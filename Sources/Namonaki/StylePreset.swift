import Foundation

/// Ready-made looks. Each is only a set of slider values plus, for `minimal`, a layout
/// switch that both renderers honour — there is no per-preset stylesheet to drift.
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


    var backdropAlpha: Double {
        switch self {
        case .restrained: 0.38
        case .highContrast: 0.62
        case .minimal: 0
        }
    }

}
