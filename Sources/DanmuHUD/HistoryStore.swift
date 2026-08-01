import Foundation

/// 最近若干条弹幕的缓存。开放平台接口不提供历史消息，
/// 所以只能自己把收到的存下来，下次启动先铺回窗口里，免得开着一片空白。
///
/// 存的是渲染好的 HTML 片段，这样样式和实时消息完全一致，不用再拼一遍 DOM。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let limit = 40
    private var items: [String]

    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("DanmuHUD", isDirectory: true)
            .appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            items = list
        } else {
            items = []
        }
    }

    var all: [String] { items }

    func append(_ html: String) {
        guard !html.isEmpty else { return }
        items.append(html)
        if items.count > limit {
            items.removeFirst(items.count - limit)
        }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        let fm = FileManager.default
        let dir = Self.file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
