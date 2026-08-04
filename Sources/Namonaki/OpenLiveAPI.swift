import Foundation

enum OpenLiveNetworkPolicy {
    static let allowedHosts = Set(["api1.blive.chat", "api2.blive.chat"])
    static let allowedPaths = Set([
        "/api/open_live/start_game",
        "/api/open_live/end_game",
        "/api/open_live/game_heartbeat",
    ])

    static func allows(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
            && allowedHosts.contains(url.host?.lowercased() ?? "")
            && allowedPaths.contains(url.path)
    }

    static func allowsWebSocket(_ url: URL) -> Bool {
        url.scheme == "wss"
            && url.user == nil
            && url.password == nil
            && url.host?.lowercased() == "broadcastlv.chat.bilibili.com"
            && (url.port == nil || url.port == 443)
            && url.path == "/sub"
            && url.query == nil
            && url.fragment == nil
    }
}

enum OpenLiveAPIError: LocalizedError, Equatable {
    case disallowedEndpoint
    case transport(String)
    case invalidResponse
    case business(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disallowedEndpoint:
            "拦截了不在隐私白名单内的网络请求"
        case .transport:
            "连接 blivechat 公共服务失败"
        case .invalidResponse:
            "blivechat 公共服务返回了无法识别的数据"
        case .business(let code, _):
            switch code {
            case 7007: "身份码无效，请去 B 站重新复制"
            case 7010: "开放平台连接数已达上限，请稍后再试"
            default: "开放平台错误 \(code)"
            }
        }
    }
}

/// 即使公共 API 返回重定向，也不允许身份码跟着离开白名单域名。
private final class OpenLiveSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, OpenLiveNetworkPolicy.allows(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct OpenLiveSession: Sendable, Equatable {
    let endpoint: URL
    let gameID: String
    let authBody: String
    let webSocketURLs: [URL]
    let roomID: Int
    let ownerOpenID: String
}

private struct OpenLiveResponse<Value: Decodable>: Decodable {
    let code: Int
    let message: String
    let requestID: String?
    let data: Value?

    enum CodingKeys: String, CodingKey {
        case code, message, data
        case requestID = "request_id"
    }
}

private struct StartResponseData: Decodable {
    let gameInfo: GameInfo
    let websocketInfo: WebSocketInfo
    let anchorInfo: AnchorInfo

    struct GameInfo: Decodable {
        let gameID: String
        enum CodingKeys: String, CodingKey { case gameID = "game_id" }
    }

    struct WebSocketInfo: Decodable {
        let authBody: String
        let links: [URL]
        enum CodingKeys: String, CodingKey {
            case authBody = "auth_body"
            case links = "wss_link"
        }
    }

    struct AnchorInfo: Decodable {
        let roomID: Int
        let openID: String
        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case openID = "open_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case gameInfo = "game_info"
        case websocketInfo = "websocket_info"
        case anchorInfo = "anchor_info"
    }
}

private struct EmptyResponseData: Decodable {}

private struct StartBody: Encodable {
    let code: String
    let appID = 0
    enum CodingKeys: String, CodingKey { case code; case appID = "app_id" }
}

private struct EndBody: Encodable {
    let appID = 0
    let gameID: String
    enum CodingKeys: String, CodingKey { case appID = "app_id"; case gameID = "game_id" }
}

private struct HeartbeatBody: Encodable {
    let gameID: String
    enum CodingKeys: String, CodingKey { case gameID = "game_id" }
}

final class OpenLiveAPI: @unchecked Sendable {
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    private let endpoints = [
        URL(string: "https://api1.blive.chat")!,
        URL(string: "https://api2.blive.chat")!,
    ]
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(
            configuration: configuration,
            delegate: OpenLiveSessionDelegate(),
            delegateQueue: nil
        )
    }

    func start(authCode: String) async throws -> OpenLiveSession {
        var lastTransportError: OpenLiveAPIError?
        for endpoint in endpoints {
            do {
                let response: OpenLiveResponse<StartResponseData> = try await post(
                    endpoint: endpoint,
                    path: "/api/open_live/start_game",
                    body: StartBody(code: authCode)
                )
                guard response.code == 0 else {
                    throw OpenLiveAPIError.business(code: response.code, message: response.message)
                }
                guard let data = response.data,
                      !data.gameInfo.gameID.isEmpty,
                      !data.websocketInfo.authBody.isEmpty else {
                    throw OpenLiveAPIError.invalidResponse
                }
                let allowedLinks = data.websocketInfo.links.filter(OpenLiveNetworkPolicy.allowsWebSocket)
                let started = OpenLiveSession(
                    endpoint: endpoint,
                    gameID: data.gameInfo.gameID,
                    authBody: data.websocketInfo.authBody,
                    webSocketURLs: allowedLinks,
                    roomID: data.anchorInfo.roomID,
                    ownerOpenID: data.anchorInfo.openID
                )
                guard !allowedLinks.isEmpty else {
                    await end(started)
                    throw OpenLiveAPIError.invalidResponse
                }
                return started
            } catch let error as OpenLiveAPIError {
                if case .transport = error {
                    lastTransportError = error
                    continue
                }
                throw error
            }
        }
        throw lastTransportError ?? .transport("all endpoints failed")
    }

    func heartbeat(_ active: OpenLiveSession) async throws {
        let response: OpenLiveResponse<EmptyResponseData> = try await post(
            endpoint: active.endpoint,
            path: "/api/open_live/game_heartbeat",
            body: HeartbeatBody(gameID: active.gameID)
        )
        guard response.code == 0 else {
            throw OpenLiveAPIError.business(code: response.code, message: response.message)
        }
    }

    func end(_ active: OpenLiveSession) async {
        do {
            let response: OpenLiveResponse<EmptyResponseData> = try await post(
                endpoint: active.endpoint,
                path: "/api/open_live/end_game",
                body: EndBody(gameID: active.gameID)
            )
            guard [0, 7000, 7003].contains(response.code) else { return }
        } catch {
            // 退出路径只做尽力清理，且绝不把 game_id 或请求体写入日志。
        }
    }

    func makeWebSocketTask(url: URL) throws -> URLSessionWebSocketTask {
        guard OpenLiveNetworkPolicy.allowsWebSocket(url) else {
            throw OpenLiveAPIError.disallowedEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        return task
    }

    private func post<Body: Encodable, Value: Decodable>(
        endpoint: URL,
        path: String,
        body: Body
    ) async throws -> OpenLiveResponse<Value> {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              OpenLiveNetworkPolicy.allows(url) else {
            throw OpenLiveAPIError.disallowedEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw OpenLiveAPIError.transport("HTTP error")
            }
            guard let value = try? decoder.decode(OpenLiveResponse<Value>.self, from: data) else {
                throw OpenLiveAPIError.invalidResponse
            }
            return value
        } catch let error as OpenLiveAPIError {
            throw error
        } catch {
            throw OpenLiveAPIError.transport(String(describing: type(of: error)))
        }
    }
}
