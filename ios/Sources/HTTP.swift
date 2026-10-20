import Foundation
import Network

// MARK: - 极简 HTTP 请求
final class HTTPRequest {
    var method = "GET"
    var path = "/"
    var headers: [String: String] = [:]
    var body = Data()

    /// 返回 nil 表示数据还不完整
    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let (headEnd, bodyStart) = findHeaderEnd(buf) else { return nil }
        let headData = buf.subdata(in: 0..<headEnd)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let req = HTTPRequest()
        req.method = parts[0].uppercased()
        req.path = parts[1]

        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }

        let need = Int(req.headers["content-length"] ?? "0") ?? 0
        if buf.count < bodyStart + need { return nil }
        if need > 0 {
            req.body = buf.subdata(in: bodyStart..<(bodyStart + need))
        }
        return req
    }

    private static func findHeaderEnd(_ d: Data) -> (Int, Int)? {
        let bytes = [UInt8](d)
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                return (i, i + 4)
            }
            i += 1
        }
        return nil
    }

    // MARK: 工具
    var pathOnly: String {
        return path.components(separatedBy: "?").first ?? path
    }

    var query: [String: String] {
        var out: [String: String] = [:]
        let segs = path.components(separatedBy: "?")
        guard segs.count > 1 else { return out }
        for pair in segs[1].components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count >= 2 {
                let k = kv[0].removingPercentEncoding ?? kv[0]
                let v = kv[1].removingPercentEncoding ?? kv[1]
                out[k] = v
            }
        }
        return out
    }

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }
}

// MARK: - 响应构造
func makeResponse(status: Int, json: Any) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data("{}".utf8)
    return makeResponse(status: status, body: body, contentType: "application/json")
}

func makeResponse(status: Int, body: Data, contentType: String) -> Data {
    var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
    head += "Content-Type: \(contentType); charset=utf-8\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Access-Control-Allow-Origin: *\r\n"
    head += "Connection: close\r\n\r\n"
    var d = Data(head.utf8)
    d.append(body)
    return d
}

func statusText(_ s: Int) -> String {
    switch s {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "OK"
    }
}

// MARK: - 服务器
final class HTTPServer {
    static let shared = HTTPServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "iphonebridge.http", attributes: .concurrent)
    private(set) var running = false
    private(set) var port: UInt16 = 17899

    func start(_ p: UInt16 = 17899) {
        guard listener == nil else { return }
        port = p
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: p) else {
            Log.add("端口非法 \(p)")
            return
        }
        do {
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    HTTPServer.shared.running = true
                    Log.add("HTTP 已监听 \(p)")
                case .failed(let err):
                    HTTPServer.shared.running = false
                    Log.add("监听失败 \(err)")
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
            Log.add("正在启动 HTTP \(p)…")
        } catch {
            Log.add("创建监听失败 \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        Log.add("HTTP 已停止")
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, err in
            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }

            if let req = HTTPRequest.parse(buf) {
                let resp = Router.handle(req)
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if isDone || err != nil || buf.count > 100 * 1024 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }
}

// MARK: - 主线程同步执行
func onMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread { return block() }
    return DispatchQueue.main.sync(execute: block)
}
