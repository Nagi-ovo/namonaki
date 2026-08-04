import Foundation

/// The last few messages received. The Open Live API serves no backlog, so the only way
/// to open on something other than a blank window is to keep our own.
///
/// The file is disposable by design: if it cannot be decoded (an older build wrote a
/// different shape) it is dropped rather than migrated.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let limit = 40
    private var items: [DanmakuMessage]

    private static let directory: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Namonaki", isDirectory: true)
    }()

    private static let file = directory.appendingPathComponent("messages.json")
    /// Rendered HTML fragments written by the WebView-based HUD.
    private static let legacyFile = directory.appendingPathComponent("history.json")

    private init() {
        try? FileManager.default.removeItem(at: Self.legacyFile)
        if let data = try? Data(contentsOf: Self.file),
           let list = try? JSONDecoder().decode([DanmakuMessage].self, from: data) {
            items = list
        } else {
            items = []
        }
    }

    var all: [DanmakuMessage] { items }

    func append(_ message: DanmakuMessage) {
        items.append(message)
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
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
