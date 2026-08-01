import Foundation

/// 表情列表的本地缓存。每次打开面板都等网络请求太难受，
/// 先把上次的结果铺出来，后台再悄悄刷新。
@MainActor
enum EmoteCache {
    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("DanmuHUD", isDirectory: true)
            .appendingPathComponent("emotes.json")
    }()

    static func load() -> [BilibiliAccount.EmotePack] {
        guard let data = try? Data(contentsOf: file),
              let packs = try? JSONDecoder().decode([BilibiliAccount.EmotePack].self, from: data) else {
            return []
        }
        return packs
    }

    static func save(_ packs: [BilibiliAccount.EmotePack]) {
        guard !packs.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(packs) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
