import Foundation
import UIKit
import AVFoundation
import AudioToolbox

// MARK: - 私有 API 通用调用
enum ObjC {
    static func cls(_ name: String) -> AnyObject? {
        guard let c = NSClassFromString(name) else { return nil }
        return c as AnyObject
    }

    static func call(_ target: AnyObject?, _ name: String) -> AnyObject? {
        guard let t = target as? NSObjectProtocol else { return nil }
        let sel = NSSelectorFromString(name)
        guard t.responds(to: sel) else { return nil }
        return t.perform(sel)?.takeUnretainedValue()
    }

    static func call1(_ target: AnyObject?, _ name: String, _ a: AnyObject) -> AnyObject? {
        guard let t = target as? NSObjectProtocol else { return nil }
        let sel = NSSelectorFromString(name)
        guard t.responds(to: sel) else { return nil }
        return t.perform(sel, with: a)?.takeUnretainedValue()
    }

    static func call2(_ target: AnyObject?, _ name: String, _ a: AnyObject, _ b: AnyObject) -> AnyObject? {
        guard let t = target as? NSObjectProtocol else { return nil }
        let sel = NSSelectorFromString(name)
        guard t.responds(to: sel) else { return nil }
        return t.perform(sel, with: a, with: b)?.takeUnretainedValue()
    }
}

// MARK: - 路由
enum Router {

    static func handle(_ req: HTTPRequest) -> Data {
        let p = req.pathOnly
        Log.add("\(req.method) \(p)")

        switch p {
        case "/health":
            return ok(["ok": true, "app": "iPhoneBridge", "version": "1.0",
                       "port": Int(HTTPServer.shared.port)])

        case "/info":
            return json(deviceInfo())

        case "/clipboard":
            if req.method == "POST" {
                let text = (req.jsonBody["text"] as? String) ?? ""
                let cc: Int = onMain {
                    UIPasteboard.general.string = text
                    return UIPasteboard.general.changeCount
                }
                Log.add("写入剪贴板 \(text.count) 字")
                return ok(["ok": true, "change_count": cc])
            }
            let r: (String, Int) = onMain {
                (UIPasteboard.general.string ?? "", UIPasteboard.general.changeCount)
            }
            return ok(["ok": true, "text": r.0, "change_count": r.1, "length": r.0.count])

        case "/apps":
            return json(["ok": true, "apps": appList()])

        case "/open":
            let b = req.jsonBody
            if let bundle = b["bundle"] as? String {
                let r = openApp(bundle)
                return json(r)
            }
            if let u = b["url"] as? String {
                return json(openURL(u))
            }
            return fail("缺少 bundle 或 url")

        case "/url":
            return json(openURL((req.jsonBody["url"] as? String) ?? ""))

        case "/shortcut":
            let name = (req.jsonBody["name"] as? String) ?? ""
            guard !name.isEmpty else { return fail("缺少 name") }
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            return json(openURL("shortcuts://run-shortcut?name=\(enc)"))

        case "/ls":
            let path = req.query["path"] ?? "/var/mobile/Media"
            return json(listDir(path))

        case "/get":
            guard let path = req.query["path"] else { return fail("缺少 path") }
            return json(readFile(path))

        case "/put":
            let b = req.jsonBody
            guard let path = b["path"] as? String, let data = b["data"] as? String else {
                return fail("缺少 path / data")
            }
            return json(writeFile(path, base64: data))

        case "/brightness":
            let v = (req.jsonBody["value"] as? Double) ?? 0.5
            onMain { UIScreen.main.brightness = CGFloat(min(max(v, 0.0), 1.0)) }
            return ok(["ok": true, "value": v])

        case "/volume":
            let v = Float((req.jsonBody["value"] as? Double) ?? 0.5)
            let r: Bool = onMain { VolumeControl.shared.set(v) }
            return json(["ok": r, "error": r ? "" : "未找到系统音量控件"])

        case "/torch":
            let on = (req.jsonBody["on"] as? Bool) ?? true
            return json(torch(on))

        case "/vibrate":
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return ok(["ok": true])

        case "/logs":
            return ok(["ok": true, "logs": Log.lines])

        // MARK: - 触摸 / 键盘注入
        case "/hid":
            return ok(["ok": true, "ready": HID.shared.ready,
                       "screen": "\(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"])

        case "/tap":
            let b = req.jsonBody
            let pt = point(b)
            guard HID.shared.ready else { return fail("HID 未就绪（可能缺少注入权限）") }
            let r = HID.shared.tap(x: pt.x, y: pt.y)
            return json(["ok": r, "x": pt.x, "y": pt.y])

        case "/long":
            let b = req.jsonBody
            let pt = point(b)
            let secs = (b["seconds"] as? Double) ?? 1.0
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(["ok": HID.shared.longPress(x: pt.x, y: pt.y, seconds: secs)])

        case "/swipe":
            let b = req.jsonBody
            let p1 = point(b, prefix: "1")
            let p2 = point(b, prefix: "2")
            let dur = (b["duration"] as? Double) ?? 0.3
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(["ok": HID.shared.swipe(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y, duration: dur)])

        case "/home":
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(["ok": HID.shared.home()])

        case "/text":
            let t = (req.jsonBody["text"] as? String) ?? ""
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(HID.shared.type(t))

        case "/press":
            let name = (req.jsonBody["key"] as? String) ?? "return"
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(["ok": HID.shared.press(name), "key": name])

        case "/paste":
            let t = (req.jsonBody["text"] as? String) ?? ""
            guard HID.shared.ready else { return fail("HID 未就绪") }
            return json(HID.shared.paste(t))

        case "/hidtest":
            let b = req.jsonBody
            let kind = (b["type"] as? String) ?? "default"
            let action = (b["action"] as? String) ?? "key"
            if action == "tap" {
                let pt = point(b)
                return json(HID.shared.probeTap(kind: kind, x: pt.x, y: pt.y))
            }
            let page = UInt16((b["page"] as? Int) ?? 0x0C)
            let usage = UInt16((b["usage"] as? Int) ?? 0x40)
            return json(HID.shared.probe(kind: kind, page: page, usage: usage))

        default:
            return makeResponse(status: 404, json: ["ok": false, "error": "未知接口 \(p)"])
        }
    }

    // MARK: - 工具
    /// 坐标解析：优先归一化 nx/ny(0~1)，其次点坐标 x/y
    static func point(_ b: [String: Any], prefix: String = "") -> CGPoint {
        let size = onMain { UIScreen.main.bounds.size }
        let nk = "nx" + prefix, nyk = "ny" + prefix
        if let nx = b[nk] as? Double, let ny = b[nyk] as? Double {
            return CGPoint(x: CGFloat(nx) * size.width, y: CGFloat(ny) * size.height)
        }
        let xk = "x" + prefix, yk = "y" + prefix
        if let x = b[xk] as? Double, let y = b[yk] as? Double {
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        if let x = b[xk] as? Int, let y = b[yk] as? Int {
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    static func ok(_ extra: [String: Any]) -> Data {
        var d = extra
        d["ok"] = true
        return makeResponse(status: 200, json: d)
    }

    static func json(_ d: [String: Any]) -> Data {
        var o = d
        if o["ok"] == nil { o["ok"] = true }
        return makeResponse(status: 200, json: o)
    }

    static func fail(_ msg: String) -> Data {
        return makeResponse(status: 200, json: ["ok": false, "error": msg])
    }

    // MARK: - 设备信息
    static func deviceInfo() -> [String: Any] {
        let d = UIDevice.current
        let screen = onMain { UIScreen.main.bounds.size }
        var out: [String: Any] = [
            "ok": true,
            "name": d.name,
            "model": d.model,
            "system_version": d.systemVersion,
            "identifier": d.identifierForVendor?.uuidString ?? "",
            "screen": "\(Int(screen.width))x\(Int(screen.height))",
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        ]
        onMain {
            d.isBatteryMonitoringEnabled = true
            let lvl = d.batteryLevel
            out["battery"] = lvl < 0 ? 0 : Double(lvl)
            out["charging"] = (d.batteryState == .charging || d.batteryState == .full)
            out["brightness"] = Double(UIScreen.main.brightness)
        }
        return out
    }

    // MARK: - 应用
    static func appList() -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let ws = ObjC.call(ObjC.cls("LSApplicationWorkspace"), "defaultWorkspace"),
           let arr = ObjC.call(ws, "allInstalledApplications") as? [AnyObject] {
            for proxy in arr {
                let bundle = (ObjC.call(proxy, "bundleIdentifier") as? String) ?? ""
                guard !bundle.isEmpty else { continue }
                let name = (ObjC.call(proxy, "localizedName") as? String) ?? bundle
                let type = (ObjC.call(proxy, "applicationType") as? String) ?? "User"
                out.append(["name": name, "bundle": bundle, "type": type])
            }
        }
        if out.isEmpty { out = scanAppsFromDisk() }
        out.sort { ($0["name"] as? String ?? "").localizedCompare($1["name"] as? String ?? "") == .orderedAscending }
        return out
    }

    /// 无沙盒条件下的兜底：直接扫描 App 容器目录
    static func scanAppsFromDisk() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let fm = FileManager.default
        let roots = ["/var/containers/Bundle/Application", "/Applications"]
        for root in roots {
            guard let groups = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for g in groups {
                let gp = root + "/" + g
                guard let items = try? fm.contentsOfDirectory(atPath: gp) else { continue }
                for it in items where it.hasSuffix(".app") {
                    let plist = gp + "/" + it + "/Info.plist"
                    guard let dict = NSDictionary(contentsOfFile: plist) else { continue }
                    let bundle = (dict["CFBundleIdentifier"] as? String) ?? ""
                    guard !bundle.isEmpty else { continue }
                    let name = (dict["CFBundleDisplayName"] as? String)
                        ?? (dict["CFBundleName"] as? String) ?? bundle
                    out.append(["name": name, "bundle": bundle, "type": "User"])
                }
            }
        }
        return out
    }

    static func openApp(_ bundle: String) -> [String: Any] {
        if let ws = ObjC.call(ObjC.cls("LSApplicationWorkspace"), "defaultWorkspace") {
            let r = ObjC.call1(ws, "openApplicationWithBundleID:", bundle as AnyObject)
            if (r as? Bool) == true { return ["ok": true, "via": "workspace"] }
        }
        // 退路：用 URL Scheme 打开
        let schemes = urlSchemes(for: bundle)
        for s in schemes {
            let r = openURL("\(s)://")
            if (r["ok"] as? Bool) == true { return r }
        }
        return ["ok": false, "error": "启动失败（可能缺少 URL Scheme）"]
    }

    static func urlSchemes(for bundle: String) -> [String] {
        let fm = FileManager.default
        guard let groups = try? fm.contentsOfDirectory(atPath: "/var/containers/Bundle/Application") else { return [] }
        for g in groups {
            let gp = "/var/containers/Bundle/Application/" + g
            guard let items = try? fm.contentsOfDirectory(atPath: gp) else { continue }
            for it in items where it.hasSuffix(".app") {
                let plist = gp + "/" + it + "/Info.plist"
                guard let dict = NSDictionary(contentsOfFile: plist),
                      (dict["CFBundleIdentifier"] as? String) == bundle else { continue }
                if let types = dict["CFBundleURLTypes"] as? [[String: Any]] {
                    var out: [String] = []
                    for t in types {
                        if let ss = t["CFBundleURLSchemes"] as? [String] { out.append(contentsOf: ss) }
                    }
                    return out
                }
            }
        }
        return []
    }

    static func openURL(_ s: String) -> [String: Any] {
        guard let url = URL(string: s) else { return ["ok": false, "error": "URL 非法"] }
        if let ws = ObjC.call(ObjC.cls("LSApplicationWorkspace"), "defaultWorkspace") {
            let r = ObjC.call2(ws, "openSensitiveURL:withOptions:", url as AnyObject, NSDictionary())
            if (r as? Bool) == true { return ["ok": true, "via": "workspace"] }
        }
        var done = false
        onMain {
            UIApplication.shared.open(url, options: [:]) { ok in done = ok }
        }
        return ["ok": done, "via": "uiapplication"]
    }

    // MARK: - 文件
    static func listDir(_ path: String) -> [String: Any] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ["ok": false, "error": "目录不存在或不可读: \(path)"]
        }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else {
            return ["ok": false, "error": "无权限读取: \(path)"]
        }
        var items: [[String: Any]] = []
        for n in names {
            let full = path.hasSuffix("/") ? path + n : path + "/" + n
            var d: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &d) else { continue }
            var size = 0
            if !d.boolValue, let attrs = try? fm.attributesOfItem(atPath: full) {
                size = (attrs[.size] as? Int) ?? 0
            }
            items.append(["name": n, "dir": d.boolValue, "size": size])
        }
        let parent = (path as NSString).deletingLastPathComponent
        return ["ok": true, "path": path, "parent": parent.isEmpty ? "/" : parent, "items": items]
    }

    static func readFile(_ path: String) -> [String: Any] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            return ["ok": false, "error": "文件不存在: \(path)"]
        }
        if size > 64 * 1024 * 1024 {
            return ["ok": false, "error": "文件超过 64MB，请用其他方式导出"]
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return ["ok": false, "error": "读取失败（权限）"]
        }
        return ["ok": true, "size": size, "name": (path as NSString).lastPathComponent,
                "data": data.base64EncodedString()]
    }

    static func writeFile(_ path: String, base64: String) -> [String: Any] {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return ["ok": false, "error": "base64 解码失败"]
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return ["ok": true, "size": data.count, "path": path]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    // MARK: - 手电
    static func torch(_ on: Bool) -> [String: Any] {
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch else {
            return ["ok": false, "error": "设备不支持手电"]
        }
        do {
            try dev.lockForConfiguration()
            defer { dev.unlockForConfiguration() }
            dev.torchMode = on ? .on : .off
            return ["ok": true]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }
}
