#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iPhone Bridge - 电脑端服务
- 通过 USB(usbmux) 把本机端口转发到手机 App 内置的 HTTP 服务
- 提供本地 Web 控制台：剪贴板双向同步 / 文件互传 / App 管理 / 设备工具
只依赖标准库 + pymobiledevice3
"""
import base64
import ctypes
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(ROOT, "web")
WEB_PORT = 8770
PHONE_PORT = 17899         # 手机 App 监听的端口
LOCAL_PORT = 17899         # 转发到本机的端口
PY = sys.executable
TMPDIR = tempfile.gettempdir()
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

_logs = []
_log_lock = threading.Lock()


def log(msg):
    line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
    with _log_lock:
        _logs.append(line)
        del _logs[:-500]
    try:
        print(line, flush=True)
    except Exception:
        pass


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           creationflags=CREATE_NO_WINDOW)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return -1, str(e)


# ---------------------------------------------------------------- 剪贴板 (Win32)
_user32 = ctypes.windll.user32 if os.name == "nt" else None
_kernel32 = ctypes.windll.kernel32 if os.name == "nt" else None
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

if _user32:
    # 64 位必须声明签名，否则句柄被截断成 int32，GlobalLock 返回 NULL
    _kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    _kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    _kernel32.GlobalLock.restype = wintypes.LPVOID
    _kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    _kernel32.GlobalUnlock.restype = wintypes.BOOL
    _kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    _kernel32.GlobalFree.restype = wintypes.HGLOBAL
    _kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]

    _user32.OpenClipboard.restype = wintypes.BOOL
    _user32.OpenClipboard.argtypes = [wintypes.HWND]
    _user32.CloseClipboard.restype = wintypes.BOOL
    _user32.EmptyClipboard.restype = wintypes.BOOL
    _user32.IsClipboardFormatAvailable.restype = wintypes.BOOL
    _user32.IsClipboardFormatAvailable.argtypes = [wintypes.UINT]
    _user32.GetClipboardData.restype = wintypes.HANDLE
    _user32.GetClipboardData.argtypes = [wintypes.UINT]
    _user32.SetClipboardData.restype = wintypes.HANDLE
    _user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]


def pc_clip_get():
    if not _user32:
        return ""
    for _ in range(8):
        if _user32.OpenClipboard(None):
            try:
                if not _user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
                    return ""
                h = _user32.GetClipboardData(CF_UNICODETEXT)
                if not h:
                    return ""
                ptr = _kernel32.GlobalLock(h)
                if not ptr:
                    return ""
                try:
                    return ctypes.wstring_at(ptr)
                finally:
                    _kernel32.GlobalUnlock(h)
            finally:
                _user32.CloseClipboard()
        time.sleep(0.05)
    return ""


def pc_clip_set(text):
    if not _user32:
        return False
    data = ctypes.create_unicode_buffer(text)
    size = ctypes.sizeof(data)
    for _ in range(8):
        if _user32.OpenClipboard(None):
            try:
                _user32.EmptyClipboard()
                h = _kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
                if not h:
                    return False
                ptr = _kernel32.GlobalLock(h)
                if not ptr:
                    _kernel32.GlobalFree(h)
                    return False
                ctypes.memmove(ptr, data, size)
                _kernel32.GlobalUnlock(h)
                if not _user32.SetClipboardData(CF_UNICODETEXT, h):
                    _kernel32.GlobalFree(h)
                    return False
                return True
            except Exception as e:
                log("写剪贴板失败: %s" % e)
                return False
            finally:
                _user32.CloseClipboard()
        time.sleep(0.05)
    return False


# ---------------------------------------------------------------- usbmux / 隧道
class Tunnel:
    def __init__(self):
        self.proc = None
        self.started_at = 0
        self.lines = []

    @property
    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        if self.running:
            return True
        cmd = [PY, "-m", "pymobiledevice3", "usbmux", "forward",
               str(LOCAL_PORT), str(PHONE_PORT)]
        env = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, encoding="utf-8", errors="replace",
                                         env=env, creationflags=CREATE_NO_WINDOW)
        except Exception as e:
            log("隧道启动失败: %s" % e)
            return False
        self.started_at = time.time()
        self.lines = []
        threading.Thread(target=self._pump, daemon=True).start()
        log("端口转发 %d -> 手机 %d 已启动" % (LOCAL_PORT, PHONE_PORT))
        return True

    def _pump(self):
        try:
            for line in self.proc.stdout:
                line = line.rstrip()
                if line:
                    self.lines.append(line)
                    del self.lines[:-40]
        except Exception:
            pass

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except Exception:
                pass
        self.proc = None
        log("端口转发已停止")


tunnel = Tunnel()


def pmd3_ok():
    rc, out = run([PY, "-c", "import pymobiledevice3"], timeout=40)
    return rc == 0, out.strip()[-300:]


def list_devices():
    rc, out = run([PY, "-m", "pymobiledevice3", "usbmux", "list"], timeout=30)
    if rc != 0:
        hint = ""
        if "usbmuxd" in out.lower():
            hint = "电脑上没有苹果 USB 服务（AppleMobileDeviceService），请先装 iTunes 或 Microsoft Store 的「Apple 设备」"
        return {"ok": False, "error": out.strip()[-500:], "hint": hint, "devices": []}
    devices, cur = [], None
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^(?:UDID|SerialNumber)\s*[:=]\s*([0-9A-Za-z\-]+)", s, re.I)
        if m:
            cur = {"udid": m.group(1)}
            devices.append(cur)
            continue
        if cur is not None and ":" in s:
            k, v = s.split(":", 1)
            key = k.strip().lower().replace(" ", "_")
            if key and v.strip():
                cur[key] = v.strip()
    return {"ok": True, "devices": devices, "raw": out.strip()[-1200:]}


def phone(path, method="GET", body=None, timeout=8):
    url = "http://127.0.0.1:%d%s" % (LOCAL_PORT, path)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace") or "{}")
    except Exception as e:
        return {"ok": False, "error": "%s" % e}


def phone_alive():
    r = phone("/health", timeout=2.5)
    return bool(r.get("ok"))


# ---------------------------------------------------------------- 原生服务（不依赖手机 App）
SHOT_TMP = os.path.join(TMPDIR, "ib_shot.png")


def pmd3(args, timeout=90):
    return run([PY, "-m", "pymobiledevice3"] + [str(a) for a in args], timeout=timeout)


def run_partial(cmd, seconds=3.0):
    """跑一会儿就杀掉，保留已产出的输出（用于 syslog 这类长驻命令）"""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, encoding="utf-8", errors="replace",
                             creationflags=CREATE_NO_WINDOW)
    except Exception as e:
        return -1, str(e)
    try:
        out, _ = p.communicate(timeout=seconds)
        return p.returncode or 0, out or ""
    except subprocess.TimeoutExpired:
        try:
            p.kill()
        except Exception:
            pass
        out, _ = p.communicate()
        return 0, out or ""


INFO_KEYS = {
    "DeviceName": "名称", "ProductType": "型号", "ProductVersion": "系统版本",
    "BuildVersion": "构建号", "SerialNumber": "序列号", "UniqueDeviceID": "UDID",
    "HardwareModel": "硬件型号", "CPUArchitecture": "架构", "RegionInfo": "地区",
    "TimeZone": "时区", "PasswordProtected": "已设密码", "ActivationState": "激活状态",
}


def native_info():
    rc, out = pmd3(["lockdown", "info"], timeout=60)
    if rc != 0:
        return {"ok": False, "error": out.strip()[-500:]}
    items = []
    for line in out.splitlines():
        s = line.replace("│", " ").replace("┃", " ").replace("─", " ").rstrip()
        if not s or ":" not in s or s.startswith(" "):
            continue
        k, v = s.split(":", 1)
        k, v = k.strip(), v.strip()
        if k in INFO_KEYS and v and not v.startswith("{") and len(v) < 120:
            items.append({"k": INFO_KEYS[k], "v": v})
    return {"ok": True, "items": items, "raw": out.strip()[:3000]}


def native_shot():
    if os.path.exists(SHOT_TMP):
        try:
            os.remove(SHOT_TMP)
        except Exception:
            pass
    tries = [
        ["developer", "screenshot", SHOT_TMP],
        ["developer", "dvt", "screenshot", SHOT_TMP],
    ]
    err = ""
    for t in tries:
        rc, out = pmd3(t, timeout=120)
        if os.path.exists(SHOT_TMP) and os.path.getsize(SHOT_TMP) > 2000:
            with open(SHOT_TMP, "rb") as f:
                b = f.read()
            log("截图成功 %d 字节" % len(b))
            return {"ok": True, "data": base64.b64encode(b).decode(), "size": len(b)}
        err = out.strip()[-400:]
        if "DeveloperDiskImage" in out or "ddi" in out.lower():
            log("尝试自动挂载开发者镜像…")
            pmd3(["mounter", "auto-mount"], timeout=180)
    return {"ok": False, "error": err or "截图失败", "hint": "需要先挂载开发者镜像，或系统版本不支持 DVT 截图"}


def afc(args, timeout=90):
    return pmd3(["afc"] + args, timeout=timeout)


def native_ls(path):
    rc, out = afc(["ls", path], timeout=60)
    if rc != 0:
        return {"ok": False, "error": out.strip()[-400:]}
    items = []
    for line in out.splitlines():
        s = line.rstrip()
        if not s.strip():
            continue
        is_dir = s.strip().endswith("/")
        name = s.strip().rstrip("/").split("/")[-1]
        if name in (".", "..", "") or name.startswith("total"):
            continue
        items.append({"name": name, "dir": is_dir, "size": -1})
    parent = path.rstrip("/").rsplit("/", 1)[0] or "/"
    return {"ok": True, "path": path, "parent": parent, "items": items}


def native_get(path):
    local = os.path.join(TMPDIR, "ib_pull.tmp")
    if os.path.exists(local):
        try:
            os.remove(local)
        except Exception:
            pass
    rc, out = afc(["pull", path, local], timeout=180)
    if not os.path.exists(local):
        return {"ok": False, "error": out.strip()[-400:] or "拉取失败"}
    size = os.path.getsize(local)
    if size > 64 * 1024 * 1024:
        os.remove(local)
        return {"ok": False, "error": "文件超过 64MB"}
    with open(local, "rb") as f:
        b = f.read()
    try:
        os.remove(local)
    except Exception:
        pass
    return {"ok": True, "size": size, "name": path.rsplit("/", 1)[-1],
            "data": base64.b64encode(b).decode()}


def native_put(path, b64):
    local = os.path.join(TMPDIR, "ib_push.tmp")
    try:
        with open(local, "wb") as f:
            f.write(base64.b64decode(b64))
    except Exception as e:
        return {"ok": False, "error": "解码失败 %s" % e}
    rc, out = afc(["push", local, path], timeout=300)
    ok = rc == 0
    return {"ok": ok, "error": "" if ok else out.strip()[-400:], "path": path}


def native_apps():
    rc, out = pmd3(["apps", "list"], timeout=90)
    if rc != 0:
        return {"ok": False, "error": out.strip()[-400:], "apps": []}
    apps = []
    for line in out.splitlines():
        s = line.strip()
        m = re.match(r"^([A-Za-z0-9._\-]{4,})$", s)
        if m:
            apps.append({"bundle": m.group(1), "name": m.group(1)})
    return {"ok": True, "apps": apps, "raw": out.strip()[:2500]}


def native_syslog(seconds=3):
    rc, out = run_partial([PY, "-m", "pymobiledevice3", "syslog", "live"], seconds)
    lines = [l for l in out.splitlines() if l.strip()]
    return {"ok": True, "lines": lines[-200:]}


def native_cmd(args):
    """只允许调用 pymobiledevice3 子命令，不执行任意 shell"""
    if not args:
        return {"ok": False, "error": "缺少参数"}
    bad = set("|&;><`$\n")
    if any(c in " ".join(args) for c in bad):
        return {"ok": False, "error": "参数包含非法字符"}
    rc, out = pmd3(args, timeout=120)
    return {"ok": rc == 0, "code": rc, "out": out[-8000:]}



# ---------------------------------------------------------------- 剪贴板同步
class Sync:
    def __init__(self):
        self.enabled = False
        self.phone_hash = ""
        self.pc_hash = ""
        self.history = []
        self.paused_until = 0
        self.err = ""
        self.last_sync = 0

    def start(self):
        self.enabled = True
        log("剪贴板自动同步已开启")

    def stop(self):
        self.enabled = False
        log("剪贴板自动同步已关闭")

    def add_history(self, side, text):
        if not text:
            return
        if self.history and self.history[0]["side"] == side and self.history[0]["text"] == text:
            return
        self.history.insert(0, {"side": side, "text": text[:20000],
                                "t": time.strftime("%H:%M:%S")})
        del self.history[40:]


sync = Sync()


def sync_loop():
    while True:
        time.sleep(1.0)
        if not sync.enabled:
            continue
        try:
            # 手机 -> 电脑
            r = phone("/clipboard", timeout=3)
            if not r.get("ok"):
                sync.err = r.get("error", "")[:160]
                continue
            sync.err = ""
            text = r.get("text") or ""
            cc = str(r.get("change_count", ""))
            key = "%s|%s" % (cc, len(text))
            if cc and key != sync.phone_hash and text:
                sync.phone_hash = key
                if text != pc_clip_get():
                    pc_clip_set(text)
                    sync.pc_hash = "pc|" + str(hash(text))
                    sync.add_history("phone", text)
                    sync.last_sync = time.time()
                    log("手机 -> 电脑 剪贴板 %d 字" % len(text))
            # 电脑 -> 手机
            ptext = pc_clip_get()
            pkey = "pc|%d|%d" % (hash(ptext), len(ptext))
            if pkey != sync.pc_hash and ptext and ptext != text:
                sync.pc_hash = pkey
                res = phone("/clipboard", "POST", {"text": ptext}, timeout=4)
                if res.get("ok"):
                    sync.phone_hash = "%s|%d" % (res.get("change_count", ""), len(ptext))
                    sync.add_history("pc", ptext)
                    sync.last_sync = time.time()
                    log("电脑 -> 手机 剪贴板 %d 字" % len(ptext))
                else:
                    sync.pc_hash = ""
        except Exception as e:
            sync.err = str(e)[:160]


# ---------------------------------------------------------------- HTTP 服务
class Handler(BaseHTTPRequestHandler):
    server_version = "iPhoneBridge/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, data, ctype="application/json; charset=utf-8"):
        if isinstance(data, (dict, list)):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        elif isinstance(data, str):
            data = data.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:
            pass

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n).decode("utf-8") or "{}") if n else {}
        except Exception:
            return {}

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            fp = os.path.join(WEB_DIR, "index.html")
            if os.path.exists(fp):
                with open(fp, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            return self._send(500, {"ok": False, "error": "web/index.html 缺失"})
        if u.path == "/api/status":
            return self._send(200, self.status())
        if u.path == "/api/logs":
            with _log_lock:
                return self._send(200, {"ok": True, "logs": list(_logs)})
        if u.path == "/api/clipboard/pc":
            return self._send(200, {"ok": True, "text": pc_clip_get()})
        if u.path == "/api/clipboard/history":
            return self._send(200, {"ok": True, "history": sync.history})

        # ---- 原生模式（不需要手机端 App）----
        if u.path == "/api/native/info":
            return self._send(200, native_info())
        if u.path == "/api/native/shot":
            return self._send(200, native_shot())
        if u.path == "/api/native/apps":
            return self._send(200, native_apps())
        if u.path == "/api/native/syslog":
            return self._send(200, native_syslog(3))
        if u.path == "/api/native/ls":
            q = parse_qs(u.query)
            return self._send(200, native_ls((q.get("path") or ["/"])[0]))
        return self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        b = self._body()
        p = u.path

        if p == "/api/tunnel":
            action = b.get("action")
            if action == "start":
                ok = tunnel.start()
                time.sleep(0.6)
                return self._send(200, {"ok": ok, "status": self.status()})
            tunnel.stop()
            return self._send(200, {"ok": True, "status": self.status()})

        if p == "/api/sync":
            if b.get("enabled"):
                sync.start()
            else:
                sync.stop()
            return self._send(200, {"ok": True, "sync": self.sync_state()})

        if p == "/api/clipboard/pc":
            text = b.get("text") or ""
            ok = pc_clip_set(text)
            if ok and text:
                # 清空指纹，让同步线程把这段新内容推到手机
                sync.pc_hash = ""
                sync.add_history("pc", text)
            return self._send(200, {"ok": ok})

        if p == "/api/clipboard/pull":
            r = phone("/clipboard", timeout=6)
            if r.get("ok") and r.get("text"):
                pc_clip_set(r["text"])
                sync.phone_hash = "%s|%d" % (r.get("change_count", ""), len(r["text"]))
                sync.pc_hash = "pc|%d|%d" % (hash(r["text"]), len(r["text"]))
                sync.add_history("phone", r["text"])
            return self._send(200, r)

        if p == "/api/clipboard/push":
            text = b.get("text") or ""
            r = phone("/clipboard", "POST", {"text": text}, timeout=8)
            if r.get("ok"):
                sync.phone_hash = "%s|%d" % (r.get("change_count", ""), len(text))
                sync.add_history("pc", text)
            return self._send(200, r)

        # ---- 原生模式（不需要手机端 App）----
        if p == "/api/native/get":
            return self._send(200, native_get(b.get("path") or "/"))
        if p == "/api/native/put":
            return self._send(200, native_put(b.get("path") or "", b.get("data") or ""))
        if p == "/api/native/cmd":
            return self._send(200, native_cmd(b.get("args") or []))

        # 通用代理：前端可直接调用手机端任意接口
        if p == "/api/phone":
            path = b.get("path") or "/health"
            method = (b.get("method") or "GET").upper()
            body = b.get("body")
            timeout = float(b.get("timeout") or 15)
            return self._send(200, phone(path, method, body, timeout))

        return self._send(404, {"ok": False, "error": "not found"})

    def sync_state(self):
        return {
            "enabled": sync.enabled,
            "phone_hash": sync.phone_hash,
            "last_sync": sync.last_sync,
            "error": sync.err,
            "count": len(sync.history),
        }

    def status(self):
        ok, err = pmd3_ok()
        dev = list_devices() if ok else {"ok": False, "devices": [], "error": err}
        alive = phone_alive()
        info = {}
        if alive:
            info = phone("/info", timeout=4) or {}
        return {
            "ok": True,
            "driver": {"pymobiledevice3": ok, "error": err},
            "devices": dev,
            "tunnel": {"running": tunnel.running, "local": LOCAL_PORT,
                       "remote": PHONE_PORT, "lines": tunnel.lines[-6:]},
            "phone": {"connected": alive, "info": info},
            "sync": self.sync_state(),
            "pc_clipboard_len": len(pc_clip_get() or ""),
        }


def main():
    threading.Thread(target=sync_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", WEB_PORT), Handler)
    log("控制台: http://127.0.0.1:%d" % WEB_PORT)
    threading.Timer(1.2, lambda: webbrowser.open("http://127.0.0.1:%d" % WEB_PORT)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        tunnel.stop()


if __name__ == "__main__":
    main()
