import Foundation
import Combine

/// 所有设置都存在 UserDefaults 里，退出后保留。
/// 房间 URL 里带身份码，属于敏感信息，只留在本机。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// 内置样式表每次改版就 +1
    private static let currentCSSVersion = 7

    @Published var roomURL: String {
        didSet { defaults.set(roomURL, forKey: Keys.roomURL) }
    }
    @Published var customCSS: String {
        didSet { defaults.set(customCSS, forKey: Keys.customCSS) }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop) }
    }
    @Published var presetID: String {
        didSet { defaults.set(presetID, forKey: Keys.presetID) }
    }
    /// 收藏的窗口位置，一键回位用。空字符串表示还没存过。
    @Published var bookmarkFrame: String {
        didSet { defaults.set(bookmarkFrame, forKey: Keys.bookmarkFrame) }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var nameOpacity: Double {
        didSet { defaults.set(nameOpacity, forKey: Keys.nameOpacity) }
    }
    @Published var avatarSize: Double {
        didSet { defaults.set(avatarSize, forKey: Keys.avatarSize) }
    }
    /// 每条弹幕背后垫的深色衬底浓度。0 = 全透明，靠阴影撑；
    /// 浅色桌面上调到 0.4 左右才读得清。
    @Published var backdropAlpha: Double {
        didSet { defaults.set(backdropAlpha, forKey: Keys.backdropAlpha) }
    }
    /// blivechat 的连接状态提示（Connecting / Disconnected 之类），默认不显示
    @Published var showDebugMessages: Bool {
        didSet { defaults.set(showDebugMessages, forKey: Keys.showDebugMessages) }
    }
    /// 始终画一圈极淡的边框，标出窗口范围——没弹幕时窗口全透明，容易找不着
    @Published var showOutline: Bool {
        didSet { defaults.set(showOutline, forKey: Keys.showOutline) }
    }

    /// 覆盖 CSS 里那几个变量的默认值，注入时拼在样式表后面
    var variableCSS: String {
        """
        :root {
          --blc-font-size: \(Int(fontSize))px;
          --blc-name-opacity: \(String(format: "%.2f", nameOpacity));
          --blc-avatar-size: \(Int(avatarSize))px;
          --blc-backdrop-alpha: \(String(format: "%.2f", backdropAlpha));
        }
        """
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let roomURL = "roomURL"
        static let customCSS = "customCSS"
        static let opacity = "opacity"
        static let alwaysOnTop = "alwaysOnTop"
        static let presetID = "presetID"
        static let cssVersion = "cssVersion"
        static let bookmarkFrame = "bookmarkFrame"
        static let frame = "windowFrame"
        static let fontSize = "fontSize"
        static let nameOpacity = "nameOpacity"
        static let avatarSize = "avatarSize"
        static let backdropAlpha = "backdropAlpha"
        static let showDebugMessages = "showDebugMessages"
        static let showOutline = "showOutline"
    }

    private init() {
        roomURL = defaults.string(forKey: Keys.roomURL) ?? ""
        let savedCSS = defaults.string(forKey: Keys.customCSS)
        customCSS = (savedCSS?.isEmpty == false) ? savedCSS! : DefaultStyle.css
        opacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        presetID = defaults.string(forKey: Keys.presetID) ?? StylePreset.restrained.rawValue
        bookmarkFrame = defaults.string(forKey: Keys.bookmarkFrame) ?? ""
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 21
        nameOpacity = defaults.object(forKey: Keys.nameOpacity) as? Double ?? 0.75
        avatarSize = defaults.object(forKey: Keys.avatarSize) as? Double ?? 26
        backdropAlpha = defaults.object(forKey: Keys.backdropAlpha) as? Double ?? 0.38
        showDebugMessages = defaults.bool(forKey: Keys.showDebugMessages)
        showOutline = defaults.bool(forKey: Keys.showOutline)

        // 内置样式改版后，把还停在旧版本的用户升上来，
        // 否则新加的规则（比如衬底）永远不会生效
        if defaults.integer(forKey: Keys.cssVersion) < Self.currentCSSVersion {
            customCSS = preset.css
            defaults.set(Self.currentCSSVersion, forKey: Keys.cssVersion)
        }
    }

    var savedFrame: NSRect? {
        guard let raw = defaults.string(forKey: Keys.frame) else { return nil }
        return NSRectFromString(raw)
    }

    func saveFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: Keys.frame)
    }

    func resetCSS() {
        customCSS = DefaultStyle.css
    }

    var preset: StylePreset {
        StylePreset(rawValue: presetID) ?? .restrained
    }

    /// 套用预设：样式表和几根滑杆一起改，免得只换一半
    func apply(_ preset: StylePreset) {
        presetID = preset.rawValue
        customCSS = preset.css
        fontSize = preset.fontSize
        nameOpacity = preset.nameOpacity
        avatarSize = preset.avatarSize
        backdropAlpha = preset.backdropAlpha
    }
}
