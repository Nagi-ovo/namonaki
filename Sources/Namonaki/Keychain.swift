import Foundation

/// 登录凭证的本地存储。
///
/// 原来放钥匙串，但每次重新编译都是一份新签名，系统就当成「另一个 app 来读」，
/// 于是反复弹窗要密码。改成存文件：目录和文件都设成 0700 / 0600，只有当前用户能读，
/// 也不进 UserDefaults（那玩意是明文 plist，还会被备份带走）。
///
/// 取舍说明：这比钥匙串弱——钥匙串是加密的，文件只是靠权限挡着。
/// 对「本机自用」够了；要是哪天这东西给别人用，应该换回钥匙串并配好 ACL。
@MainActor
enum Keychain {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Namonaki", isDirectory: true)
    }()

    private static let file = directory.appendingPathComponent("credentials.json")

    private static var cache: [String: String] = load()

    static func set(_ value: String, for key: String) {
        cache[key] = value
        persist()
    }

    static func get(_ key: String) -> String? {
        cache[key]
    }

    static func delete(_ key: String) {
        cache.removeValue(forKey: key)
        persist()
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func persist() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONSerialization.data(withJSONObject: cache) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
