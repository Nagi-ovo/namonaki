import Foundation

/// 项目从 DanmuHUD 改名成 Namonaki，bundle id 和数据目录都变了。
/// UserDefaults 是按 bundle id 分域的，不搬的话房间地址、样式设置全部归零；
/// 凭证和缓存放在应用支持目录，目录名也跟着换了。
///
/// 这段只在首次启动时跑一次，搬完就不再碰旧数据（留着当备份）。
@MainActor
enum Migration {
    private static let flag = "migratedFromDanmuHUD"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        migrateDefaults()
        migrateSupportFiles()
    }

    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        // 已经有配置就别覆盖
        guard (defaults.string(forKey: "roomURL") ?? "").isEmpty else { return }
        guard let old = UserDefaults(suiteName: "fun.nagi.danmuhud") else { return }

        for (key, value) in old.dictionaryRepresentation() {
            // 系统自己塞的那些 Apple 前缀键不要搬
            guard !key.hasPrefix("Apple"), !key.hasPrefix("NS"), !key.hasPrefix("com.apple") else {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }

    private static func migrateSupportFiles() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let old = base.appendingPathComponent("DanmuHUD", isDirectory: true)
        let new = base.appendingPathComponent("Namonaki", isDirectory: true)

        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.copyItem(at: old, to: new)
    }
}
