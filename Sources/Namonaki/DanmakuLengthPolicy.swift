import Foundation

/// 服务端只用 1003212 表示超长，不直接返回具体上限，
/// 所以从 60 字开始按 10 字一档做真实发送探测。
enum DanmakuLengthPolicy {
    static let advertisedLimit = 60
    static let probeLimits = [60, 50, 40, 30, 20]

    static func firstAttempt(_ text: String, detectedLimit: Int?) -> String {
        guard let detectedLimit else { return text }
        return truncate(text, to: detectedLimit)
    }

    static func retryLimits(afterRejectedLength length: Int) -> [Int] {
        probeLimits.filter { $0 < length }
    }

    /// String.prefix 按 Character 截，不会把组合 emoji 或 Unicode 字符切成半个。
    static func truncate(_ text: String, to limit: Int) -> String {
        String(text.prefix(limit))
    }
}

/// 保存当前账号测出的弹幕长度，并按 UID 隔离不同账号的结果。
struct DanmakuLimitStore {
    private enum Keys {
        static let currentUID = "biliDanmakuLimit.currentUID"
        static let currentLimit = "biliDanmakuLimit.current"
        static let accountPrefix = "biliDanmakuLimit.account."
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var currentUID: Int? {
        positiveInt(forKey: Keys.currentUID)
    }

    var currentLimit: Int? {
        positiveInt(forKey: Keys.currentLimit)
    }

    /// 切换到指定账号。旧版本可能已经测出上限、但还不知道 UID，
    /// 这种情况下把当前结果迁移到第一次识别出的账号。
    @discardableResult
    func activate(uid: Int) -> Int? {
        if currentUID == uid {
            let saved = currentLimit ?? accountLimit(for: uid)
            setCurrentLimit(saved)
            return saved
        }

        if currentUID == nil, let pending = currentLimit {
            defaults.set(uid, forKey: Keys.currentUID)
            defaults.set(pending, forKey: accountKey(uid))
            return pending
        }

        let saved = accountLimit(for: uid)
        defaults.set(uid, forKey: Keys.currentUID)
        setCurrentLimit(saved)
        return saved
    }

    func save(limit: Int, uid: Int?) {
        guard limit > 0 else { return }
        defaults.set(limit, forKey: Keys.currentLimit)
        guard let uid else { return }
        defaults.set(uid, forKey: Keys.currentUID)
        defaults.set(limit, forKey: accountKey(uid))
    }

    func clearCurrentAccount() {
        defaults.removeObject(forKey: Keys.currentUID)
        defaults.removeObject(forKey: Keys.currentLimit)
    }

    private func accountLimit(for uid: Int) -> Int? {
        positiveInt(forKey: accountKey(uid))
    }

    private func accountKey(_ uid: Int) -> String {
        Keys.accountPrefix + String(uid)
    }

    private func setCurrentLimit(_ limit: Int?) {
        if let limit {
            defaults.set(limit, forKey: Keys.currentLimit)
        } else {
            defaults.removeObject(forKey: Keys.currentLimit)
        }
    }

    private func positiveInt(forKey key: String) -> Int? {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
        let result = value.intValue
        return result > 0 ? result : nil
    }
}
