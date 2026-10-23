import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - 触摸 / 键盘注入（IOHIDEvent 私有接口）
//
// 巨魔安装后本 App 声明了 com.apple.private.hid.client.* 权限，
// 可以直接往系统 HID 事件流里注入手指与键盘事件，
// 效果等同于用户真的在屏幕上点/输入。
final class HID {

    static let shared = HID()

    private var handle: UnsafeMutableRawPointer?

    // IOHIDEventCreateDigitizerFingerEvent
    private typealias FnFinger = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
        Int32, Int32, Int32, Int32, Bool, Bool, UInt32
    ) -> UnsafeRawPointer?

    // IOHIDEventCreateDigitizerEvent
    private typealias FnDigitizer = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Int32, Int32, Int32, Int32, Int32, Bool, Bool, UInt32
    ) -> UnsafeRawPointer?

    // IOHIDEventCreateKeyboardEvent
    private typealias FnKeyboard = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt16, UInt16, Bool, UInt32
    ) -> UnsafeRawPointer?

    private typealias FnClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    // 真实签名: IOHIDEventSystemClientCreateWithType(alloc, CFStringRef type, CFErrorRef*)
    private typealias FnClientCreateWithType = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnDispatch = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void

    private var fnFinger: FnFinger?
    private var fnDigitizer: FnDigitizer?
    private var fnKeyboard: FnKeyboard?
    private var fnClient: FnClientCreate?
    private var fnClientWithType: FnClientCreateWithType?
    private var fnDispatch: FnDispatch?
    private var client: UnsafeRawPointer?

    private var touchIndex: UInt32 = 1
    private let lock = NSLock()

    var ready: Bool { fnDispatch != nil && (fnFinger != nil || fnDigitizer != nil) }

    private init() {
        // IOKit 里带着这些符号；用 dlsym 取，避免链接期缺符号
        for path in ["/System/Library/Frameworks/IOKit.framework/IOKit",
                     "/usr/lib/libIOKit.dylib"] {
            if let h = dlopen(path, RTLD_LAZY) {
                handle = h
                break
            }
        }
        guard let h = handle else { Log.add("HID: IOKit 加载失败"); return }

        if let p = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent") {
            fnFinger = unsafeBitCast(p, to: FnFinger.self)
        }
        if let p = dlsym(h, "IOHIDEventCreateDigitizerEvent") {
            fnDigitizer = unsafeBitCast(p, to: FnDigitizer.self)
        }
        if let p = dlsym(h, "IOHIDEventCreateKeyboardEvent") {
            fnKeyboard = unsafeBitCast(p, to: FnKeyboard.self)
        }
        if let p = dlsym(h, "IOHIDEventSystemClientCreate") {
            fnClient = unsafeBitCast(p, to: FnClientCreate.self)
        }
        if let p = dlsym(h, "IOHIDEventSystemClientCreateWithType") {
            fnClientWithType = unsafeBitCast(p, to: FnClientCreateWithType.self)
        }
        if let p = dlsym(h, "IOHIDEventSystemClientDispatchEvent") {
            fnDispatch = unsafeBitCast(p, to: FnDispatch.self)
        }

        Log.add("HID: ready=\(ready) finger=\(fnFinger != nil) digitizer=\(fnDigitizer != nil) dispatch=\(fnDispatch != nil)")
        ensureClient()
    }

    // MARK: - 客户端

    /// 新建系统 HID 客户端。类型必须是 CFString（"monitor"/"admin"），
    /// 全局注入走 monitor 类型 + hid.* 权限；后台时旧 client 会被系统失效，
    /// 因此每次动作前都重建。
    private func makeClient() -> UnsafeRawPointer? {
        let types: [CFString] = ["monitor", "admin"]
        if let f = fnClientWithType {
            for t in types {
                let p = unsafeBitCast(t, to: UnsafeRawPointer.self)
                if let c = f(nil, p, nil) {
                    Log.add("HID: client type=\(t) ok")
                    return c
                }
            }
        }
        if let f = fnClient {
            if let c = f(nil) {
                Log.add("HID: default client ok")
                return c
            }
        }
        return nil
    }

    private func ensureClient() {
        if client == nil {
            client = makeClient()
        }
    }

    private func renewClient() {
        if let old = client {
            Unmanaged<CFTypeRef>.fromOpaque(old).release()
            client = nil
        }
        client = makeClient()
    }

    // MARK: - 基础

    private var screenSize: CGSize {
        if Thread.isMainThread {
            return UIScreen.main.bounds.size
        }
        var s = CGSize(width: 390, height: 844)
        DispatchQueue.main.sync { s = UIScreen.main.bounds.size }
        return s
    }

    private func fixed(_ v: CGFloat) -> Int32 {
        let c = max(0.0, min(1.0, v))
        return Int32(c * 65536.0)
    }

    private func makeTouch(px: CGFloat, py: CGFloat, down: Bool, phase: UInt32) -> UnsafeRawPointer? {
        let size = screenSize
        let fx = fixed(px / max(size.width, 1))
        let fy = fixed(py / max(size.height, 1))
        let mask = phase
        let ts = mach_absolute_time()

        if let f = fnFinger {
            // (alloc, ts, index, identity, mask, x, y, z, pressure, range, touch, options)
            return f(nil, ts, touchIndex, touchIndex, mask, fx, fy, 0, 0, down, down, 0)
        }
        if let f = fnDigitizer {
            // type: kIOHIDDigitizerTransducerTypeFinger = 2
            return f(nil, ts, 2, touchIndex, touchIndex, mask, 0,
                     fx, fy, 0, 0, 0, down, down, 0)
        }
        return nil
    }

    private func dispatch(_ ev: UnsafeRawPointer?) {
        guard let ev = ev, let d = fnDispatch, let c = client else { return }
        d(c, ev)
        Unmanaged<CFTypeRef>.fromOpaque(ev).release()
    }

    // 事件掩码
    private let maskRange: UInt32 = 0x01
    private let maskTouch: UInt32 = 0x02
    private let maskPosition: UInt32 = 0x04

    // MARK: - 对外动作

    @discardableResult
    func tap(x: CGFloat, y: CGFloat) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        renewClient()
        touchIndex = touchIndex &+ 1
        // down
        dispatch(makeTouch(px: x, py: y, down: true, phase: maskRange | maskTouch | maskPosition))
        usleep(40_000)
        // up
        dispatch(makeTouch(px: x, py: y, down: false, phase: maskRange | maskTouch))
        return true
    }

    @discardableResult
    func longPress(x: CGFloat, y: CGFloat, seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        renewClient()
        touchIndex = touchIndex &+ 1
        dispatch(makeTouch(px: x, py: y, down: true, phase: maskRange | maskTouch | maskPosition))
        let deadline = Date().addingTimeInterval(max(0.2, min(seconds, 10)))
        while Date() < deadline {
            usleep(120_000)
            dispatch(makeTouch(px: x, py: y, down: true, phase: maskPosition | maskTouch | maskRange))
        }
        dispatch(makeTouch(px: x, py: y, down: false, phase: maskRange | maskTouch))
        return true
    }

    @discardableResult
    func swipe(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, duration: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        renewClient()
        touchIndex = touchIndex &+ 1
        dispatch(makeTouch(px: x1, py: y1, down: true, phase: maskRange | maskTouch | maskPosition))

        let steps = max(8, Int(duration * 60))
        let dt = max(4_000, Int(duration / Double(steps) * 1_000_000))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let px = x1 + (x2 - x1) * t
            let py = y1 + (y2 - y1) * t
            dispatch(makeTouch(px: px, py: py, down: true, phase: maskPosition | maskTouch | maskRange))
            usleep(useconds_t(dt))
        }
        dispatch(makeTouch(px: x2, py: y2, down: false, phase: maskRange | maskTouch))
        return true
    }

    /// 回到主屏：键盘 Home 键（全局生效）+ 底部上滑双保险
    @discardableResult
    func home() -> Bool {
        // Consumer 页 Home 键（page 0x0C usage 0x40 = Menu/Home）
        key(0x0C, 0x40, true)
        usleep(20_000)
        key(0x0C, 0x40, false)
        let s = screenSize
        return swipe(x1: s.width / 2, y1: s.height - 6, x2: s.width / 2, y2: s.height * 0.45, duration: 0.28)
    }

    // MARK: - 键盘

    private func key(_ page: UInt16, _ usage: UInt16, _ down: Bool) {
        guard let f = fnKeyboard, let d = fnDispatch else { return }
        ensureClient()
        guard let c = client else { return }
        if let ev = f(nil, mach_absolute_time(), page, usage, down, 0) {
            d(c, ev)
            Unmanaged<CFTypeRef>.fromOpaque(ev).release()
        }
    }

    /// US 布局：字符 -> (usage, 是否需要 Shift)
    private static let keyMap: [Character: (UInt16, Bool)] = [
        "a": (0x04, false), "b": (0x05, false), "c": (0x06, false), "d": (0x07, false),
        "e": (0x08, false), "f": (0x09, false), "g": (0x0A, false), "h": (0x0B, false),
        "i": (0x0C, false), "j": (0x0D, false), "k": (0x0E, false), "l": (0x0F, false),
        "m": (0x10, false), "n": (0x11, false), "o": (0x12, false), "p": (0x13, false),
        "q": (0x14, false), "r": (0x15, false), "s": (0x16, false), "t": (0x17, false),
        "u": (0x18, false), "v": (0x19, false), "w": (0x1A, false), "x": (0x1B, false),
        "y": (0x1C, false), "z": (0x1D, false),
        "1": (0x1E, false), "2": (0x1F, false), "3": (0x20, false), "4": (0x21, false),
        "5": (0x22, false), "6": (0x23, false), "7": (0x24, false), "8": (0x25, false),
        "9": (0x26, false), "0": (0x27, false),
        " ": (0x2C, false), "\n": (0x28, false), "\t": (0x2B, false),
        "-": (0x2D, false), "=": (0x2E, false), "[": (0x2F, false), "]": (0x30, false),
        "\\": (0x31, false), ";": (0x33, false), "'": (0x34, false), "`": (0x35, false),
        ",": (0x36, false), ".": (0x37, false), "/": (0x38, false),
        "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true),
        "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
        "(": (0x26, true), ")": (0x27, true),
        "_": (0x2D, true), "+": (0x2E, true), "{": (0x2F, true), "}": (0x30, true),
        "|": (0x31, true), ":": (0x33, true), "\"": (0x34, true), "~": (0x35, true),
        "<": (0x36, true), ">": (0x37, true), "?": (0x38, true)
    ]

    private static let shift: UInt16 = 0xE1
    private static let command: UInt16 = 0xE3

    /// 纯 ASCII 直接打；含中文等则先写剪贴板再 Cmd+V
    @discardableResult
    func type(_ text: String) -> [String: Any] {
        guard !text.isEmpty else { return ["ok": false, "error": "空文本"] }

        // 先确认每个字符都能用 US 键盘映射打出来
        var plan: [(UInt16, Bool)] = []
        var unmapped = false
        for ch in text {
            let low = Character(ch.lowercased())
            if let (u, s) = HID.keyMap[ch] {
                plan.append((u, s))
            } else if let (u, s) = HID.keyMap[low] {
                // 大写字母：小写用法 + Shift
                plan.append((u, ch.isUppercase ? true : s))
            } else {
                unmapped = true
                break
            }
        }

        if !unmapped && !plan.isEmpty {
            for (usage, needShift) in plan {
                if needShift { key(0x07, HID.shift, true) }
                key(0x07, usage, true)
                key(0x07, usage, false)
                if needShift { key(0x07, HID.shift, false) }
                usleep(8_000)
            }
            return ["ok": true, "via": "hid-keyboard", "count": plan.count]
        }

        // 含非 ASCII：剪贴板 + Cmd+V
        return paste(text)
    }

    /// 写剪贴板并发送 Cmd+V
    @discardableResult
    func paste(_ text: String) -> [String: Any] {
        var cc = 0
        if Thread.isMainThread {
            UIPasteboard.general.string = text
            cc = UIPasteboard.general.changeCount
        } else {
            DispatchQueue.main.sync {
                UIPasteboard.general.string = text
                cc = UIPasteboard.general.changeCount
            }
        }
        usleep(60_000)
        key(0x07, HID.command, true)
        usleep(12_000)
        key(0x07, 0x19, true)     // v
        usleep(12_000)
        key(0x07, 0x19, false)
        usleep(12_000)
        key(0x07, HID.command, false)
        return ["ok": true, "via": "clipboard-paste", "change_count": cc]
    }

    /// 单个物理键，用于回车/退格/退出等
    @discardableResult
    func press(_ name: String) -> Bool {
        let map: [String: UInt16] = [
            "return": 0x28, "enter": 0x28, "backspace": 0x2A, "delete": 0x2A,
            "escape": 0x29, "esc": 0x29, "space": 0x2C, "tab": 0x2B,
            "up": 0x52, "down": 0x51, "left": 0x50, "right": 0x4F
        ]
        guard let usage = map[name.lowercased()] else { return false }
        key(0x07, usage, true)
        usleep(15_000)
        key(0x07, usage, false)
        return true
    }
}
