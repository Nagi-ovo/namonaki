import Foundation
import Combine
import WebKit

/// 发弹幕用的账号状态。收弹幕走 blivechat 的开放平台接口（只读），
/// 发送必须用本人登录态，所以这里单独管一套 Cookie。
@MainActor
final class BilibiliAccount: ObservableObject {
    static let shared = BilibiliAccount()

    @Published private(set) var userName: String?
    @Published private(set) var uid: Int?
    @Published private(set) var roomID: Int?
    @Published private(set) var lastError: String?

    /// 手动指定的直播间号，留空就用登录账号自己的直播间
    @Published var manualRoomID: String {
        didSet { UserDefaults.standard.set(manualRoomID, forKey: "manualRoomID") }
    }

    var isLoggedIn: Bool { sessData != nil && csrf != nil }

    var effectiveRoomID: Int? {
        if let manual = Int(manualRoomID.trimmingCharacters(in: .whitespaces)), manual > 0 {
            return manual
        }
        return roomID
    }

    // 钥匙串读一次就缓存住。每次界面刷新都去读的话，本地签名的 app 会被系统
    // 反复弹窗要授权，烦得很。
    private lazy var cachedSess: String? = Keychain.get("SESSDATA")
    private lazy var cachedCSRF: String? = Keychain.get("bili_jct")
    private var sessData: String? { cachedSess }
    private var csrf: String? { cachedCSRF }
    private var lastSentAt: Date?

    private init() {
        manualRoomID = UserDefaults.standard.string(forKey: "manualRoomID") ?? ""
        userName = UserDefaults.standard.string(forKey: "biliUserName")
        let savedRoom = UserDefaults.standard.integer(forKey: "biliRoomID")
        roomID = savedRoom > 0 ? savedRoom : nil
    }

    // MARK: - 登录

    /// 从登录用的 WebView 里捞出 Cookie。SESSDATA 和 bili_jct 齐了才算登录成功。
    func adoptCookies(_ cookies: [HTTPCookie]) -> Bool {
        let wanted = Dictionary(
            cookies
                .filter { $0.name == "SESSDATA" || $0.name == "bili_jct" }
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let sess = wanted["SESSDATA"], let jct = wanted["bili_jct"],
              !sess.isEmpty, !jct.isEmpty else { return false }

        Keychain.set(sess, for: "SESSDATA")
        Keychain.set(jct, for: "bili_jct")
        cachedSess = sess
        cachedCSRF = jct
        objectWillChange.send()
        return true
    }

    func signOut() {
        Keychain.delete("SESSDATA")
        Keychain.delete("bili_jct")
        cachedSess = nil
        cachedCSRF = nil
        userName = nil
        uid = nil
        roomID = nil
        UserDefaults.standard.removeObject(forKey: "biliUserName")
        UserDefaults.standard.removeObject(forKey: "biliRoomID")
        objectWillChange.send()
    }

    // MARK: - 拉取账号信息

    /// 登录后查一次昵称和自己的直播间号，省得让人手填
    func refreshProfile() async {
        guard isLoggedIn else { return }
        do {
            let nav = try await getJSON("https://api.bilibili.com/x/web-interface/nav")
            guard let data = nav["data"] as? [String: Any],
                  let mid = data["mid"] as? Int else {
                lastError = "登录态已失效，请重新登录"
                return
            }
            uid = mid
            userName = data["uname"] as? String
            UserDefaults.standard.set(userName, forKey: "biliUserName")

            let master = try await getJSON("https://api.live.bilibili.com/live_user/v1/Master/info?uid=\(mid)")
            if let d = master["data"] as? [String: Any],
               let info = d["info"] as? [String: Any],
               let room = d["room_id"] as? Int ?? info["room_id"] as? Int, room > 0 {
                roomID = room
                UserDefaults.standard.set(room, forKey: "biliRoomID")
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 表情

    struct Emoticon: Identifiable, Hashable {
        let id: String        // emoticon_unique，发送时当 msg 用
        let text: String      // 触发词，形如 [妙]
        let url: String
        let descript: String
        /// 没解锁的表情发出去会被服务端拒绝，先在界面上标出来
        let locked: Bool
    }

    @Published private(set) var emoticons: [Emoticon] = []

    /// 拉取当前直播间可用的表情包。要登录，而且不同直播间的表情不一样。
    func refreshEmoticons() async {
        guard isLoggedIn, let room = effectiveRoomID else { return }
        let url = "https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons"
            + "?platform=pc&room_id=\(room)"
        guard let json = try? await getJSON(url),
              let data = json["data"] as? [String: Any],
              let packs = data["data"] as? [[String: Any]] else { return }

        emoticons = packs.flatMap { pack -> [Emoticon] in
            let list = pack["emoticons"] as? [[String: Any]] ?? []
            return list.compactMap { item in
                guard let unique = item["emoticon_unique"] as? String else { return nil }
                // perm 为 0 一般表示没有使用权限（等级或粉丝勋章不够）
                let perm = item["perm"] as? Int ?? 1
                return Emoticon(
                    id: unique,
                    text: item["emoji"] as? String ?? "",
                    url: Self.httpsURL(item["url"] as? String ?? ""),
                    descript: item["descript"] as? String ?? "",
                    locked: perm == 0
                )
            }
        }
    }

    // MARK: - 发送

    enum SendError: LocalizedError {
        case notLoggedIn
        case noRoom
        case tooFast
        case empty
        case api(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "还没登录 B 站账号"
            case .noRoom: "不知道要发到哪个直播间，先在设置里填直播间号"
            case .tooFast: "发太快了，等一秒再发"
            case .empty: "内容是空的"
            case .api(let code, let message):
                switch code {
                case -101: "账号未登录，需要重新登录"
                case -111: "登录态过期了，重新登录一次"
                case 1003212: "这条太长了，B 站不让发"
                case 10031: "发送频率过快，缓一下"
                default: "发送失败（\(code)）：\(message)"
                }
            }
        }
    }

    /// 发大表情：msg 传表情的 emoticon_unique，再用 dm_type=1 告诉服务端这是表情
    func send(emoticon: Emoticon) async throws {
        try await send(emoticon.id, dmType: 1)
    }

    func send(_ raw: String, dmType: Int = 0) async throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SendError.empty }
        guard let sess = sessData, let jct = csrf else { throw SendError.notLoggedIn }
        guard let room = effectiveRoomID else { throw SendError.noRoom }

        // B 站对发送频率有限制，本地先挡一道，免得白白撞风控
        if let last = lastSentAt, Date().timeIntervalSince(last) < 1.2 {
            throw SendError.tooFast
        }

        var request = URLRequest(url: URL(string: "https://api.live.bilibili.com/msg/send")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("SESSDATA=\(sess); bili_jct=\(jct)", forHTTPHeaderField: "Cookie")
        request.setValue("https://live.bilibili.com/\(room)", forHTTPHeaderField: "Referer")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let fields: [String: String] = [
            "bubble": "0",
            "dm_type": String(dmType),
            "msg": text,
            "color": "16777215",
            "mode": "1",
            "room_type": "0",
            "jumpfrom": "0",
            "reply_mid": "0",
            "reply_attr": "0",
            "replay_dmid": "",
            "statistics": #"{"appId":100,"platform":5}"#,
            "fontsize": "25",
            "rnd": String(Int(Date().timeIntervalSince1970)),
            "roomid": String(room),
            "csrf": jct,
            "csrf_token": jct
        ]
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = json["code"] as? Int ?? -1
        guard code == 0 else {
            throw SendError.api(code: code, message: json["message"] as? String ?? "")
        }
        lastSentAt = Date()
    }

    // MARK: - 工具

    /// B 站返回的表情图是 http 的，而 ATS 只放行了网页内的明文请求，
    /// app 自己发的（AsyncImage 走 URLSession）会被拦掉，图就一片空白。
    /// 这些 CDN 都支持 https，直接升级协议最干净，不用放宽 ATS。
    private static func httpsURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("http://") { return "https://" + raw.dropFirst("http://".count) }
        return raw
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private func getJSON(_ urlString: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        if let sess = sessData, let jct = csrf {
            request.setValue("SESSDATA=\(sess); bili_jct=\(jct)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
