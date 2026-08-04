import Foundation
import Combine

/// 普通设置存在 UserDefaults；身份码单独存在权限受限的本地凭据文件。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// 内置样式表每次改版就 +1
    private static let currentCSSVersion = 13

    @Published var authCode: String {
        didSet {
            let normalized = authCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized.isEmpty {
                Keychain.delete(Keys.authCode)
            } else {
                Keychain.set(normalized, for: Keys.authCode)
            }
        }
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
          --blc-backdrop-alpha: \(String(format: "%.2f", backdropAlpha));
        }
        """
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let legacyRoomURL = "roomURL"
        static let authCode = "openLiveAuthCode"
        static let customCSS = "customCSS"
        static let opacity = "opacity"
        static let alwaysOnTop = "alwaysOnTop"
        static let presetID = "presetID"
        static let cssVersion = "cssVersion"
        static let bookmarkFrame = "bookmarkFrame"
        static let frame = "windowFrame"
        static let fontSize = "fontSize"
        static let nameOpacity = "nameOpacity"
        static let backdropAlpha = "backdropAlpha"
        static let showDebugMessages = "showDebugMessages"
        static let showOutline = "showOutline"
    }

    private init() {
        authCode = Self.loadAndMigrateAuthCode(defaults: defaults)
        let savedCSS = defaults.string(forKey: Keys.customCSS)
        customCSS = (savedCSS?.isEmpty == false) ? savedCSS! : DefaultStyle.css
        opacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        alwaysOnTop = defaults.object(forKey: Keys.alwaysOnTop) as? Bool ?? true
        presetID = defaults.string(forKey: Keys.presetID) ?? StylePreset.restrained.rawValue
        bookmarkFrame = defaults.string(forKey: Keys.bookmarkFrame) ?? ""
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 21
        nameOpacity = defaults.object(forKey: Keys.nameOpacity) as? Double ?? 0.75
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

    /// 旧版把身份码放在 UserDefaults 的整条 URL 里。首次读取后立即拆出凭据并删除旧值。
    private static func loadAndMigrateAuthCode(defaults: UserDefaults) -> String {
        if let saved = Keychain.get(Keys.authCode)?.uppercased() {
            if OpenLiveRuntime.isValidAuthCode(saved) {
                defaults.removeObject(forKey: Keys.legacyRoomURL)
                return saved
            }
            Keychain.delete(Keys.authCode)
        }

        let legacy = defaults.string(forKey: Keys.legacyRoomURL) ?? ""
        defaults.removeObject(forKey: Keys.legacyRoomURL)
        guard let code = legacy
            .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "&" || $0 == "=" })
            .map({ String($0).uppercased() })
            .first(where: { OpenLiveRuntime.isValidAuthCode($0) }) else {
            return ""
        }
        Keychain.set(code, for: Keys.authCode)
        return code
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
        backdropAlpha = preset.backdropAlpha
    }
}
