# -*- coding: utf-8 -*-
"""
iPhone Bridge - 桌面控制台
=========================
一个窗口搞定：左边手机投屏（鼠标点就是点手机），右边剪贴板 / 文件 / 应用 / 设备 / 日志。

连线方式：数据线 -> Windows 的 Apple 移动设备服务 -> usbmuxd -> 手机
    · 投屏帧：走苹果 developer 服务（screenshotr），需要开发者镜像
    · 触摸/键盘/剪贴板/文件/应用：走手机端 Bridge App 的本地 HTTP（17899，经 usbmux 转发）
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FROZEN = bool(getattr(sys, "frozen", False))
if FROZEN:
    # exe 模式：数据/日志放在 exe 旁边
    BASE_DIR = os.path.dirname(sys.executable)
ROOT_DIR = os.path.dirname(BASE_DIR)
PY = sys.executable  # 冻结环境下指向自身 exe，转发逻辑改走进程内线程

from PyQt6.QtCore import Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QImage, QPainter, QPen, QPixmap
from PyQt6.QtWidgets import (
    QApplication, QComboBox, QFileDialog, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QMessageBox, QPlainTextEdit, QPushButton,
    QSizePolicy, QSplitter, QTabWidget, QTextEdit, QVBoxLayout, QWidget,
)

A = Qt.AlignmentFlag

C_BG = "#12161c"
C_PANEL = "#191f28"
C_LINE = "#2a3340"
C_TEXT = "#e6ecf5"
C_DIM = "#8b97a8"
C_ACCENT = "#3d8bfd"
C_OK = "#35c07f"
C_WARN = "#e0a33a"
C_ERR = "#e05656"

PHONE_PORT = 17899
PHONE_BUNDLE = "com.siudi.iphonebridge"   # 手机端 Bridge 应用
PHONE_APP_VERSION = "1.0"


# --------------------------------------------------------------------------- #
# 手机端 HTTP 通道（经 usbmux 转发到 127.0.0.1）
# --------------------------------------------------------------------------- #
LINK_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 本机直连，绝不过代理


def _file_log(level: str, msg: str):
    """工作日志同步写文件（exe 模式排查用）"""
    try:
        with open(os.path.join(BASE_DIR, "bridge.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%H:%M:%S')} [{level}] {msg}\n")
    except Exception:
        pass

class PhoneLink:
    def __init__(self, port: int = PHONE_PORT):
        self.port = port
        self.available = False
        self.info: dict = {}
        self._lock = threading.Lock()

    def request(self, path: str, data=None, timeout: float = 6.0, method: str | None = None) -> dict:
        url = f"http://127.0.0.1:{self.port}{path}"
        body = None
        headers = {"Content-Type": "application/json"}
        if data is not None:
            body = json.dumps(data).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=headers, method=method or ("POST" if body else "GET"))
        try:
            with LINK_OPENER.open(req, timeout=timeout) as r:
                raw = r.read()
            return json.loads(raw.decode("utf-8", "replace") or "{}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.available = False
            return {"ok": False, "error": f"手机端无响应：{e}"}

    def ping(self, timeout: float = 2.0) -> bool:
        r = self.request("/health", timeout=timeout)
        ok = bool(r.get("ok"))
        with self._lock:
            self.available = ok
        if ok:
            self.info = self.request("/info", timeout=3.0)
        return ok


LINK = PhoneLink()


# --------------------------------------------------------------------------- #
# 进程内端口转发器线程（替代子进程方案：不再产生残留进程、可随时干净启停）
# --------------------------------------------------------------------------- #
class ForwarderThread(threading.Thread):
    """本机 PHONE_PORT -> 手机 PHONE_PORT，线程内跑 asyncio 转发循环"""

    def __init__(self, udid: str | None, say):
        super().__init__(daemon=True, name="usbmux-forwarder")
        self.udid = udid
        self._say = say
        self.fwd = None
        self.loop = None
        self.exited = threading.Event()

    def run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        try:
            from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
            self.fwd = UsbmuxTcpForwarder(self.udid, PHONE_PORT, PHONE_PORT)
            self._say("info", f"端口转发已启动 127.0.0.1:{PHONE_PORT} -> 手机 {PHONE_PORT}")
            self.loop.run_until_complete(self.fwd.start(address="127.0.0.1"))
        except Exception:
            self._say("warn", "端口转发退出：\n" + traceback.format_exc(limit=3))
        finally:
            self.exited.set()

    def shutdown(self):
        try:
            if self.fwd is not None and self.loop is not None and self.loop.is_running():
                self.loop.call_soon_threadsafe(self.fwd.stop)
        except Exception:
            pass


def _port_listening(port: int) -> bool:
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
        s.close()
        return True
    except OSError:
        return False


def free_port(port: int, say) -> None:
    """启动前清理本机端口的残留监听（只清理本项目自己的 python 进程，安全）"""
    if not _port_listening(port):
        return
    try:
        import re as _re
        out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, timeout=10).stdout
        pids = set()
        for line in out.splitlines():
            if f":{port}" in line and "LISTENING" in line.upper():
                m = _re.search(r"(\d+)\s*$", line.strip())
                if m:
                    pids.add(m.group(1))
        my_base = os.path.normcase(BASE_DIR)
        for pid in pids:
            try:
                out2 = subprocess.run(
                    ["powershell", "-NoProfile", "-Command",
                     f"(Get-Process -Id {pid} -ErrorAction SilentlyContinue).Path"],
                    capture_output=True, text=True, timeout=15).stdout
                exe = (out2 or "").strip().splitlines()[0].strip() if (out2 or "").strip() else ""
                exe_n = os.path.normcase(exe)
                if exe_n and (exe_n.startswith(my_base) or exe_n.startswith(os.path.normcase(ROOT_DIR))):
                    subprocess.run(["taskkill", "/PID", pid, "/F", "/T"],
                                   capture_output=True, text=True, timeout=10)
                    say("warn", f"已清理残留转发进程 PID {pid}（占用本机 {port} 端口）")
                elif exe_n:
                    say("warn", f"本机 {port} 端口被其他程序占用：{exe}（PID {pid}），无法自动清理")
            except Exception:
                continue
        time.sleep(0.8)
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# 设备工作线程：连设备、挂开发者镜像、抓帧
# --------------------------------------------------------------------------- #
class DeviceWorker(QThread):
    frame_img = pyqtSignal(QImage)
    state = pyqtSignal(dict)
    log = pyqtSignal(str, str)   # level, msg

    SHOT_WORKERS = 6   # 并行抓屏连接数（实测 6 路最优：~3.2fps vs 单路 0.8fps）

    def __init__(self, parent=None):
        super().__init__(parent)
        self._running = True
        self._lockdown = None
        self._fwd_thread: ForwarderThread | None = None
        self._last_ensure = 0.0        # 上次自动拉起手机 App 的时间
        self._ensuring = False
        self.fps = 0.0
        self._frames = 0               # 累计帧数
        self._shot_fails = 0
        self.last_raw = b""            # 最近一帧原始 PNG（供保存截图）

    def stop(self):
        self._running = False

    # -- 工具 --------------------------------------------------------------
    def _say(self, level, msg):
        _file_log(level, msg)
        self.log.emit(level, msg)

    def _st(self, **kw):
        self.state.emit(kw)

    # -- 主循环 ------------------------------------------------------------
    def run(self):
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._main())
        except Exception:
            self._say("err", "工作线程异常：\n" + traceback.format_exc())
        finally:
            try:
                loop.run_until_complete(self._cleanup())
            except Exception:
                pass
            loop.close()

    async def _cleanup(self):
        if self._lockdown is not None:
            try:
                await self._lockdown.close()
            except Exception:
                pass
        self._kill_forward()

    def _kill_forward(self):
        t = self._fwd_thread
        if t is not None:
            try:
                t.shutdown()
                t.join(timeout=4)
            except Exception:
                pass
        self._fwd_thread = None

    def _start_forward(self, udid: str | None):
        """把本机 17899 转发到手机 17899（手机端 App 的 HTTP），进程内线程实现"""
        self._kill_forward()
        if _port_listening(PHONE_PORT):
            free_port(PHONE_PORT, self._say)
        if _port_listening(PHONE_PORT):
            self._say("err", f"本机 {PHONE_PORT} 端口仍被占用，手机端无法连接（可重启电脑或手动结束占用进程）")
            return
        t = ForwarderThread(udid, self._say)
        t.start()
        self._fwd_thread = t

    def _forwarder_alive(self) -> bool:
        t = self._fwd_thread
        return t is not None and not t.exited.is_set()

    async def _main(self):
        from pymobiledevice3.lockdown import create_using_usbmux

        attempt = 0
        while self._running:
            try:
                self._st(phase="connecting", text="连接设备…" if attempt == 0 else f"重新连接（第 {attempt} 次）")
                lockdown = await create_using_usbmux(autopair=True)
                self._lockdown = lockdown
                vals = await lockdown.get_value() or {}

                udid = vals.get("UniqueDeviceID") or ""
                self._st(
                    phase="connected",
                    device={
                        "name": vals.get("DeviceName", "iPhone"),
                        "model": vals.get("ProductType", ""),
                        "ios": vals.get("ProductVersion", ""),
                        "udid": udid,
                        "build": vals.get("BuildVersion", ""),
                        "serial": vals.get("SerialNumber", ""),
                    },
                    text="已连接",
                )
                self._say("ok", f"设备已连接：{vals.get('DeviceName','iPhone')} / iOS {vals.get('ProductVersion','?')}")

                # 1) 开发者镜像（截图必需）——失败不退出，降级运行
                # 先完成镜像检查再开端口转发：转发子进程+健康轮询的连接风暴会卡住 usbmuxd
                self._st(phase="mounting", text="检查开发者镜像…")
                ok_mount = await self._ensure_ddi(lockdown)
                if not ok_mount:
                    self._st(phase="need_devmode",
                             text="未开开发者模式：投屏不可用，剪贴板/文件/App 管理正常")
                    self._say("warn", "开发者模式未开启——投屏暂不可用，但隧道保持连接，剪贴板等功能正常")
                    self._start_forward(udid or None)
                    # 先廉价查询开发者模式开关，开了才挂载（避免反复触发大体积镜像下载）
                    while self._running and not ok_mount:
                        await asyncio.sleep(15)
                        try:
                            from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService
                            dev = bool(await MobileImageMounterService(lockdown=lockdown).query_developer_mode_status())
                            if not dev:
                                continue
                            self._say("info", "检测到开发者模式已开启，尝试挂载镜像…")
                            ok_mount = await self._ensure_ddi(lockdown, quiet=True)
                        except Exception:
                            continue
                    if not self._running:
                        return
                    self._st(phase="connected", text="已连接（投屏已启用）")
                    self._say("ok", "开发者镜像已挂载，投屏启动")

                # 2) 镜像就绪后再开端口转发（手机端 Bridge 的 HTTP 通道）
                self._start_forward(udid or None)

                # 3) 截图循环
                await self._shot_loop(lockdown)

            except asyncio.CancelledError:
                return
            except Exception as e:
                attempt += 1
                msg = str(e)
                _file_log("err", "连接失败：\n" + traceback.format_exc())
                self._st(phase="error", text="连接失败", error=msg[:300])
                self._say("err", f"连接失败：{msg[:300]}")
                self._kill_forward()
                if self._lockdown is not None:
                    try:
                        await self._lockdown.close()
                    except Exception:
                        pass
                    self._lockdown = None
                for _ in range(20):
                    if not self._running:
                        return
                    await asyncio.sleep(0.2)

    async def _ensure_ddi(self, lockdown, quiet: bool = False) -> bool:
        from pymobiledevice3.services.mobile_image_mounter import auto_mount
        from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService

        # 关键：全程复用同一条服务连接（同时维持两条 lockdown 服务连接会卡死）
        svc = MobileImageMounterService(lockdown=lockdown)
        try:
            # 开发者模式状态
            try:
                dev = bool(await asyncio.wait_for(svc.query_developer_mode_status(), 8))
                self._st(developer_mode=dev)
                self._say("info" if dev else "warn", f"开发者模式：{'已开启' if dev else '未开启'}")
            except Exception as e:
                self._say("warn", f"查询开发者模式失败：{str(e)[:120]}")

            # 已挂载则直接跳过 auto_mount
            mounted = False
            try:
                if not quiet:
                    self._say("info", "检查镜像状态…")
                mounted = bool(await asyncio.wait_for(svc.is_image_mounted("Developer"), 8))
            except Exception as e:
                self._say("warn", f"镜像状态查询失败：{str(e)[:120]}（继续常规流程）")

            if mounted:
                self._say("ok", "开发者镜像已在挂载状态")
                return True

            if not quiet:
                self._say("info", "挂载开发者镜像…（首次会自动下载，约 20–60 秒）")
            # 释放当前连接，避免与 auto_mount 内部的新连接并发
            try:
                await svc.close()
            except Exception:
                pass
            await auto_mount(lockdown)
            self._say("ok", "开发者镜像已挂载")
            return True
        except Exception as e:
            msg = str(e)
            if "already" in msg.lower():
                self._say("ok", "开发者镜像已在挂载状态")
                return True
            if not quiet:
                self._say("err", f"挂载失败：{msg[:400]}")
            self._st(phase="need_devmode", text="未开开发者模式：投屏不可用，剪贴板/文件/App 管理正常")
            return False
        finally:
            try:
                await svc.close()
            except Exception:
                pass

    async def _shot_loop(self, lockdown):
        """多路并行抓屏：每条连接独立循环抓帧+解码，聚合 fps 约为单路的 4 倍。
        PNG 解码在 asyncio 线程完成（QImage 非线程绑定），GUI 线程只负责绘制。"""
        from pymobiledevice3.services.screenshot import ScreenshotService

        self._st(phase="streaming", text="投屏中")
        self._say("ok", f"开始抓屏（{self.SHOT_WORKERS} 路并行管线）")

        async def worker(idx: int):
            while self._running:
                svc = None
                try:
                    svc = ScreenshotService(lockdown=lockdown)
                    await svc.connect()
                    while self._running:
                        data = await svc.take_screenshot()
                        if not data:
                            await asyncio.sleep(0.05)
                            continue
                        img = QImage.fromData(bytes(data))
                        if not img.isNull():
                            self._frames += 1
                            self.last_raw = bytes(data)
                            self.frame_img.emit(img)
                except asyncio.CancelledError:
                    return
                except Exception as e:
                    self._shot_fails += 1
                    if self._shot_fails in (3, 15, 60):
                        self._say("warn", f"抓屏异常：{str(e)[:160]}，自动重连中…")
                    await asyncio.sleep(1.2)
                finally:
                    if svc is not None:
                        try:
                            await svc.close()
                        except Exception:
                            pass
                    await asyncio.sleep(0.3)

        tasks = [asyncio.create_task(worker(i)) for i in range(self.SHOT_WORKERS)]

        # 统计 fps + 手机端 Bridge 自愈
        t_last = time.time()
        n_last = 0
        try:
            while self._running:
                await asyncio.sleep(2.0)
                now = time.time()
                n_now = self._frames
                self.fps = (n_now - n_last) / (now - t_last)
                self._st(fps=round(self.fps, 1))
                n_last, t_last = n_now, now
                if not LINK.available:
                    await self._recover_phone_link(lockdown)
        finally:
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _recover_phone_link(self, lockdown):
        """手机端不可用时的自愈：转发器死了就重启；还不行就用 DVT 拉起手机 App"""
        now = time.time()
        if not self._forwarder_alive():
            self._say("warn", "检测到端口转发器已停止，正在重启…")
            self._start_forward(None)
            await asyncio.sleep(2.0)
            if LINK.ping():
                self._say("ok", "转发器重启后手机端已恢复连接")
                return
        if self._ensuring or now - self._last_ensure < 30:
            return
        self._ensuring = True
        try:
            await self._ensure_phone_app(lockdown)
        finally:
            self._ensuring = False
            self._last_ensure = time.time()

    async def _ensure_phone_app(self, lockdown):
        """用 DVT（开发者服务）远程拉起手机端 Bridge 应用（无需手动点亮屏幕）"""
        try:
            from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
            from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

            async def _launch():
                async with DvtProvider(lockdown) as dvt, ProcessControl(dvt) as pc:
                    pid = await pc.process_identifier_for_bundle_identifier(PHONE_BUNDLE)
                    if pid and pid > 0:
                        self._say("info", "手机端 Bridge 已在运行，等待其 HTTP 就绪…")
                        return
                    self._say("info", "手机端 Bridge 未运行，正在自动拉起…")
                    await pc.launch(PHONE_BUNDLE, kill_existing=False)
                    self._say("ok", "手机端 Bridge 已拉起（稍后自动连接）")

            # 必须限时：DVT 挂起会拖死整个抓屏事件循环
            await asyncio.wait_for(_launch(), 20)
        except Exception as e:
            self._say("warn", f"自动拉起手机端失败：{str(e)[:160]}（请手动打开手机上的 Bridge 应用）")


# --------------------------------------------------------------------------- #
# 修复线程：开启开发者模式
# --------------------------------------------------------------------------- #
class RepairWorker(QThread):
    log = pyqtSignal(str, str)
    done = pyqtSignal(bool, str)

    def run(self):
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._run())
        except Exception as e:
            self.done.emit(False, str(e)[:300])
        finally:
            loop.close()

    async def _run(self):
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.amfi import AmfiService

        lockdown = await create_using_usbmux(autopair=True)
        svc = AmfiService(lockdown)
        self.log.emit("info", "1/2 在设置里显示「开发者模式」开关…")
        await svc.reveal_developer_mode_option_in_ui()
        self.log.emit("ok", "已显示开关")
        self.log.emit("info", "2/2 请求开启开发者模式…")
        await svc.enable_developer_mode()
        self.log.emit("ok", "已请求开启")
        await lockdown.close()
        self.done.emit(True, "需要重启手机：重启后到 设置 → 隐私与安全性 → 开发者模式 打开开关，然后再点连接。")


# --------------------------------------------------------------------------- #
# 投屏控件
# --------------------------------------------------------------------------- #
class ScreenView(QWidget):
    tapped = pyqtSignal(float, float)
    longpressed = pyqtSignal(float, float)
    swiped = pyqtSignal(float, float, float, float)
    scrolled = pyqtSignal(int)   # 滚轮：角度值（120 为一格）

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(300, 520)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setMouseTracking(True)
        self._img: QImage | None = None
        self._rect = None
        self._press_pos = None
        self._press_t = 0.0
        self._moved = False
        self._last = None
        self._hint = "等待手机画面…"
        self._hint2 = ""
        self._flash_until = 0.0   # 操作发送成功后的绿色闪环

    def set_frame_img(self, img: QImage):
        self._img = img
        self._hint = ""
        self.update()

    def set_hint(self, text: str, sub: str = ""):
        self._hint, self._hint2 = text, sub
        self.update()

    def _fit(self):
        if self._img is None:
            return None
        aw, ah = self.width(), self.height()
        iw, ih = self._img.width(), self._img.height()
        if iw <= 0 or ih <= 0:
            return None
        scale = min(aw / iw, ah / ih)
        w, h = int(iw * scale), int(ih * scale)
        x, y = (aw - w) // 2, (ah - h) // 2
        from PyQt6.QtCore import QRect
        return QRect(x, y, w, h)

    def paintEvent(self, _):
        # 注意：paintEvent 里绝不能让异常逃出去——穿透 Qt C++ 绘制代码会触发 qFatal 进程终止
        try:
            self._do_paint()
        except Exception:
            try:
                _file_log("err", "paintEvent 异常（已忽略）：\n" + traceback.format_exc(limit=3))
            except Exception:
                pass
            try:
                self._img = None
            except Exception:
                pass

    def _do_paint(self):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0e13"))
        r = self._fit()
        self._rect = r
        if self._img is not None and r is not None:
            p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)
            p.drawImage(r, self._img)
            p.setPen(QPen(QColor(C_LINE), 1))
            p.drawRect(r.adjusted(-1, -1, 0, 0))
            if self._last:
                p.setPen(QPen(QColor(61, 139, 253, 200), 2))
                p.drawEllipse(int(self._last[0]) - 14, int(self._last[1]) - 14, 28, 28)
            if time.time() < self._flash_until:
                # 操作已发送：绿色闪环（即时反馈，与投屏延迟无关）
                p.setPen(QPen(QColor(52, 199, 89, 230), 3))
                p.drawEllipse(int(self.width() / 2) - 16, self.height() - 44, 32, 32)
        else:
            p.setPen(QColor(C_DIM))
            f = QFont("Microsoft YaHei", 11)
            p.setFont(f)
            p.drawText(self.rect().adjusted(0, -20, 0, -20), A.AlignCenter, self._hint)
            if self._hint2:
                p.setPen(QColor("#5d6a7d"))
                p.setFont(QFont("Microsoft YaHei", 9))
                p.drawText(self.rect().adjusted(0, 26, 0, 26), A.AlignCenter, self._hint2)
        p.end()

    def _norm(self, pos):
        if self._rect is None or self._rect.width() == 0:
            return None
        nx = (pos.x() - self._rect.x()) / self._rect.width()
        ny = (pos.y() - self._rect.y()) / self._rect.height()
        if nx < 0 or nx > 1 or ny < 0 or ny > 1:
            return None
        return nx, ny

    def mousePressEvent(self, e):
        try:
            if e.button() == Qt.MouseButton.LeftButton:
                self._press_pos = e.position()
                self._press_t = time.time()
                self._moved = False
                n = self._norm(e.position())
                if n:
                    self._last = (int(e.position().x()), int(e.position().y()))
                    self.update()
            elif e.button() == Qt.MouseButton.RightButton:
                # 右键 = 长按
                n = self._norm(e.position())
                if n:
                    self.longpressed.emit(*n)
        except Exception:
            try:
                _file_log("err", "mousePress 异常（已忽略）：\n" + traceback.format_exc(limit=2))
            except Exception:
                pass

    def wheelEvent(self, e):
        dy = e.angleDelta().y()
        if dy:
            self.scrolled.emit(dy)

    def mouseMoveEvent(self, e):
        if self._press_pos is not None:
            if (e.position() - self._press_pos).manhattanLength() > 8:
                self._moved = True

    def mouseReleaseEvent(self, e):
        if e.button() != Qt.MouseButton.LeftButton or self._press_pos is None:
            return
        dur = time.time() - self._press_t
        a = self._norm(self._press_pos)
        b = self._norm(e.position())
        self._press_pos = None
        if not a or not b:
            return
        if not self._moved and dur < 0.6:
            self._flash()
            self.tapped.emit(*a)
        elif not self._moved and dur >= 0.6:
            self._flash()
            self.longpressed.emit(*a)
        elif self._moved:
            self._flash()
            self.swiped.emit(a[0], a[1], b[0], b[1])

    def _flash(self):
        self._flash_until = time.time() + 0.45
        self.update()
        QTimer.singleShot(500, self.update)


# --------------------------------------------------------------------------- #
# 主窗口
# --------------------------------------------------------------------------- #
class MainWindow(QWidget):
    ui_call = pyqtSignal(object)   # 任意线程 → 主线程执行 UI 操作

    def __init__(self):
        super().__init__()
        self.ui_call.connect(self._run_ui)
        self.setWindowTitle("iPhone Bridge · 电脑控制台")
        self.resize(1180, 780)
        self.setStyleSheet(self._qss())

        self.dev: dict = {}
        self.phase = "init"
        self.files_path = "/var/mobile/Media"
        self.autosync = True   # 默认开启双向自动同步

        self._build_ui()

        self.worker = DeviceWorker(self)
        self.worker.frame_img.connect(self.on_frame)
        self.worker.state.connect(self.on_state)
        self.worker.log.connect(self.add_log)
        self.worker.start()

        self.ping_timer = QTimer(self)
        self.ping_timer.timeout.connect(self.ping_phone)
        self.ping_timer.start(3000)

        self.sync_timer = QTimer(self)
        self.sync_timer.timeout.connect(self.auto_sync_tick)
        self.sync_timer.start(1500)
        self._last_clip = ""

    # -- 主线程调度（线程里禁止直接碰控件） --------------------------------
    def ui(self, fn):
        self.ui_call.emit(fn)

    def _run_ui(self, fn):
        try:
            fn()
        except Exception:
            pass

    # -- 外观 --------------------------------------------------------------
    def _qss(self):
        return f"""
        QWidget {{ background: {C_BG}; color: {C_TEXT}; font-family: "Microsoft YaHei", "Segoe UI"; font-size: 12px; }}
        QFrame#card {{ background: {C_PANEL}; border: 1px solid {C_LINE}; border-radius: 10px; }}
        QLabel#h {{ color: {C_DIM}; }}
        QLabel#big {{ font-size: 14px; font-weight: 600; }}
        QPushButton {{ background: #222b38; border: 1px solid {C_LINE}; border-radius: 7px; padding: 6px 12px; }}
        QPushButton:hover {{ background: #2b3646; }}
        QPushButton:pressed {{ background: #1b2330; }}
        QPushButton#primary {{ background: {C_ACCENT}; border: none; color: white; font-weight: 600; }}
        QPushButton#primary:hover {{ background: #5a9dff; }}
        QLineEdit, QPlainTextEdit, QTextEdit, QListWidget, QComboBox {{
            background: #0f141b; border: 1px solid {C_LINE}; border-radius: 7px; padding: 5px;
            selection-background-color: {C_ACCENT};
        }}
        QTabWidget::pane {{ border: 1px solid {C_LINE}; border-radius: 8px; top: -1px; }}
        QTabBar::tab {{ background: transparent; padding: 7px 14px; color: {C_DIM}; }}
        QTabBar::tab:selected {{ color: {C_TEXT}; border-bottom: 2px solid {C_ACCENT}; }}
        QSplitter::handle {{ background: {C_LINE}; }}
        """

    # -- 布局 --------------------------------------------------------------
    def _build_ui(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(10, 10, 10, 10)
        root.setSpacing(8)

        # 顶栏
        top = QFrame()
        top.setObjectName("card")
        tl = QHBoxLayout(top)
        tl.setContentsMargins(12, 8, 12, 8)
        self.dot = QLabel("●")
        self.dot.setStyleSheet(f"color:{C_WARN};font-size:14px")
        self.lbl_dev = QLabel("正在查找设备…")
        self.lbl_dev.setObjectName("big")
        self.lbl_phase = QLabel("")
        self.lbl_phase.setObjectName("h")
        self.lbl_fps = QLabel("")
        self.lbl_fps.setObjectName("h")
        tl.addWidget(self.dot)
        tl.addWidget(self.lbl_dev)
        tl.addSpacing(10)
        tl.addWidget(self.lbl_phase)
        tl.addStretch(1)
        tl.addWidget(self.lbl_fps)

        self.btn_home = QPushButton("回到主屏")
        self.btn_home.clicked.connect(lambda: self.phone_call("/home"))
        self.btn_fix = QPushButton("修复连接")
        self.btn_fix.clicked.connect(self.fix_connect)
        self.btn_shot = QPushButton("存截图")
        self.btn_shot.clicked.connect(self.save_shot)
        tl.addWidget(self.btn_home)
        tl.addWidget(self.btn_fix)
        tl.addWidget(self.btn_shot)
        self.lbl_phone = QLabel("手机端：检测中")
        self.lbl_phone.setObjectName("h")
        tl.addWidget(self.lbl_phone)
        root.addWidget(top)

        # 主体
        split = QSplitter(Qt.Orientation.Horizontal)

        left = QFrame()
        left.setObjectName("card")
        ll = QVBoxLayout(left)
        ll.setContentsMargins(6, 6, 6, 6)
        self.screen = ScreenView()
        self.screen.tapped.connect(self.on_tap)
        self.screen.longpressed.connect(self.on_long)
        self.screen.swiped.connect(self.on_swipe)
        self.screen.scrolled.connect(self.on_scroll)
        ll.addWidget(self.screen, 1)

        bar = QHBoxLayout()
        self.input = QLineEdit()
        self.input.setPlaceholderText("在这里输入文字，回车即发送到手机（中文会自动走粘贴）")
        self.input.returnPressed.connect(self.send_text)
        btn_send = QPushButton("发送")
        btn_send.setObjectName("primary")
        btn_send.clicked.connect(self.send_text)
        btn_bs = QPushButton("退格")
        btn_bs.clicked.connect(lambda: self.phone_call("/press", {"key": "backspace"}))
        btn_ret = QPushButton("回车")
        btn_ret.clicked.connect(lambda: self.phone_call("/press", {"key": "return"}))
        bar.addWidget(self.input, 1)
        bar.addWidget(btn_send)
        bar.addWidget(btn_bs)
        bar.addWidget(btn_ret)
        ll.addLayout(bar)
        split.addWidget(left)

        # 右侧面板
        self.tabs = QTabWidget()
        self.tabs.addTab(self._tab_clip(), "剪贴板")
        self.tabs.addTab(self._tab_files(), "文件")
        self.tabs.addTab(self._tab_apps(), "应用")
        self.tabs.addTab(self._tab_device(), "设备")
        self.tabs.addTab(self._tab_log(), "日志")
        split.addWidget(self.tabs)
        split.setSizes([720, 420])
        root.addWidget(split, 1)

        self.lbl_foot = QLabel("提示：手机插线解锁；Bridge 未运行时会自动拉起。鼠标：左键=点击 · 拖动=滑动 · 右键=长按 · 滚轮=滚动列表")
        self.lbl_foot.setObjectName("h")
        root.addWidget(self.lbl_foot)

    def _tab_clip(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setSpacing(8)

        row = QHBoxLayout()
        b1 = QPushButton("手机 → 电脑")
        b1.setObjectName("primary")
        b1.clicked.connect(self.pull_clip)
        b2 = QPushButton("电脑 → 手机")
        b2.clicked.connect(self.push_clip)
        self.btn_auto = QPushButton("自动同步：关")
        self.btn_auto.clicked.connect(self.toggle_auto)
        row.addWidget(b1)
        row.addWidget(b2)
        row.addWidget(self.btn_auto)
        v.addLayout(row)

        v.addWidget(QLabel("手机剪贴板"))
        self.txt_phone = QPlainTextEdit()
        self.txt_phone.setPlaceholderText("点上面「手机 → 电脑」读取")
        v.addWidget(self.txt_phone, 1)

        v.addWidget(QLabel("电脑剪贴板"))
        self.txt_pc = QPlainTextEdit()
        self.txt_pc.setPlaceholderText("这里的内容可一键推到手机")
        v.addWidget(self.txt_pc, 1)

        row2 = QHBoxLayout()
        b3 = QPushButton("读取电脑剪贴板")
        b3.clicked.connect(self.read_pc_clip)
        b4 = QPushButton("用手机内容覆盖电脑")
        b4.clicked.connect(self.phone_to_pc)
        row2.addWidget(b3)
        row2.addWidget(b4)
        v.addLayout(row2)
        return w

    def _tab_files(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setSpacing(8)
        row = QHBoxLayout()
        up = QPushButton("返回上级")
        up.clicked.connect(self.files_up)
        rf = QPushButton("刷新")
        rf.clicked.connect(lambda: self.load_files(self.files_path))
        dl = QPushButton("下载选中")
        dl.clicked.connect(self.download_file)
        ul = QPushButton("上传到此处")
        ul.clicked.connect(self.upload_file)
        for b in (up, rf, dl, ul):
            row.addWidget(b)
        v.addLayout(row)
        self.lbl_path = QLabel(self.files_path)
        self.lbl_path.setObjectName("h")
        v.addWidget(self.lbl_path)
        self.lst = QListWidget()
        self.lst.itemDoubleClicked.connect(self.file_open)
        v.addWidget(self.lst, 1)
        return w

    def _tab_apps(self):
        w = QWidget()
        v = QVBoxLayout(w)
        row = QHBoxLayout()
        rf = QPushButton("刷新列表")
        rf.clicked.connect(self.load_apps)
        op = QPushButton("打开选中")
        op.clicked.connect(self.open_app)
        row.addWidget(rf)
        row.addWidget(op)
        v.addLayout(row)
        self.lst_apps = QListWidget()
        self.lst_apps.itemDoubleClicked.connect(self.open_app)
        v.addWidget(self.lst_apps, 1)
        return w

    def _tab_device(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.txt_dev = QTextEdit()
        self.txt_dev.setReadOnly(True)
        v.addWidget(self.txt_dev, 1)

        row = QHBoxLayout()
        row.addWidget(QLabel("亮度"))
        from PyQt6.QtWidgets import QSlider
        s1 = QSlider(Qt.Orientation.Horizontal)
        s1.setRange(0, 100)
        s1.setValue(60)
        s1.sliderReleased.connect(lambda: self.phone_call("/brightness", {"value": s1.value() / 100}))
        row.addWidget(s1, 1)
        v.addLayout(row)
        row2 = QHBoxLayout()
        row2.addWidget(QLabel("音量"))
        s2 = QSlider(Qt.Orientation.Horizontal)
        s2.setRange(0, 100)
        s2.setValue(50)
        s2.sliderReleased.connect(lambda: self.phone_call("/volume", {"value": s2.value() / 100}))
        row2.addWidget(s2, 1)
        v.addLayout(row2)

        row3 = QHBoxLayout()
        b1 = QPushButton("手电开")
        b1.clicked.connect(lambda: self.phone_call("/torch", {"on": True}))
        b2 = QPushButton("手电关")
        b2.clicked.connect(lambda: self.phone_call("/torch", {"on": False}))
        b3 = QPushButton("震动")
        b3.clicked.connect(lambda: self.phone_call("/vibrate"))
        b4 = QPushButton("HID 自检")
        b4.clicked.connect(self.hid_selftest)
        for b in (b1, b2, b3, b4):
            row3.addWidget(b)
        v.addLayout(row3)
        return w

    def _tab_log(self):
        w = QWidget()
        v = QVBoxLayout(w)
        self.txt_log = QTextEdit()
        self.txt_log.setReadOnly(True)
        self.txt_log.setStyleSheet("font-family: Consolas, 'Microsoft YaHei'; font-size: 11px;")
        v.addWidget(self.txt_log, 1)
        return w

    # -- 日志 --------------------------------------------------------------
    def add_log(self, level, msg):
        color = {"ok": C_OK, "warn": C_WARN, "err": C_ERR}.get(level, C_DIM)
        t = time.strftime("%H:%M:%S")
        self.txt_log.append(f'<span style="color:#5d6a7d">{t}</span> '
                            f'<span style="color:{color}">{msg}</span>')

    # -- 设备状态 ----------------------------------------------------------
    def on_state(self, st: dict):
        if "device" in st:
            self.dev = st["device"]
            d = self.dev
            self.lbl_dev.setText(f"{d.get('name','iPhone')} · {d.get('model','')} · iOS {d.get('ios','')}")
            self.refresh_dev_panel()
        if "phase" in st:
            self.phase = st["phase"]
            txt = st.get("text", "")
            self.lbl_phase.setText(txt)
            color = {
                "connected": C_OK, "streaming": C_OK, "mounting": C_WARN,
                "connecting": C_WARN, "need_devmode": C_ERR, "error": C_ERR,
            }.get(self.phase, C_WARN)
            self.dot.setStyleSheet(f"color:{color};font-size:14px")
            if self.phase == "streaming":
                self.screen.set_hint("")
            elif self.phase == "need_devmode":
                self.screen.set_hint("需要开启「开发者模式」", "点右上角「修复连接」，按提示重启手机并在设置里打开开关")
            elif self.phase == "mounting":
                self.screen.set_hint("正在准备投屏…", "首次会下载开发者镜像，请稍等")
        if "fps" in st:
            self.lbl_fps.setText(f"{st['fps']} 帧/秒")

    def refresh_dev_panel(self):
        d = self.dev
        if not d:
            return
        lines = [
            ("设备名称", d.get("name", "")),
            ("机型", d.get("model", "")),
            ("系统版本", f"iOS {d.get('ios','')} ({d.get('build','')})"),
            ("UDID", d.get("udid", "")),
            ("序列号", d.get("serial", "")),
        ]
        html = "".join(
            f'<tr><td style="color:{C_DIM};padding:3px 10px 3px 0">{k}</td>'
            f'<td style="padding:3px 0">{v}</td></tr>' for k, v in lines
        )
        phone = ""
        if LINK.available and LINK.info:
            i = LINK.info
            bat = i.get("battery")
            phone = (
                f'<tr><td style="color:{C_DIM};padding:3px 10px 3px 0">手机 App</td>'
                f'<td style="padding:3px 0;color:{C_OK}">在线 v{i.get("app_version","?")}</td></tr>'
                f'<tr><td style="color:{C_DIM};padding:3px 10px 3px 0">电量</td>'
                f'<td style="padding:3px 0">{int((bat or 0)*100)}%{" 充电中" if i.get("charging") else ""}</td></tr>'
                f'<tr><td style="color:{C_DIM};padding:3px 10px 3px 0">屏幕</td>'
                f'<td style="padding:3px 0">{i.get("screen","")} pt</td></tr>'
            )
        else:
            phone = (f'<tr><td style="color:{C_DIM};padding:3px 10px 3px 0">手机 App</td>'
                     f'<td style="padding:3px 0;color:{C_WARN}">未响应（需安装并打开 Bridge）</td></tr>')
        self.txt_dev.setHtml(f'<table style="font-size:12px">{"".join(["<tr>"])}{html}{phone}</table>')

    # -- 帧 ----------------------------------------------------------------
    def on_frame(self, img):
        self.screen.set_frame_img(img)

    def save_shot(self):
        raw = getattr(self.worker, "last_raw", b"") if hasattr(self, "worker") else b""
        if not raw:
            QMessageBox.information(self, "提示", "还没有画面")
            return
        path, _ = QFileDialog.getSaveFileName(self, "保存截图", f"iphone-{time.strftime('%Y%m%d-%H%M%S')}.png", "PNG (*.png)")
        if path:
            open(path, "wb").write(raw)
            self.add_log("ok", f"截图已保存：{path}")

    # -- 触摸 --------------------------------------------------------------
    def on_tap(self, nx, ny):
        self.phone_call("/tap", {"nx": nx, "ny": ny})

    def on_long(self, nx, ny):
        self.phone_call("/long", {"nx": nx, "ny": ny, "seconds": 1.0})

    def on_swipe(self, x1, y1, x2, y2):
        dist = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
        dur = max(0.12, min(0.5, dist * 0.7))
        self.phone_call("/swipe", {"nx1": x1, "ny1": y1, "nx2": x2, "ny2": y2, "duration": dur})

    def on_scroll(self, dy):
        """滚轮 -> 手机列表滚动：上滚看上方内容（手指下划），下滚反之"""
        ticks = max(-5.0, min(5.0, dy / 120.0))
        d = max(0.03, min(0.25, abs(ticks) * 0.05))
        if ticks > 0:
            y1, y2 = 0.5 - d / 2, 0.5 + d / 2   # 上滚：手指下划
        else:
            y1, y2 = 0.5 + d / 2, 0.5 - d / 2   # 下滚：手指上划
        self.phone_call("/swipe", {"nx1": 0.5, "ny1": y1, "nx2": 0.5, "ny2": y2, "duration": 0.16})

    def send_text(self):
        t = self.input.text()
        if not t:
            return
        self.phone_call("/text", {"text": t})
        self.input.clear()

    # -- 手机调用（后台线程，避免卡界面） ----------------------------------
    def phone_call(self, path, data=None, done=None):
        def job():
            r = LINK.request(path, data)
            if not r.get("ok"):
                err = r.get("error", "")
                self.ui(lambda: self.add_log("warn", f"{path} 失败：{err}"))
            elif done:
                self.ui(lambda: done(r))
        threading.Thread(target=job, daemon=True).start()

    def ping_phone(self):
        def job():
            was = LINK.available
            ok = LINK.ping()
            if ok:
                hid = LINK.request("/hid", timeout=4)
                ready = bool(hid.get("ready"))
                if ok and not was:
                    self.ui(lambda: self.add_log("ok", "手机端 App 已连接"))
                    self.ui(self.refresh_dev_panel)
                self.ui(lambda: self._set_phone_chip(True, ready))
            else:
                if not ok and was:
                    self.ui(lambda: self.add_log("warn", "手机端 App 断开"))
                    self.ui(self.refresh_dev_panel)
                self.ui(lambda: self._set_phone_chip(False, False))
        threading.Thread(target=job, daemon=True).start()

    def _set_phone_chip(self, online: bool, hid_ready: bool):
        if online:
            self.lbl_phone.setText("手机端：● 在线" + ("（触摸就绪）" if hid_ready else "（HID 未就绪）"))
            self.lbl_phone.setStyleSheet(f"color:{C_OK};")
        else:
            self.lbl_phone.setText("手机端：○ 未连接（会自动拉起 Bridge）")
            self.lbl_phone.setStyleSheet(f"color:{C_WARN};")

    # -- 剪贴板 ------------------------------------------------------------
    def pull_clip(self):
        def job():
            r = LINK.request("/clipboard")
            if r.get("ok"):
                text = r.get("text", "")
                self._last_clip = text
                self.ui(lambda: self.txt_phone.setPlainText(text))
                self.ui(lambda: self.add_log("ok", f"已从手机读取 {len(text)} 字"))
        threading.Thread(target=job, daemon=True).start()

    def push_clip(self):
        text = self.txt_pc.toPlainText()
        if not text:
            text = self.txt_phone.toPlainText()
        if not text:
            self.add_log("warn", "没有可推送的内容")
            return
        self.phone_call("/clipboard", {"text": text})
        self.add_log("ok", f"已写入手机剪贴板 {len(text)} 字")

    def read_pc_clip(self):
        try:
            import ctypes
            u = ctypes.windll.user32
            k = ctypes.windll.kernel32
            u.OpenClipboard(None)
            h = u.GetClipboardData(13)  # CF_UNICODETEXT
            if h:
                k.GlobalLock.restype = ctypes.c_void_p
                p = k.GlobalLock(ctypes.c_void_p(h))
                if p:
                    text = ctypes.wstring_at(p)
                    k.GlobalUnlock(ctypes.c_void_p(h))
                    self.txt_pc.setPlainText(text)
            u.CloseClipboard()
        except Exception as e:
            self.add_log("warn", f"读电脑剪贴板失败：{e}")

    def phone_to_pc(self):
        text = self.txt_phone.toPlainText()
        if not text:
            return
        try:
            import ctypes
            u = ctypes.windll.user32
            k = ctypes.windll.kernel32
            k.GlobalAlloc.restype = ctypes.c_void_p
            k.GlobalLock.restype = ctypes.c_void_p
            u.OpenClipboard(None)
            u.EmptyClipboard()
            size = (len(text) + 1) * 2
            h = k.GlobalAlloc(2, size)
            p = k.GlobalLock(ctypes.c_void_p(h))
            ctypes.memmove(p, ctypes.create_unicode_buffer(text), size)
            k.GlobalUnlock(ctypes.c_void_p(h))
            u.SetClipboardData(13, ctypes.c_void_p(h))
            u.CloseClipboard()
            self.add_log("ok", "已写入电脑剪贴板")
        except Exception as e:
            self.add_log("err", f"写电脑剪贴板失败：{e}")

    def toggle_auto(self):
        self.autosync = not self.autosync
        self.btn_auto.setText(f"自动同步：{'开' if self.autosync else '关'}")
        self.add_log("info", "自动同步已" + ("开启" if self.autosync else "关闭"))

    def auto_sync_tick(self):
        if not self.autosync or not LINK.available:
            return

        def job():
            r = LINK.request("/clipboard", timeout=3)
            if r.get("ok"):
                text = r.get("text", "")
                if text and text != self._last_clip:
                    self._last_clip = text
                    self.ui(lambda: self.txt_phone.setPlainText(text))
                    self.ui(self.phone_to_pc)
                    self.ui(lambda: self.add_log("ok", f"手机 → 电脑 同步 {len(text)} 字"))
        threading.Thread(target=job, daemon=True).start()

    # -- 文件 --------------------------------------------------------------
    def load_files(self, path):
        def job():
            r = LINK.request(f"/ls?path={urllib.parse.quote(path)}")
            if not r.get("ok"):
                err = r.get("error", "")
                self.ui(lambda: self.add_log("warn", f"列目录失败：{err}"))
                return
            files_path = r.get("path", path)
            items = sorted(r.get("items", []), key=lambda x: (not x.get("dir"), x.get("name", "")))

            def fill():
                self.lst.clear()
                self.files_path = files_path
                self.lbl_path.setText(files_path)
                for it in items:
                    name = it["name"]
                    item = QListWidgetItem(("📁 " if it.get("dir") else "📄 ") + name +
                                           ("" if it.get("dir") else f"   {self._size(it.get('size', 0))}"))
                    item.setData(Qt.ItemDataRole.UserRole, it)
                    self.lst.addItem(item)
            self.ui(fill)
        threading.Thread(target=job, daemon=True).start()

    @staticmethod
    def _size(n):
        for u in ("B", "KB", "MB", "GB"):
            if n < 1024:
                return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
            n /= 1024
        return f"{n:.1f}TB"

    def files_up(self):
        p = self.files_path.rstrip("/")
        parent = p.rsplit("/", 1)[0] or "/"
        self.load_files(parent)

    def file_open(self, item):
        it = item.data(Qt.ItemDataRole.UserRole) or {}
        name = it.get("name", "")
        full = self.files_path.rstrip("/") + "/" + name
        if it.get("dir"):
            self.load_files(full)
        else:
            self.add_log("info", f"{full}（双击下载）")

    def download_file(self):
        item = self.lst.currentItem()
        if not item:
            return
        it = item.data(Qt.ItemDataRole.UserRole) or {}
        if it.get("dir"):
            return
        full = self.files_path.rstrip("/") + "/" + it["name"]
        path, _ = QFileDialog.getSaveFileName(self, "保存到电脑", it["name"])
        if not path:
            return

        def job():
            r = LINK.request(f"/get?path={urllib.parse.quote(full)}", timeout=60)
            if not r.get("ok"):
                err = r.get("error", "")
                self.ui(lambda: self.add_log("err", f"下载失败：{err}"))
                return
            data = base64.b64decode(r.get("data", ""))
            open(path, "wb").write(data)
            n = len(data)
            self.ui(lambda: self.add_log("ok", f"已保存 {path}（{self._size(n)}）"))
        threading.Thread(target=job, daemon=True).start()

    def upload_file(self):
        path, _ = QFileDialog.getOpenFileName(self, "选择要传到手机的文件")
        if not path:
            return
        name = os.path.basename(path)
        dst = self.files_path.rstrip("/") + "/" + name

        def job():
            data = open(path, "rb").read()
            r = LINK.request("/put", {"path": dst, "data": base64.b64encode(data).decode()}, timeout=120)
            if r.get("ok"):
                self.ui(lambda: self.add_log("ok", f"已上传到手机：{dst}"))
                self.ui(lambda: self.load_files(self.files_path))
            else:
                err = r.get("error", "")
                self.ui(lambda: self.add_log("err", f"上传失败：{err}"))
        threading.Thread(target=job, daemon=True).start()

    # -- 应用 --------------------------------------------------------------
    def load_apps(self):
        def job():
            r = LINK.request("/apps", timeout=20)
            apps = r.get("apps") or []
            err = r.get("error", "")

            def fill():
                self.lst_apps.clear()
                for a in apps:
                    it = QListWidgetItem(f"{a.get('name','?')}   ·   {a.get('bundle','')}")
                    it.setData(Qt.ItemDataRole.UserRole, a)
                    self.lst_apps.addItem(it)
                if not apps:
                    self.add_log("warn", f"没取到应用列表：{err}")
                else:
                    self.add_log("ok", f"应用 {len(apps)} 个")
            self.ui(fill)
        threading.Thread(target=job, daemon=True).start()

    def open_app(self, item=None):
        item = item if isinstance(item, QListWidgetItem) else self.lst_apps.currentItem()
        if not item:
            return
        a = item.data(Qt.ItemDataRole.UserRole) or {}
        self.phone_call("/open", {"bundle": a.get("bundle", "")})
        self.add_log("info", f"启动 {a.get('name','')}")

    # -- 修复 / 自检 -------------------------------------------------------
    def fix_connect(self):
        if self.phase in ("need_devmode", "error", "mounting"):
            ans = QMessageBox.question(
                self, "开启开发者模式",
                "投屏需要手机开启「开发者模式」。\n\n现在执行：在手机设置里显示开发者模式开关 → 请求开启。\n完成后需要重启手机，再到 设置 → 隐私与安全性 → 开发者模式 打开开关。\n\n继续吗？")
            if ans != QMessageBox.StandardButton.Yes:
                return
            self.repair = RepairWorker(self)
            self.repair.log.connect(self.add_log)
            self.repair.done.connect(self._repair_done)
            self.repair.start()
        else:
            self.add_log("info", "重启连接线程…")
            self.worker.stop()
            self.worker.wait(3000)
            self.worker = DeviceWorker(self)
        self.worker.frame_img.connect(self.on_frame)
        self.worker.state.connect(self.on_state)
        self.worker.log.connect(self.add_log)
        self.worker.start()

    def _repair_done(self, ok, msg):
        self.add_log("ok" if ok else "err", msg)
        QMessageBox.information(self, "修复连接", msg)

    def hid_selftest(self):
        def job():
            r = LINK.request("/hid")
            s = json.dumps(r, ensure_ascii=False)
            self.ui(lambda: self.add_log("ok" if r.get("ok") else "err", s))
            if r.get("ok"):
                LINK.request("/tap", {"nx": 0.5, "ny": 0.5})
                self.ui(lambda: self.add_log("info", "已发送一次点击（屏幕中心）"))
        threading.Thread(target=job, daemon=True).start()

    def closeEvent(self, e):
        try:
            with open(os.path.join(BASE_DIR, "runtime.log"), "a", encoding="utf-8") as _f:
                _f.write(f"[EXIT] closeEvent {time.strftime('%H:%M:%S')}（窗口被关闭）\n")
        except Exception:
            pass
        try:
            self.worker.stop()
            self.worker.wait(1500)
        except Exception:
            pass
        e.accept()


def main():
    # 崩溃日志：任何致命错误写入 crash.log，便于排查
    try:
        import faulthandler
        faulthandler.enable(open(os.path.join(BASE_DIR, "crash.log"), "w", encoding="utf-8"))
    except Exception:
        pass
    # 运行时日志：窗口关闭原因 / Qt 消息 / 线程异常
    try:
        _rt = open(os.path.join(BASE_DIR, "runtime.log"), "a", encoding="utf-8", buffering=1)
        _rt.write(f"\n===== 启动 {time.strftime('%H:%M:%S')} pid={os.getpid()} =====\n")
        if sys.stdout is None or not hasattr(sys.stdout, "write"):
            sys.stdout = _rt
        if sys.stderr is None or not hasattr(sys.stderr, "write"):
            sys.stderr = _rt
    except Exception:
        _rt = None
    if os.name == "nt":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            pass
    app = QApplication(sys.argv)
    app.setApplicationName("iPhone Bridge")
    win = MainWindow()
    # 捕获 Qt 层警告/qFatal（写进 runtime.log；qFatal 之前会先走这里）
    try:
        if _rt:
            from PyQt6.QtCore import qInstallMessageHandler
            _ML = {0: "DBG", 1: "WRN", 2: "CRT", 3: "FTL", 4: "INF"}

            def _qt_msg(_t, _ctx, msg):
                try:
                    _rt.write(f"[QT-{_ML.get(int(_t), _t)}] {msg}\n")
                except Exception:
                    pass

            qInstallMessageHandler(_qt_msg)
    except Exception:
        pass

    def _on_quit():
        try:
            if _rt:
                _rt.write(f"[EXIT] aboutToQuit {time.strftime('%H:%M:%S')}\n")
        except Exception:
            pass

    app.aboutToQuit.connect(_on_quit)
    win.show()
    # 测试模式：窗口挪出屏幕，避免人工观察干扰（存活/崩溃可客观判定）
    if "--offscreen-test" in sys.argv:
        try:
            win.move(-32000, -32000)
        except Exception:
            pass
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
