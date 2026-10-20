# iPhone Bridge

电脑通过 **USB 数据线**控制 iPhone（iPhone 12 Pro / iOS 16.6.1 / 巨魔 TrollStore，**无需越狱**）。

```
┌──────────────┐   USB 线    ┌────────────────┐   TCP   ┌──────────────────┐
│ 电脑 Web 控制台 │ ─────────> │ Windows usbmuxd │ ──────> │ 手机端 Bridge App │
│ 127.0.0.1:8770│            │ Apple 驱动      │ iproxy  │ 内置 HTTP :17899   │
└──────────────┘            └────────────────┘         └──────────────────┘
```

已实现接口：剪贴板读写与双向自动同步、文件浏览/上传下载、应用列表与启动、
打开 URL / 运行快捷指令、亮度、音量、手电、震动、设备信息。

---

## 一、电脑端（已完成，可直接跑）

### 1. 装 Apple USB 驱动（必做，一次）
Windows 认 iPhone 线靠苹果的 `AppleMobileDeviceService`，二选一：

- **iTunes**：https://www.apple.com.cn/itunes/ （装完不用打开）
- 或 Microsoft Store 搜 **「Apple 设备 / Apple Devices」**

装完在 PowerShell 里确认：

```powershell
Get-Service AppleMobileDeviceService
```
状态应为 `Running`。没有它，插上线电脑也发现不了设备。

### 2. 启动
双击 `start.bat`。首次会自动建虚拟环境并装 `pymobiledevice3`，随后浏览器打开
`http://127.0.0.1:8770`。

### 3. 手机授权
插线 → 手机上点「信任此电脑」→ 输入锁屏密码。

### 4. 先用「原生模式」（不需要装任何手机 App）

控制台左侧最后一栏 **原生模式**，走的是苹果自带 USB 服务，插上线就能用：

| 能做的事 | 说明 |
|---|---|
| 读设备信息 | 型号/系统/序列号/UDID |
| 截图 | 首次会自动挂载开发者镜像，若系统不支持会明确报错 |
| 文件读写 | AFC 通道，`/DCIM` 相册、`/` 沙盒目录，可下载/上传 |
| 应用列表 | installation_proxy |
| 实时日志 | syslog 3 秒快照 |
| 任意子命令 | 输入 `pymobiledevice3` 的参数直接执行 |

**剪贴板必须装手机端 App**——iOS 没对外暴露剪贴板接口，这是系统限制，绕不过去。

---

## 二、手机端 App（需要构建一次，约 10 分钟）

电脑端已经写好，但手机端是个原生 App，必须在 macOS 环境编译一次。
**不需要买 Mac**，用 GitHub Actions 免费 macOS 机器即可：

1. 把本目录 `iphone-bridge` 传到 GitHub 新建仓库（私有库也行）
   —— 懒人做法：`bash push-to-github.sh https://github.com/你的账号/iphone-bridge.git`
2. 仓库自动触发 Actions（`.github/workflows/build-ipa.yml`）
3. 构建完成后在 Actions 页面底部下载 `iPhoneBridge-tipa` 工件，解压得到 `Bridge.tipa`
4. 把 `.tipa` 传到手机（微信/文件/AirDrop 都行），用 **TrollStore** 打开安装
5. 打开 App → 看到「HTTP 已监听 17899」即可

> 你自己有 Mac 的话，`cd ios && bash build.sh` 一步出包。
> 如果你的 GitHub 上传不便，也可以把 `ios/` 目录丢进任意 macOS 机器执行同一条命令。

### 装完必做的一步（让剪贴板读取静默）
iOS 16 起，App 读别的 App 的剪贴板会弹「允许粘贴」。
**设置 → 找到「Bridge」→ 从其他 App 粘贴 → 允许**，之后就再也不弹了。

### 保持在线
App 内置了静音音频保活，只要不手动上滑杀掉、不被系统重启就一直在后台。
手机重启后需要重新打开一次 App。

---

## 三、用法

1. `start.bat` 启动电脑端
2. 手机 App 保持后台
3. 网页「设备」页 → 点 **启动转发** → 显示「全链路就绪」
4. 「剪贴板」页打开 **自动双向同步**：手机复制 → 电脑剪贴板立刻有；
   电脑复制 → 手机剪贴板立刻有

---

## 四、目录

```
iphone-bridge/
├─ start.bat                 电脑端一键启动（自动建 venv、装依赖、检查驱动）
├─ push-to-github.sh         一条命令推仓库并触发云端构建
├─ pc/server.py              本地服务（端口转发 + 剪贴板同步 + 原生模式 + API 代理）
├─ web/index.html            Web 控制台
├─ ios/                      手机端 App（Swift，无第三方依赖）
│  ├─ Sources/main.swift     入口
│  ├─ Sources/App.swift      UI + 后台保活 + 音量
│  ├─ Sources/HTTP.swift     内置 HTTP 服务器（NWListener）
│  ├─ Sources/Router.swift   接口实现
│  ├─ Info.plist  entitlements.plist
│  └─ build.sh               一行出 .tipa
└─ .github/workflows/build-ipa.yml   云端免费构建
```

### 依赖
电脑端只用 `pymobiledevice3`（纯 Python，v11.x）。首次启动自动装，
国内走清华镜像；装不上不影响剪贴板功能，只是「原生模式」不可用。
已实测：Python 3.13 + pymobiledevice3 11.40.0 正常。

## 五、接口速查（端口 17899）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活检查 |
| GET | `/info` | 设备名/型号/系统/电量/亮度 |
| GET | `/clipboard` | 读手机剪贴板（含 change_count） |
| POST | `/clipboard` | `{"text":"..."}` 写手机剪贴板 |
| GET | `/apps` | 已安装应用列表 |
| POST | `/open` | `{"bundle":"com.tencent.xin"}` 或 `{"url":"..."}` |
| GET | `/ls?path=/var/mobile/Media` | 列目录 |
| GET | `/get?path=...` | 下载（base64，≤64MB） |
| POST | `/put` | `{"path":"...","data":"base64"}` 上传 |
| POST | `/brightness` `/volume` `/torch` `/vibrate` | 设备控制 |
| POST | `/shortcut` | `{"name":"快捷指令名"}` |

## 六、已知限制

- 全屏截图没做：系统级截屏需要 SpringBoard 私有权限，容易崩，暂不集成
- 应用启动优先用 `LSApplicationWorkspace`，个别 App 会失败
- 文件读写受 iOS 容器权限限制，`/var/mobile/Media`、`/var/mobile/Documents` 最稳
- 传输走 USB 但底层是 TCP，速度约 40–80 MB/s（受 usbmux 影响）
