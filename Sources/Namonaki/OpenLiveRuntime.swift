import Foundation
import Combine

@MainActor
final class OpenLiveRuntime: ObservableObject {
    static let shared = OpenLiveRuntime()

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case authenticating
        case connected(roomID: Int)
        case reconnecting(attempt: Int)
        /// Backed off to a slow retry. Something needs attention, but we never stop
        /// trying — the danmaku has to be able to come back on its own.
        case waiting(reason: String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: "等待身份码"
            case .connecting: "正在连接"
            case .authenticating: "正在鉴权"
            case .connected: "已连接"
            case .reconnecting(let attempt): "正在重连（第 \(attempt) 次）"
            case .waiting(let reason): "\(reason)，每分钟自动重试"
            case .failed(let message): message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var relayState: LocalRelayServer.State = .stopped

    /// Every message received. The HUD subscribes here and renders natively instead of
    /// looping back through the local relay.
    let messages = PassthroughSubject<DanmakuMessage, Never>()

    let relayToken: String
    let rendererRoot: URL

    private let api = OpenLiveAPI()
    private let relay: LocalRelayServer
    private var connectionTask: Task<Void, Never>?
    private var socketHeartbeatTask: Task<Void, Never>?
    private var gameHeartbeatTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var activeSession: OpenLiveSession?
    private var generation = 0
    private var sessionNeedsRefresh = false

    var hudURL: URL? { rendererURL(showDebugMessages: Preferences.shared.showDebugMessages) }
    var obsURL: URL? { rendererURL(showDebugMessages: false) }

    private init() {
        relayToken = Self.loadOrCreateRelayToken()
        rendererRoot = Self.findRendererRoot()
        relay = LocalRelayServer(token: relayToken, rendererRoot: rendererRoot)
        relay.onStateChange = { [weak self] state in
            Task { @MainActor in self?.relayState = state }
        }
    }

    func start(authCode: String) {
        relay.start()
        updateAuthCode(authCode)
    }

    func updateAuthCode(_ raw: String) {
        let authCode = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        generation += 1
        let currentGeneration = generation
        connectionTask?.cancel()
        connectionTask = nil
        cancelSocketTasks()

        let previous = activeSession
        activeSession = nil
        sessionNeedsRefresh = false

        guard !authCode.isEmpty else {
            connectionState = .idle
            publishStatus("Waiting for identity code")
            if let previous { Task { await api.end(previous) } }
            return
        }
        guard Self.isValidAuthCode(authCode) else {
            connectionState = .failed("身份码应为 12–14 位大写字母或数字")
            publishStatus("Invalid identity code format")
            if let previous { Task { await api.end(previous) } }
            return
        }

        connectionTask = Task { [weak self] in
            guard let self else { return }
            if let previous { await self.api.end(previous) }
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            await self.connectionLoop(authCode: authCode, generation: currentGeneration)
        }
    }

    /// Hands the current look to the relay so the OBS page can follow it.
    func publishStyle(_ payload: Data) {
        relay.setStyle(payload)
    }

    func shutdown() async {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        cancelSocketTasks()
        let previous = activeSession
        activeSession = nil
        if let previous { await api.end(previous) }
        relay.stop()
    }

    /// Fast reconnects before we drop to the slow lane. Past this the network is
    /// genuinely down, and hammering it every 20 seconds helps nobody.
    private static let fastRetryBudget = 30
    private static let slowRetryDelay = 60

    private func connectionLoop(authCode: String, generation: Int) async {
        var retryCount = 0
        var totalRetryCount = 0
        var slowRetryReason: (label: String, status: String)?

        while !Task.isCancelled, self.generation == generation {
            do {
                if activeSession == nil || sessionNeedsRefresh
                    || retryCount >= max(3, activeSession?.webSocketURLs.count ?? 0) {
                    if let previous = activeSession {
                        activeSession = nil
                        cancelGameHeartbeat()
                        await api.end(previous)
                    }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    sessionNeedsRefresh = false
                    retryCount = 0
                    connectionState = .connecting
                    publishStatus("Connecting")
                    let started = try await api.start(authCode: authCode)
                    guard !Task.isCancelled, self.generation == generation else {
                        await api.end(started)
                        return
                    }
                    activeSession = started
                    startGameHeartbeat(for: started, generation: generation)
                }

                guard let active = activeSession else { continue }
                let socketURL = active.webSocketURLs[retryCount % active.webSocketURLs.count]
                let authenticated = try await runWebSocket(
                    url: socketURL,
                    active: active,
                    generation: generation
                )
                // A session that worked earns the whole retry budget back, otherwise an app
                // left running for days eventually exhausts it on unrelated blips.
                if authenticated {
                    retryCount = 0
                    totalRetryCount = 0
                    slowRetryReason = nil
                }
            } catch is CancellationError {
                return
            } catch let error as OpenLiveAPIError {
                if case .business(let code, _) = error, code == 7007 {
                    // The identity code itself is wrong. Retrying only files more invalid
                    // attempts against it upstream, so this one really is terminal.
                    connectionState = .failed(error.localizedDescription)
                    publishStatus("Identity code rejected")
                    return
                }
                if case .business(let code, _) = error, code == 7010 {
                    // Usually our own previous session that the server has not released yet.
                    // It expires on its own, so wait it out instead of giving up.
                    slowRetryReason = ("开放平台连接数已达上限", "Connection limit reached")
                } else {
                    connectionState = .failed(error.localizedDescription)
                }
            } catch {
                if Task.isCancelled { return }
            }

            cancelSocketTasks(keepGameHeartbeat: true)
            retryCount += 1
            totalRetryCount += 1
            if slowRetryReason == nil, totalRetryCount > Self.fastRetryBudget {
                slowRetryReason = ("连接反复失败，请检查网络", "Too many reconnection attempts")
            }

            let delay: Int
            if let reason = slowRetryReason {
                connectionState = .waiting(reason: reason.label)
                publishStatus(reason.status)
                delay = Self.slowRetryDelay
            } else {
                connectionState = .reconnecting(attempt: totalRetryCount)
                publishStatus("Disconnected")
                delay = min(1 + ((totalRetryCount - 1) * 2), 20)
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    private func runWebSocket(
        url: URL,
        active: OpenLiveSession,
        generation: Int
    ) async throws -> Bool {
        let socket = try api.makeWebSocketTask(url: url)
        webSocket = socket
        connectionState = .authenticating
        publishStatus("Connected and authenticating")
        socket.resume()
        try await socket.send(.data(try OpenLivePacketCodec.makeJSONPacket(
            active.authBody,
            operation: OpenLivePacketCodec.operationAuth
        )))

        socketHeartbeatTask = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let socket, !Task.isCancelled else { return }
                do {
                    let packet = try OpenLivePacketCodec.makeJSONPacket(
                        [:],
                        operation: OpenLivePacketCodec.operationHeartbeat
                    )
                    try await socket.send(.data(packet))
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                guard self.generation == generation else { return }
            }
        }

        var didAuthenticate = false
        while !Task.isCancelled, self.generation == generation {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }

            for incoming in try OpenLivePacketCodec.decode(data) {
                switch incoming {
                case .authenticated:
                    didAuthenticate = true
                    connectionState = .connected(roomID: active.roomID)
                    publishStatus("Connected")
                    let heartbeat = try OpenLivePacketCodec.makeJSONPacket(
                        [:],
                        operation: OpenLivePacketCodec.operationHeartbeat
                    )
                    try await socket.send(.data(heartbeat))
                case .heartbeat:
                    break
                case .command(let command):
                    guard let mapped = try OpenLiveEventMapper.map(
                        command,
                        ownerOpenID: active.ownerOpenID
                    ) else { continue }
                    switch mapped {
                    case .message(let message):
                        // OBS gets blivechat-shaped JSON; the HUD takes the typed value.
                        relay.broadcast(message.relayPayload)
                        messages.send(message)
                    case .sessionEnded(let gameID):
                        if gameID == active.gameID {
                            sessionNeedsRefresh = true
                            socket.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            }
        }
        return didAuthenticate
    }

    private func startGameHeartbeat(for active: OpenLiveSession, generation: Int) {
        cancelGameHeartbeat()
        gameHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.generation == generation,
                      self.activeSession?.gameID == active.gameID else { return }
                do {
                    try await self.api.heartbeat(active)
                } catch let error as OpenLiveAPIError {
                    if case .business(let code, _) = error, code == 7003 {
                        self.sessionNeedsRefresh = true
                        self.webSocket?.cancel(with: .goingAway, reason: nil)
                    }
                } catch {
                    // 单次项目心跳的网络错误留给下一轮恢复，不上传额外诊断数据。
                }
            }
        }
    }

    private func cancelSocketTasks(keepGameHeartbeat: Bool = false) {
        socketHeartbeatTask?.cancel()
        socketHeartbeatTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if !keepGameHeartbeat { cancelGameHeartbeat() }
    }

    private func cancelGameHeartbeat() {
        gameHeartbeatTask?.cancel()
        gameHeartbeatTask = nil
    }

    private func publishStatus(_ englishStatus: String) {
        relay.setStatus(OpenLiveEventMapper.debug(englishStatus))
    }

    private func rendererURL(showDebugMessages: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(relay.port)
        components.path = "/room/native"
        components.queryItems = [
            URLQueryItem(name: "namonakiNative", value: "true"),
            URLQueryItem(name: "token", value: relayToken),
            URLQueryItem(name: "showDebugMessages", value: showDebugMessages ? "true" : "false"),
        ]
        return components.url
    }

    static func isValidAuthCode(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-Z]{12,14}$"#, options: .regularExpression) != nil
    }

    private static func loadOrCreateRelayToken() -> String {
        if let saved = Keychain.get("relayToken"), saved.count >= 32 { return saved }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        Keychain.set(token, for: "relayToken")
        return token
    }

    private static func findRendererRoot() -> URL {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Renderer", isDirectory: true),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Resources/Renderer", isDirectory: true),
        ].compactMap { $0 }
        return candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) })
            ?? candidates[0]
    }
}
