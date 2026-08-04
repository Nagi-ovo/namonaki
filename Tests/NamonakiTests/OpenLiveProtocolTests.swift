import Foundation
import Testing
@testable import Namonaki

struct OpenLiveProtocolTests {
    @Test func buildsBilibiliPacketHeader() throws {
        let packet = OpenLivePacketCodec.makePacket(
            body: Data("{}".utf8),
            operation: OpenLivePacketCodec.operationHeartbeat
        )

        #expect(packet.count == 18)
        #expect(Array(packet.prefix(16)) == [
            0, 0, 0, 18,
            0, 16,
            0, 1,
            0, 0, 0, 2,
            0, 0, 0, 1,
        ])
        #expect(String(data: packet.dropFirst(16), encoding: .utf8) == "{}")
    }

    @Test func decodesConcatenatedCommandsAndAuthReply() throws {
        let first = OpenLivePacketCodec.makePacket(
            body: Data(#"{"cmd":"ONE","data":{}}"#.utf8),
            operation: OpenLivePacketCodec.operationMessage
        )
        let second = OpenLivePacketCodec.makePacket(
            body: Data(#"{"cmd":"TWO","data":{}}"#.utf8),
            operation: OpenLivePacketCodec.operationMessage
        )
        let auth = OpenLivePacketCodec.makePacket(
            body: Data(#"{"code":0}"#.utf8),
            operation: OpenLivePacketCodec.operationAuthReply
        )

        let decoded = try OpenLivePacketCodec.decode(first + second + auth)
        #expect(decoded.count == 3)
        #expect(decoded[0] == .command(Data(#"{"cmd":"ONE","data":{}}"#.utf8)))
        #expect(decoded[1] == .command(Data(#"{"cmd":"TWO","data":{}}"#.utf8)))
        #expect(decoded[2] == .authenticated)
    }

    @Test func rejectsTruncatedPackets() {
        #expect(throws: OpenLiveProtocolError.self) {
            try OpenLivePacketCodec.decode(Data([0, 1, 2]))
        }
    }

    @Test func decodesOpenLiveZlibEnvelope() throws {
        // Python zlib.compress 生成的已知 fixture：外层 ver=2，内层是普通业务包。
        let fixture = try #require(Data(base64Encoded:
            "AAAAPQAQAAIAAAAFAAAAAXicY2BgUGcQYGBkYGBgBWLGaqXk3BQlK6UozwAlHaWUxJJEJavq2loAWYkHXA=="
        ))
        let decoded = try OpenLivePacketCodec.decode(fixture)

        #expect(decoded == [.command(Data(#"{"cmd":"ZIP","data":{}}"#.utf8))])
    }

    @Test func mapsOpenLiveDanmakuWithoutLeakingSessionFields() throws {
        let command: [String: Any] = [
            "cmd": "LIVE_OPEN_PLATFORM_DM_MIRROR:extra",
            "data": [
                "msg_id": "message-1",
                "open_id": "owner-open-id",
                "uname": "测试用户",
                "uface": "//i0.hdslb.com/avatar.jpg",
                "timestamp": 123,
                "msg": "你好",
                "reply_uname": "主播",
                "guard_level": 0,
                "is_admin": false,
                "fans_medal_wearing_status": true,
                "fans_medal_level": 8,
                "fans_medal_name": "灯牌",
                "dm_type": 1,
                "emoji_img_url": "http://i0.hdslb.com/emote.png",
                // 未知字段不应被原样广播给 OBS。
                "auth_body": "must-not-leak",
                "game_id": "must-not-leak",
            ],
        ]
        let raw = try JSONSerialization.data(withJSONObject: command)
        guard case .message(let message) = try OpenLiveEventMapper.map(
            raw,
            ownerOpenID: "owner-open-id"
        ) else {
            Issue.record("弹幕没有映射成本机消息")
            return
        }

        let payload = message.relayPayload
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(object["type"] as? String == "text")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["authorName"] as? String == "测试用户")
        #expect(data["authorType"] as? Int == 3)
        #expect(data["content"] as? String == "@主播 你好")
        #expect(data["avatarUrl"] as? String == "https://i0.hdslb.com/avatar.jpg")
        #expect(data["emoticon"] as? String == "https://i0.hdslb.com/emote.png")
        #expect(data["isMirror"] as? Bool == true)
        #expect(data["auth_body"] == nil)
        #expect(data["game_id"] == nil)
        #expect(String(data: payload, encoding: .utf8)?.contains("must-not-leak") == false)
    }

    @Test func mapsGiftGuardSuperChatAndDeletion() throws {
        let fixtures: [(String, [String: Any], String)] = [
            (
                "LIVE_OPEN_PLATFORM_SEND_GIFT",
                ["msg_id": "g", "gift_num": 2, "r_price": 100, "paid": true],
                "gift"
            ),
            (
                "LIVE_OPEN_PLATFORM_GUARD",
                ["msg_id": "m", "guard_num": 1, "price": 1000, "user_info": [:]],
                "member"
            ),
            (
                "LIVE_OPEN_PLATFORM_SUPER_CHAT",
                ["message_id": 42, "rmb": 30, "message": "SC"],
                "superChat"
            ),
            (
                "LIVE_OPEN_PLATFORM_SUPER_CHAT_DEL",
                ["message_ids": [42, "43"]],
                "deleteSuperChat"
            ),
        ]

        for (commandName, data, expectedType) in fixtures {
            let raw = try JSONSerialization.data(withJSONObject: [
                "cmd": commandName,
                "data": data,
            ])
            guard case .message(let message) = try OpenLiveEventMapper.map(raw, ownerOpenID: "") else {
                Issue.record("\(commandName) 没有被映射")
                continue
            }
            let object = try #require(
                JSONSerialization.jsonObject(with: message.relayPayload) as? [String: Any]
            )
            #expect(object["type"] as? String == expectedType)
        }
    }

    @Test func recognizesInteractionEnd() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "cmd": "LIVE_OPEN_PLATFORM_INTERACTION_END",
            "data": ["game_id": "game-1"],
        ])
        #expect(try OpenLiveEventMapper.map(raw, ownerOpenID: "") == .sessionEnded(gameID: "game-1"))
    }

    @Test func ignoresUnknownCommandsWithoutDisconnecting() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["cmd": "SOME_FUTURE_COMMAND"])
        #expect(try OpenLiveEventMapper.map(raw, ownerOpenID: "") == nil)
    }
}

struct OpenLivePrivacyPolicyTests {
    @Test func onlyAllowsExpectedHTTPSAPIEndpoints() {
        #expect(OpenLiveNetworkPolicy.allows(
            URL(string: "https://api1.blive.chat/api/open_live/start_game")!
        ))
        #expect(OpenLiveNetworkPolicy.allows(
            URL(string: "https://api2.blive.chat/api/open_live/game_heartbeat")!
        ))
        #expect(!OpenLiveNetworkPolicy.allows(
            URL(string: "http://api1.blive.chat/api/open_live/start_game")!
        ))
        #expect(!OpenLiveNetworkPolicy.allows(
            URL(string: "https://evil.example/api/open_live/start_game")!
        ))
        #expect(!OpenLiveNetworkPolicy.allows(
            URL(string: "https://api1.blive.chat/api/anything_else")!
        ))
        #expect(!OpenLiveNetworkPolicy.allows(
            URL(string: "https://api1.blive.chat/api/open_live/start_game?redirect=evil")!
        ))
        #expect(OpenLiveNetworkPolicy.allowsWebSocket(
            URL(string: "wss://broadcastlv.chat.bilibili.com:443/sub")!
        ))
        #expect(!OpenLiveNetworkPolicy.allowsWebSocket(
            URL(string: "wss://evil.example/sub")!
        ))
        #expect(!OpenLiveNetworkPolicy.allowsWebSocket(
            URL(string: "ws://broadcastlv.chat.bilibili.com/sub")!
        ))
    }

    @Test @MainActor func validatesIdentityCodeLocally() {
        #expect(OpenLiveRuntime.isValidAuthCode("ABCDEF123456"))
        #expect(OpenLiveRuntime.isValidAuthCode("ABCDEF12345678"))
        #expect(!OpenLiveRuntime.isValidAuthCode("ABCDEF12345"))
        #expect(!OpenLiveRuntime.isValidAuthCode("abcdef123456"))
        #expect(!OpenLiveRuntime.isValidAuthCode("ABCDEF123456789"))
    }
}
