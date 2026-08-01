import Foundation

/// 几套现成的弹幕风格。共用同一份基础 CSS，靠变量和少量补丁拉开差别，
/// 这样改基础样式时三套一起受益，不会各写一份互相跑偏。
enum StylePreset: String, CaseIterable, Identifiable {
    case restrained
    case highContrast
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restrained: "克制"
        case .highContrast: "高对比"
        case .minimal: "极简"
        }
    }

    var summary: String {
        switch self {
        case .restrained: "默认。淡衬底，用户名往后退，正文突出。"
        case .highContrast: "衬底更实、字更大，浅色或杂乱画面上也读得清。"
        case .minimal: "去掉头像和衬底，只剩一行字，最不打扰画面。"
        }
    }

    var fontSize: Double {
        switch self {
        case .restrained: 21
        case .highContrast: 23
        case .minimal: 20
        }
    }

    var nameOpacity: Double {
        switch self {
        case .restrained: 0.75
        case .highContrast: 0.9
        case .minimal: 0.55
        }
    }

    var avatarSize: Double {
        switch self {
        case .restrained: 26
        case .highContrast: 28
        case .minimal: 0
        }
    }

    var backdropAlpha: Double {
        switch self {
        case .restrained: 0.38
        case .highContrast: 0.62
        case .minimal: 0
        }
    }

    var css: String {
        switch self {
        case .restrained, .highContrast:
            DefaultStyle.css
        case .minimal:
            DefaultStyle.css + """

            /* ---------- 极简：去掉头像，阴影加重补回可读性 ---------- */
            #author-photo { display: none !important; }
            yt-live-chat-text-message-renderer {
              padding: 3px 12px !important;
              margin: 0 !important;
              backdrop-filter: none !important;
            }
            #content {
              text-shadow: 0 1px 3px rgba(0, 0, 0, 0.85),
                           0 0 2px rgba(0, 0, 0, 0.7) !important;
            }
            """
        }
    }
}
