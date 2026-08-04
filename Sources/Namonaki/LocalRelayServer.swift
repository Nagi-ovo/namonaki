import Foundation
import Network
import CryptoKit

/// 只监听 127.0.0.1 的静态页面和单向 WebSocket relay。
/// 浏览器必须持有随机本机令牌才能收消息；令牌与 B 站身份码无关。
final class LocalRelayServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 12451

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    var onStateChange: (@Sendable (State) -> Void)?

    private let token: String
    private let rendererRoot: URL
    let port: UInt16
    private let queue = DispatchQueue(label: "fun.nagi.namonaki.local-relay")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    /// Latched so a browser source that connects late still gets the current state.
    private var latestStatus: Data?
    private var latestStyle: Data?

    init(token: String, rendererRoot: URL, port: UInt16 = defaultPort) {
        self.token = token
        self.rendererRoot = rendererRoot.standardizedFileURL
        self.port = port
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.clients.values {
                connection.cancel()
            }
            self.clients.removeAll()
            self.onStateChange?(.stopped)
        }
    }

    func broadcast(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, !payload.isEmpty else { return }
            let frame = Self.webSocketTextFrame(payload)
            for (id, connection) in self.clients {
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard error != nil else { return }
                    self?.clients.removeValue(forKey: id)?.cancel()
                })
            }
        }
    }

    func setStatus(_ payload: Data) {
        queue.async { [weak self] in
            self?.latestStatus = payload
            self?.broadcast(payload)
        }
    }

    /// The look the HUD is currently using, so the OBS page tracks the sliders without
    /// anyone pasting CSS.
    func setStyle(_ payload: Data) {
        queue.async { [weak self] in
            self?.latestStyle = payload
            self?.broadcast(payload)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        onStateChange?(.starting)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStateChange?(.ready)
                case .failed(let error):
                    self.listener = nil
                    self.onStateChange?(.failed(error.localizedDescription))
                case .cancelled:
                    self.listener = nil
                    self.onStateChange?(.stopped)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.remove(connection) }
            if case .cancelled = state { self.remove(connection) }
        }
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, accumulated: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            var request = accumulated
            if let content { request.append(content) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handleHTTPRequest(request, on: connection)
            } else if error == nil, !isComplete, request.count < 64 * 1024 {
                self.receiveHTTPRequest(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleHTTPRequest(_ data: Data, on connection: NWConnection) {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendHTTP(status: "400 Bad Request", body: Data(), mime: "text/plain", on: connection)
            return
        }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTP(status: "400 Bad Request", body: Data(), mime: "text/plain", on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendHTTP(status: "405 Method Not Allowed", body: Data(), mime: "text/plain", on: connection)
            return
        }

        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if target.hasPrefix("/events") {
            upgradeWebSocket(target: target, headers: headers, connection: connection)
            return
        }
        if target == "/health" {
            sendHTTP(status: "200 OK", body: Data("ok".utf8), mime: "text/plain", on: connection)
            return
        }
        serveStatic(target: target, connection: connection)
    }

    private func upgradeWebSocket(
        target: String,
        headers: [String: String],
        connection: NWConnection
    ) {
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let suppliedToken = components?.queryItems?.first(where: { $0.name == "token" })?.value
        guard suppliedToken == token,
              headers["upgrade"]?.lowercased() == "websocket",
              let key = headers["sec-websocket-key"],
              !key.isEmpty else {
            sendHTTP(status: "403 Forbidden", body: Data(), mime: "text/plain", on: connection)
            return
        }

        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        let accept = Data(digest).base64EncodedString()
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }
            let id = UUID()
            self.clients[id] = connection
            for latched in [self.latestStyle, self.latestStatus].compactMap({ $0 }) {
                connection.send(content: Self.webSocketTextFrame(latched), completion: .idempotent)
            }
            self.receiveWebSocket(on: connection, id: id)
        })
    }

    private func receiveWebSocket(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] _, _, isComplete, error in
            guard let self, let connection else { return }
            if error != nil || isComplete {
                self.clients.removeValue(forKey: id)
                connection.cancel()
            } else {
                self.receiveWebSocket(on: connection, id: id)
            }
        }
    }

    private func serveStatic(target: String, connection: NWConnection) {
        let path = URLComponents(string: "http://127.0.0.1\(target)")?.path ?? "/"
        let lastComponent = path.split(separator: "/").last
        let relative: String
        if path == "/" || !(lastComponent?.contains(".") ?? false) {
            relative = "index.html"
        } else {
            relative = String(path.drop(while: { $0 == "/" }))
        }
        guard !relative.split(separator: "/").contains("..") else {
            sendHTTP(status: "403 Forbidden", body: Data(), mime: "text/plain", on: connection)
            return
        }

        let file = rendererRoot.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(rendererRoot.path + "/"),
              let body = try? Data(contentsOf: file) else {
            sendHTTP(status: "404 Not Found", body: Data(), mime: "text/plain", on: connection)
            return
        }
        sendHTTP(status: "200 OK", body: body, mime: Self.mimeType(for: file), on: connection)
    }

    private func sendHTTP(
        status: String,
        body: Data,
        mime: String,
        on connection: NWConnection
    ) {
        let csp = "default-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data: https://*.hdslb.com https://*.bilibili.com; "
            + "font-src 'self' data:; connect-src 'self' ws://127.0.0.1:\(port); "
            + "frame-src 'none'; object-src 'none'; base-uri 'self'"
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(mime)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-cache\r
        Content-Security-Policy: \(csp)\r
        X-Content-Type-Options: nosniff\r
        Referrer-Policy: no-referrer\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        clients = clients.filter { $0.value !== connection }
    }

    private static func webSocketTextFrame(_ payload: Data) -> Data {
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(payload)
        return frame
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "application/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
