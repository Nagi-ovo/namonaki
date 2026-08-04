import Foundation

/// Author of a message. Every field comes from the Open Live push; receiving is read-only.
struct DanmakuAuthor: Codable, Equatable, Sendable {
    var name: String = ""
    var avatarURL: String = ""
    var uid: String = ""
    /// 0 viewer / 1 guard / 2 moderator / 3 room owner
    var type: Int = 0
    /// Guard tier: 0 none / 1 governor / 2 admiral / 3 captain
    var privilegeType: Int = 0
    var medalName: String = ""
    var medalLevel: Int = 0

    /// Drives the name color. Owner, moderator and guards each get one; everyone else
    /// follows the name-opacity slider.
    enum Rank {
        case viewer, guardMember, moderator, owner
    }

    var rank: Rank {
        if type == 3 { return .owner }
        if type == 2 { return .moderator }
        if type == 1 || privilegeType != 0 { return .guardMember }
        return .viewer
    }
}

/// A message received from the Open Live platform that we actually display.
///
/// Single source of truth for both renderers: the native HUD consumes this type directly,
/// while `relayPayload` turns it into the JSON the bundled blivechat frontend expects.
enum DanmakuMessage: Codable, Equatable, Sendable {
    case text(Text)
    case gift(Gift)
    case member(Member)
    case superChat(SuperChat)
    case deleteSuperChat(ids: [String])

    struct Text: Codable, Equatable, Sendable {
        var id: String = ""
        var timestamp: Int = 0
        var author: DanmakuAuthor = DanmakuAuthor()
        var content: String = ""
        /// When `dm_type == 1` the whole message is one image; the text is just its `[name]`.
        var emoticonURL: String?
        var isMirror: Bool = false
    }

    struct Gift: Codable, Equatable, Sendable {
        var id: String = ""
        var timestamp: Int = 0
        var author: DanmakuAuthor = DanmakuAuthor()
        var giftID: Int = 0
        var giftName: String = ""
        var giftIconURL: String = ""
        var num: Int = 0
        /// Paid gifts carry their value here; free gifts land in `totalFreeCoin` instead.
        var totalCoin: Int = 0
        var totalFreeCoin: Int = 0

        var isPaid: Bool { totalCoin > 0 }
    }

    struct Member: Codable, Equatable, Sendable {
        var id: String = ""
        var timestamp: Int = 0
        var author: DanmakuAuthor = DanmakuAuthor()
        var num: Int = 0
        var unit: String = ""
        var totalCoin: Int = 0

        var levelName: String {
            switch author.privilegeType {
            case 1: "总督"
            case 2: "提督"
            case 3: "舰长"
            default: "大航海"
            }
        }
    }

    struct SuperChat: Codable, Equatable, Sendable {
        var id: String = ""
        var timestamp: Int = 0
        var author: DanmakuAuthor = DanmakuAuthor()
        var content: String = ""
        /// In CNY.
        var price: Int = 0
    }

    var id: String {
        switch self {
        case .text(let message): message.id
        case .gift(let message): message.id
        case .member(let message): message.id
        case .superChat(let message): message.id
        case .deleteSuperChat(let ids): ids.joined(separator: ",")
        }
    }

    var author: DanmakuAuthor? {
        switch self {
        case .text(let message): message.author
        case .gift(let message): message.author
        case .member(let message): message.author
        case .superChat(let message): message.author
        case .deleteSuperChat: nil
        }
    }

    /// Worth persisting so a cold start is not blank. Deletions and free gifts are not.
    var isWorthKeeping: Bool {
        switch self {
        case .text, .member, .superChat: true
        case .gift(let gift): gift.isPaid
        case .deleteSuperChat: false
        }
    }
}

// MARK: - blivechat wire format

extension DanmakuMessage {
    /// Bytes sent to the OBS browser source. Field names and shape must match the
    /// blivechat frontend, and only these fields go out — nothing from the upstream
    /// session payload is forwarded.
    var relayPayload: Data {
        (try? JSONSerialization.data(withJSONObject: relayObject)) ?? Data()
    }

    private var relayObject: [String: Any] {
        switch self {
        case .text(let message):
            var data = message.author.relayFields
            data["id"] = message.id
            data["timestamp"] = message.timestamp
            data["content"] = message.content
            data["authorType"] = message.author.type
            data["isGiftDanmaku"] = false
            data["isMirror"] = message.isMirror
            if let emoticon = message.emoticonURL, !emoticon.isEmpty {
                data["emoticon"] = emoticon
            }
            return ["type": "text", "data": data]

        case .gift(let message):
            var data = message.author.relayFields
            data["id"] = message.id
            data["timestamp"] = message.timestamp
            data["totalCoin"] = message.totalCoin
            data["totalFreeCoin"] = message.totalFreeCoin
            data["giftName"] = message.giftName
            data["num"] = message.num
            data["giftId"] = message.giftID
            data["giftIconUrl"] = message.giftIconURL
            return ["type": "gift", "data": data]

        case .member(let message):
            var data = message.author.relayFields
            data["id"] = message.id
            data["timestamp"] = message.timestamp
            data["num"] = message.num
            data["unit"] = message.unit
            data["total_coin"] = message.totalCoin
            return ["type": "member", "data": data]

        case .superChat(let message):
            var data = message.author.relayFields
            data["id"] = message.id
            data["timestamp"] = message.timestamp
            data["price"] = message.price
            data["content"] = message.content
            return ["type": "superChat", "data": data]

        case .deleteSuperChat(let ids):
            return ["type": "deleteSuperChat", "data": ["ids": ids]]
        }
    }
}

private extension DanmakuAuthor {
    var relayFields: [String: Any] {
        [
            "authorName": name,
            "avatarUrl": avatarURL,
            "uid": uid,
            "privilegeType": privilegeType,
            "medalLevel": medalLevel,
            "medalName": medalName,
        ]
    }
}
