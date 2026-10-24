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

    // IOHIDEventCreateDigitizerFingerEvent —— 真实签名 13 参，坐标/压力是 Double（IOHIDFloat=double）！
    private typealias FnFinger = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Bool, Bool, UInt32
    ) -> UnsafeRawPointer?

    // IOHIDEventCreateDigitizerEvent —— 15 参，坐标/压力 Double
    private typealias FnDigitizer = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Bool, Bool, UInt32
    ) -> UnsafeRawPointer?

    // IOHIDEventCreateKeyboardEvent
    private typealias FnKeyboard = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt16, UInt16, Bool, UInt32
    ) -> UnsafeRawPointer?

    private typealias FnClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    // 真实签名: IOHIDEventSystemClientCreateWithType(alloc, CFStringRef type, CFErrorRef*)
    private typealias FnClientCreateWithType = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias FnDispatch = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
    // IOHIDEventSetInteger(event, field, value)  CFIndex=64位
    private typealias FnSetInt = @convention(c) (UnsafeRawPointer?, UInt32, Int64) -> Void
    // IOHIDEventAppendEvent(parent, child, options)
    private typealias FnAppend = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt32) -> UnsafeRawPointer?
    // BackBoardServices
    private typealias FnBksCtx = @convention(c) () -> UInt32
    private typealias FnBksInfo5 = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Bool, UnsafeRawPointer?) -> Void
    private typealias FnBksInfo7 = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Bool, UnsafeRawPointer?, Double, Double) -> Void
    // IOHIDEventSetSenderID(event, UInt64)
    private typealias FnSetSender = @convention(c) (UnsafeRawPointer?, UInt64) -> Void
    // IOHIDEventSetIntegerValueWithOptions(event, field, value, options)
    private typealias FnSetIntOpts = @convention(c) (UnsafeRawPointer?, UInt32, Int64, Int64) -> Void
    // IOHIDEventSetFloatValue(event, field, IOHIDFloat=Double)
    private typealias FnSetFloat = @convention(c) (UnsafeRawPointer?, UInt32, Double) -> Void

    private var fnFinger: FnFinger?
    private var fnDigitizer: FnDigitizer?
    private var fnKeyboard: FnKeyboard?
    private var fnClient: FnClientCreate?
    private var fnClientWithType: FnClientCreateWithType?
    private var fnDispatch: FnDispatch?
    private var fnSetInt: FnSetInt?
    private var fnAppend: FnAppend?
    private var fnBksCtx: FnBksCtx?
    private var fnBksInfo5: FnBksInfo5?
    private var fnBksInfo7: FnBksInfo7?
    private var fnSetSender: FnSetSender?
    private var fnSetIntOpts: FnSetIntOpts?
    private var fnSetFloat: FnSetFloat?
    private var client: UnsafeRawPointer?

    private let lock = NSLock()

    /// 触摸事件 SenderID（TrollVNC 验证值）：
    /// 0x10000027F = Voice-Over 专用（触摸会被忽略！）；0xDEFACEDBEEFFECE5 已过期；
    /// 0x8000000817319371 = iOS 9+；0x8000000817319372 = iOS 14.8 ~ iOS 26
    var senderID: UInt64 = 0x8000000817319372

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
        if let p = dlsym(h, "IOHIDEventSetInteger") {
            fnSetInt = unsafeBitCast(p, to: FnSetInt.self)
        }
        if let p = dlsym(h, "IOHIDEventAppendEvent") {
            fnAppend = unsafeBitCast(p, to: FnAppend.self)
        }
        if let p = dlsym(h, "IOHIDEventSetSenderID") {
            fnSetSender = unsafeBitCast(p, to: FnSetSender.self)
        }
        if let p = dlsym(h, "IOHIDEventSetIntegerValueWithOptions") {
            fnSetIntOpts = unsafeBitCast(p, to: FnSetIntOpts.self)
        }
        if let p = dlsym(h, "IOHIDEventSetFloatValue") {
            fnSetFloat = unsafeBitCast(p, to: FnSetFloat.self)
        }

        // BackBoardServices：数字触摸事件必须带屏幕 contextID 才能被路由
        for path in ["/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices"] {
            if let b = dlopen(path, RTLD_LAZY) {
                if let p = dlsym(b, "BKSDisplayServerGetMainDisplayContextId") {
                    fnBksCtx = unsafeBitCast(p, to: FnBksCtx.self)
                    Log.add("HID: bks ctx ok")
                }
                if let p = dlsym(b, "BKSHIDEventSetDigitizerInfo") {
                    fnBksInfo5 = unsafeBitCast(p, to: FnBksInfo5.self)
                    fnBksInfo7 = unsafeBitCast(p, to: FnBksInfo7.self)
                    Log.add("HID: bks setDigitizerInfo ok")
                }
                break
            }
        }

        Log.add("HID: ready=\(ready) finger=\(fnFinger != nil) digitizer=\(fnDigitizer != nil) dispatch=\(fnDispatch != nil)")
        ensureClient()
    }

    // MARK: - 客户端

    /// 新建系统 HID 客户端。类型必须是 CFString（"monitor"/"admin"），
    /// 全局注入走 monitor 类型 + hid.* 权限；后台时旧 client 会被系统失效，
    /// 因此每次动作前都重建。
    private func makeClient() -> UnsafeRawPointer? {
        // default 已实测可后台派发（monitor 只能监听），故 default 最优先
        if let f = fnClient {
            if let c = f(nil) {
                Log.add("HID: client type=default ok")
                return c
            }
        }
        let types: [CFString] = ["admin" as CFString, "monitor" as CFString, "post" as CFString]
        if let f = fnClientWithType {
            for t in types {
                let p = unsafeBitCast(t, to: UnsafeRawPointer.self)
                if let c = f(nil, p, nil) {
                    Log.add("HID: client type=\(t) ok")
                    return c
                }
            }
        }
        return nil
    }

    private func ensureClient() {
        if client == nil {
            client = makeClient()
        }
    }

    // MARK: - 客户端类型探测（/hidtest）
    /// 用指定类型的临时客户端派发一个事件，不动主 client。
    /// monitor 可能只能监听不能派发；default/admin/post/passive 逐个试。
    private func probeClient(_ raw: String) -> UnsafeRawPointer? {
        if raw == "default" {
            return fnClient.flatMap { $0(nil) }
        }
        guard let f = fnClientWithType else { return nil }
        let t = raw as CFString
        return f(nil, unsafeBitCast(t, to: UnsafeRawPointer.self), nil)
    }

    func probe(kind raw: String, page: UInt16, usage: UInt16) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let f = fnKeyboard, let d = fnDispatch else {
            return ["ok": false, "error": "键盘函数缺失"]
        }
        guard let c = probeClient(raw) else {
            return ["ok": false, "type": raw, "error": "client 创建失败"]
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(c).release() }
        if let ev = f(nil, mach_absolute_time(), page, usage, true, 0) {
            d(c, ev)
        }
        usleep(40_000)
        if let ev = f(nil, mach_absolute_time(), page, usage, false, 0) {
            d(c, ev)
        }
        return ["ok": true, "type": raw, "action": "key", "page": Int(page), "usage": Int(usage)]
    }

    func probeTap(kind raw: String, x: CGFloat, y: CGFloat, sender: UInt64? = nil) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let saved = senderID
        if let s = sender { senderID = s }
        defer { senderID = saved }
        guard let d = fnDispatch else { return ["ok": false, "error": "dispatch 缺失"] }
        guard let c = probeClient(raw) else {
            return ["ok": false, "type": raw, "error": "client 创建失败"]
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(c).release() }
        guard let ev = makeTouch(.down, px: x, py: y) else {
            return ["ok": false, "error": "事件构造失败"]
        }
        d(c, ev)
        Unmanaged<CFTypeRef>.fromOpaque(ev).release()
        usleep(60_000)
        guard let up = makeTouch(.lift, px: x, py: y) else {
            return ["ok": false, "error": "事件构造失败"]
        }
        d(c, up)
        Unmanaged<CFTypeRef>.fromOpaque(up).release()
        return ["ok": true, "type": raw, "action": "tap"]
    }

    /// BKS 路径：数字触摸事件附上主屏 contextID 后派发（Veency 同款）。
    /// variant: 5/7 两种 ABI 参数个数都试。
    func probeTapBKS(x: CGFloat, y: CGFloat, variant: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let d = fnDispatch else { return ["ok": false, "error": "dispatch 缺失"] }
        guard let ctxFn = fnBksCtx else { return ["ok": false, "error": "BKSDisplayServerGetMainDisplayContextId 缺失"] }
        let ctxId = ctxFn()
        guard let c = fnClient.flatMap({ $0(nil) }) else { return ["ok": false, "error": "default client 创建失败"] }
        defer { Unmanaged<CFTypeRef>.fromOpaque(c).release() }

        func bks(_ ev: UnsafeRawPointer?) {
            guard let ev = ev else { return }
            switch variant {
            case 5: fnBksInfo5?(ev, ctxId, 0, false, nil)
            case 7: fnBksInfo7?(ev, ctxId, 0, false, nil, 0, 0)
            default: break
            }
        }

        guard let ev = makeTouch(.down, px: x, py: y) else {
            return ["ok": false, "error": "事件构造失败"]
        }
        bks(ev)
        d(c, ev)
        Unmanaged<CFTypeRef>.fromOpaque(ev).release()
        usleep(60_000)
        guard let up = makeTouch(.lift, px: x, py: y) else {
            return ["ok": false, "error": "事件构造失败"]
        }
        bks(up)
        d(c, up)
        Unmanaged<CFTypeRef>.fromOpaque(up).release()
        return ["ok": true, "type": "default-bks", "action": "tapbks", "variant": variant, "ctxId": Int(ctxId)]
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

    // MARK: - 触摸事件构造（TrollVNC 验证实现移植）

    // IOHIDEventField 常量（编码 = (事件类型<<16)|偏移，Digitizer 类型=11）
    private let kFieldIsBuiltIn: UInt32 = 4                  // (0<<16)|4
    private let kFieldDigitizerMajorRadius: UInt32 = 720_900 // (11<<16)|20 = 0xB0014
    private let kFieldDigitizerMinorRadius: UInt32 = 720_901 // 0xB0015
    private let kFieldDigitizerIsDisplayIntegrated: UInt32 = 720_921 // 0xB0019

    // IOHIDDigitizerEventMask
    private let evRange: UInt32 = 0x01
    private let evTouch: UInt32 = 0x02
    private let evPosition: UInt32 = 0x04
    private let evIdentity: UInt32 = 0x20
    private let evAttribute: UInt32 = 0x40

    /// kIOHIDDigitizerTransducerTypeHand = 3
    private let transducerHand: UInt32 = 3
    /// 手指标识（TrollVNC: index=identity=同一 fingerID，从 2 开始）
    private let fingerID: UInt32 = 2
    /// TrollVNC 默认手指半径 = 5
    private let defaultRadius: Double = 5

    private enum TouchPhaseKind { case down, move, lift }

    /// TrollVNC 同款：Hand 父事件带 phase 对应 eventMask + finger 子事件，
    /// 归一化 Double 坐标，radius=5，twist=90。
    private func makeTouch(_ phase: TouchPhaseKind, px: CGFloat, py: CGFloat) -> UnsafeRawPointer? {
        guard let dg = fnDigitizer, let fg = fnFinger else { return nil }
        let size = screenSize
        let x = Double(px / max(size.width, 1))
        let y = Double(py / max(size.height, 1))
        let ts = mach_absolute_time()

        // hand 层：down/lift → Touch|Identity；move → Position|Attribute
        let touching = phase != .lift
        let handMask: UInt32
        switch phase {
        case .down, .lift: handMask = evTouch | evIdentity
        case .move:        handMask = evPosition | evAttribute
        }
        // 创建：transducer=3, index=0, identity=0, button=0, x/y/z/pressure/twist=0, range=false, touch=touching
        guard let hand = dg(nil, ts, transducerHand, 0, 0, handMask, 0,
                            0, 0, 0, 0, 0, false, touching, 0) else { return nil }
        fnSetInt?(hand, kFieldIsBuiltIn, 1)
        fnSetInt?(hand, kFieldDigitizerIsDisplayIntegrated, 1)
        fnSetSender?(hand, senderID)

        // finger 层：与 hand 同 mask；down/move → range=touch=true，lift → false
        guard let finger = fg(nil, ts, fingerID, fingerID, handMask,
                              x, y, 0, 0, 90, touching, touching, 0) else {
            Unmanaged<CFTypeRef>.fromOpaque(hand).release()
            return nil
        }
        let radius: Double = touching ? defaultRadius : 0
        fnSetFloat?(finger, kFieldDigitizerMajorRadius, radius)
        fnSetFloat?(finger, kFieldDigitizerMinorRadius, radius)
        _ = fnAppend?(hand, finger, 0)
        Unmanaged<CFTypeRef>.fromOpaque(finger).release() // append 已 retain
        return hand
    }

    private func dispatchTouch(_ phase: TouchPhaseKind, px: CGFloat, py: CGFloat) {
        guard let ev = makeTouch(phase, px: px, py: py) else { return }
        dispatchTo(client, ev)
    }

    private func dispatchTo(_ c: UnsafeRawPointer?, _ ev: UnsafeRawPointer?) {
        guard let ev = ev, let d = fnDispatch, let c = c else {
            if let ev = ev { Unmanaged<CFTypeRef>.fromOpaque(ev).release() }
            return
        }
        d(c, ev)
        Unmanaged<CFTypeRef>.fromOpaque(ev).release()
    }

    // MARK: - 对外动作

    @discardableResult
    func tap(x: CGFloat, y: CGFloat) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        ensureClient()
        dispatchTouch(.down, px: x, py: y)
        usleep(60_000)
        dispatchTouch(.lift, px: x, py: y)
        return true
    }

    @discardableResult
    func longPress(x: CGFloat, y: CGFloat, seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        ensureClient()
        dispatchTouch(.down, px: x, py: y)
        let deadline = Date().addingTimeInterval(max(0.2, min(seconds, 10)))
        while Date() < deadline {
            usleep(120_000)
            dispatchTouch(.move, px: x, py: y)
        }
        dispatchTouch(.lift, px: x, py: y)
        return true
    }

    @discardableResult
    func swipe(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, duration: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return false }
        ensureClient()
        dispatchTouch(.down, px: x1, py: y1)

        let steps = max(8, Int(duration * 60))
        let dt = max(4_000, Int(duration / Double(steps) * 1_000_000))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let px = x1 + (x2 - x1) * t
            let py = y1 + (y2 - y1) * t
            dispatchTouch(.move, px: px, py: py)
            usleep(useconds_t(dt))
        }
        dispatchTouch(.lift, px: x2, py: y2)
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
