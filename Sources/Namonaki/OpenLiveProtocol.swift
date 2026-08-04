import Foundation
import Compression

enum OpenLiveProtocolError: LocalizedError {
    case truncatedPacket
    case invalidPacketLength(Int)
    case unsupportedCompression(Int)
    case decompressionFailed
    case invalidJSON
    case authenticationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .truncatedPacket: "弹幕数据包不完整"
        case .invalidPacketLength(let length): "弹幕数据包长度异常：\(length)"
        case .unsupportedCompression(let version): "暂不支持的弹幕压缩格式：\(version)"
        case .decompressionFailed: "弹幕数据解压失败"
        case .invalidJSON: "弹幕数据格式错误"
        case .authenticationFailed(let code): "弹幕 WebSocket 鉴权失败（\(code)）"
        }
    }
}

enum OpenLivePacketCodec {
    static let headerSize = 16
    static let operationHeartbeat = 2
    static let operationHeartbeatReply = 3
    static let operationMessage = 5
    static let operationAuth = 7
    static let operationAuthReply = 8

    enum Incoming: Equatable {
        case command(Data)
        case authenticated
        case heartbeat
    }

    static func makePacket(body: Data, operation: Int) -> Data {
        var packet = Data()
        packet.appendUInt32BE(UInt32(headerSize + body.count))
        packet.appendUInt16BE(UInt16(headerSize))
        packet.appendUInt16BE(1)
        packet.appendUInt32BE(UInt32(operation))
        packet.appendUInt32BE(1)
        packet.append(body)
        return packet
    }

    static func makeJSONPacket(_ value: Any, operation: Int) throws -> Data {
        let body: Data
        if let string = value as? String {
            body = Data(string.utf8)
        } else {
            body = try JSONSerialization.data(withJSONObject: value)
        }
        return makePacket(body: body, operation: operation)
    }

    static func decode(_ data: Data) throws -> [Incoming] {
        var result: [Incoming] = []
        try decodePackets(data, into: &result)
        return result
    }

    private static func decodePackets(_ data: Data, into result: inout [Incoming]) throws {
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= headerSize else {
                throw OpenLiveProtocolError.truncatedPacket
            }

            let packetLength = Int(data.uint32BE(at: offset))
            let rawHeaderSize = Int(data.uint16BE(at: offset + 4))
            let version = Int(data.uint16BE(at: offset + 6))
            let operation = Int(data.uint32BE(at: offset + 8))

            guard rawHeaderSize >= headerSize,
                  packetLength >= rawHeaderSize,
                  offset + packetLength <= data.count else {
                throw OpenLiveProtocolError.invalidPacketLength(packetLength)
            }

            let body = data.subdata(
                in: (offset + rawHeaderSize)..<(offset + packetLength)
            )

            switch operation {
            case operationMessage:
                switch version {
                case 0, 1:
                    if !body.isEmpty {
                        guard (try? JSONSerialization.jsonObject(with: body)) != nil else {
                            throw OpenLiveProtocolError.invalidJSON
                        }
                        result.append(.command(body))
                    }
                case 2:
                    try decodePackets(try inflateZlib(body), into: &result)
                case 3:
                    // Open Live 当前发送 zlib；遇到 Brotli 时明确报错并重连，
                    // 避免把压缩数据当成 JSON 静默丢掉。
                    throw OpenLiveProtocolError.unsupportedCompression(version)
                default:
                    throw OpenLiveProtocolError.unsupportedCompression(version)
                }
            case operationAuthReply:
                guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let code = object["code"] as? Int else {
                    throw OpenLiveProtocolError.invalidJSON
                }
                guard code == 0 else {
                    throw OpenLiveProtocolError.authenticationFailed(code)
                }
                result.append(.authenticated)
            case operationHeartbeatReply:
                result.append(.heartbeat)
            default:
                break
            }

            offset += packetLength
        }
    }

    private static func inflateZlib(_ input: Data) throws -> Data {
        let source: Data
        if input.count >= 6,
           input[0] & 0x0f == 8,
           (Int(input[0]) * 256 + Int(input[1])) % 31 == 0 {
            // Compression.framework 的 COMPRESSION_ZLIB 吃的是 raw DEFLATE；
            // B 站发来的是 RFC 1950 zlib envelope，需要去掉头和 Adler-32。
            let dictionaryBytes = (input[1] & 0x20) == 0 ? 0 : 4
            let start = 2 + dictionaryBytes
            guard input.count >= start + 4 else {
                throw OpenLiveProtocolError.decompressionFailed
            }
            source = input.subdata(in: start..<(input.count - 4))
        } else {
            source = input
        }

        var capacity = max(64 * 1024, input.count * 8)
        let maximum = 64 * 1024 * 1024

        while capacity <= maximum {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { destination in
                source.withUnsafeBytes { compressed in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = compressed.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        dst,
                        capacity,
                        src,
                        source.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 {
                output.count = decoded
                return output
            }
            capacity *= 2
        }
        throw OpenLiveProtocolError.decompressionFailed
    }
}

enum MappedOpenLiveEvent: Equatable, Sendable {
    case broadcast(Data)
    case sessionEnded(gameID: String)
}

enum OpenLiveEventMapper {
    private static let supportedCommands = Set([
        "LIVE_OPEN_PLATFORM_INTERACTION_END",
        "LIVE_OPEN_PLATFORM_DM",
        "LIVE_OPEN_PLATFORM_DM_MIRROR",
        "LIVE_OPEN_PLATFORM_SEND_GIFT",
        "LIVE_OPEN_PLATFORM_GUARD",
        "LIVE_OPEN_PLATFORM_SUPER_CHAT",
        "LIVE_OPEN_PLATFORM_SUPER_CHAT_DEL",
    ])

    static func map(_ commandData: Data, ownerOpenID: String) throws -> MappedOpenLiveEvent? {
        guard let command = try JSONSerialization.jsonObject(with: commandData) as? [String: Any],
              let rawCommand = command["cmd"] as? String else {
            throw OpenLiveProtocolError.invalidJSON
        }

        let commandName = rawCommand.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rawCommand
        guard supportedCommands.contains(commandName) else { return nil }
        guard let payload = command["data"] as? [String: Any] else {
            throw OpenLiveProtocolError.invalidJSON
        }

        switch commandName {
        case "LIVE_OPEN_PLATFORM_INTERACTION_END":
            return .sessionEnded(gameID: string(payload["game_id"]))
        case "LIVE_OPEN_PLATFORM_DM", "LIVE_OPEN_PLATFORM_DM_MIRROR":
            return .broadcast(try encode(type: "text", data: textData(
                payload,
                ownerOpenID: ownerOpenID,
                isMirror: commandName.hasSuffix("_MIRROR")
            )))
        case "LIVE_OPEN_PLATFORM_SEND_GIFT":
            return .broadcast(try encode(type: "gift", data: giftData(payload)))
        case "LIVE_OPEN_PLATFORM_GUARD":
            return .broadcast(try encode(type: "member", data: memberData(payload)))
        case "LIVE_OPEN_PLATFORM_SUPER_CHAT":
            return .broadcast(try encode(type: "superChat", data: superChatData(payload)))
        case "LIVE_OPEN_PLATFORM_SUPER_CHAT_DEL":
            let ids = (payload["message_ids"] as? [Any] ?? []).map { string($0) }
            return .broadcast(try encode(type: "deleteSuperChat", data: ["ids": ids]))
        default:
            return nil
        }
    }

    static func debug(_ content: String) -> Data {
        (try? encode(type: "debug", data: ["content": content])) ?? Data()
    }

    private static func textData(
        _ data: [String: Any],
        ownerOpenID: String,
        isMirror: Bool
    ) -> [String: Any] {
        let openID = string(data["open_id"])
        let guardLevel = int(data["guard_level"])
        let authorType: Int
        if !ownerOpenID.isEmpty && openID == ownerOpenID {
            authorType = 3
        } else if bool(data["is_admin"]) {
            authorType = 2
        } else if guardLevel != 0 {
            authorType = 1
        } else {
            authorType = 0
        }

        let message = string(data["msg"])
        let replyName = string(data["reply_uname"])
        let content = replyName.isEmpty ? message : "@\(replyName) \(message)"
        var result: [String: Any] = [
            "avatarUrl": secureURL(data["uface"]),
            "timestamp": int(data["timestamp"]),
            "authorName": string(data["uname"]),
            "authorType": authorType,
            "content": content,
            "privilegeType": guardLevel,
            "isGiftDanmaku": false,
            "medalLevel": bool(data["fans_medal_wearing_status"])
                ? int(data["fans_medal_level"]) : 0,
            "id": string(data["msg_id"]),
            "isMirror": isMirror,
            "uid": openID,
            "medalName": bool(data["fans_medal_wearing_status"])
                ? string(data["fans_medal_name"]) : "",
        ]
        if int(data["dm_type"]) == 1 {
            let emoticon = secureURL(data["emoji_img_url"])
            if !emoticon.isEmpty {
                result["emoticon"] = emoticon
            }
        }
        return result
    }

    private static func giftData(_ data: [String: Any]) -> [String: Any] {
        let value = int(data["r_price"]) * int(data["gift_num"])
        let isPaid = bool(data["paid"])
        return [
            "id": string(data["msg_id"]),
            "avatarUrl": secureURL(data["uface"]),
            "timestamp": int(data["timestamp"]),
            "authorName": string(data["uname"]),
            "totalCoin": isPaid ? value : 0,
            "totalFreeCoin": isPaid ? 0 : value,
            "giftName": string(data["gift_name"]),
            "num": int(data["gift_num"]),
            "giftId": int(data["gift_id"]),
            "giftIconUrl": secureURL(data["gift_icon"]),
            "uid": string(data["open_id"]),
            "privilegeType": int(data["guard_level"]),
            "medalLevel": bool(data["fans_medal_wearing_status"])
                ? int(data["fans_medal_level"]) : 0,
            "medalName": bool(data["fans_medal_wearing_status"])
                ? string(data["fans_medal_name"]) : "",
        ]
    }

    private static func memberData(_ data: [String: Any]) -> [String: Any] {
        let user = data["user_info"] as? [String: Any] ?? [:]
        return [
            "id": string(data["msg_id"]),
            "avatarUrl": secureURL(user["uface"]),
            "timestamp": int(data["timestamp"]),
            "authorName": string(user["uname"]),
            "privilegeType": int(data["guard_level"]),
            "num": int(data["guard_num"]),
            "unit": string(data["guard_unit"]),
            "total_coin": int(data["price"]) * int(data["guard_num"]),
            "uid": string(user["open_id"]),
            "medalLevel": bool(data["fans_medal_wearing_status"])
                ? int(data["fans_medal_level"]) : 0,
            "medalName": bool(data["fans_medal_wearing_status"])
                ? string(data["fans_medal_name"]) : "",
        ]
    }

    private static func superChatData(_ data: [String: Any]) -> [String: Any] {
        [
            "id": string(data["message_id"]),
            "avatarUrl": secureURL(data["uface"]),
            "timestamp": int(data["start_time"]),
            "authorName": string(data["uname"]),
            "price": int(data["rmb"]),
            "content": string(data["message"]),
            "uid": string(data["open_id"]),
            "privilegeType": int(data["guard_level"]),
            "medalLevel": bool(data["fans_medal_wearing_status"])
                ? int(data["fans_medal_level"]) : 0,
            "medalName": bool(data["fans_medal_wearing_status"])
                ? string(data["fans_medal_name"]) : "",
        ]
    }

    private static func encode(type: String, data: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "data": data])
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1"].contains(value.lowercased()) }
        return false
    }

    private static func secureURL(_ value: Any?) -> String {
        let raw = string(value)
        if raw.hasPrefix("//") { return "https:\(raw)" }
        if raw.hasPrefix("http://") { return "https://\(raw.dropFirst(7))" }
        return raw
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func uint16BE(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32BE(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}
