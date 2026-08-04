import Foundation
import Testing
@testable import Namonaki

struct LocalRelayServerTests {
    @Test func servesOnlyLocalRendererAndBroadcastsWebSocketMessages() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("NamonakiRelayTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>local renderer</html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))

        let token = "test-token-that-is-not-an-identity-code"
        let port: UInt16 = 18451
        let server = LocalRelayServer(token: token, rendererRoot: root, port: port)
        defer {
            server.stop()
            try? fileManager.removeItem(at: root)
        }

        let state = await withCheckedContinuation { continuation in
            server.onStateChange = { state in
                switch state {
                case .ready, .failed:
                    continuation.resume(returning: state)
                case .starting, .stopped:
                    break
                }
            }
            server.start()
        }
        #expect(state == .ready)

        let (health, healthResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/health")!
        )
        #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: health, encoding: .utf8) == "ok")

        let (page, pageResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/room/native")!
        )
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: page, encoding: .utf8)?.contains("local renderer") == true)

        let expected = Data(#"{"type":"debug","data":{"content":"Connected"}}"#.utf8)
        server.setStatus(expected)
        let socket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/events?token=\(token)")!
        )
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let message = try await socket.receive()
        switch message {
        case .data(let data):
            #expect(data == expected)
        case .string(let string):
            #expect(string == String(data: expected, encoding: .utf8))
        @unknown default:
            Issue.record("本机 relay 返回了未知 WebSocket 消息")
        }

        let rejectedSocket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/events?token=wrong-token")!
        )
        rejectedSocket.resume()
        defer { rejectedSocket.cancel(with: .normalClosure, reason: nil) }
        do {
            _ = try await rejectedSocket.receive()
            Issue.record("本机 relay 接受了错误令牌")
        } catch {
            // 403 就是预期结果。
        }
    }
}
