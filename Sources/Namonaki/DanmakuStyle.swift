import AppKit

/// How danmaku are drawn. The three sliders and the preset picker all land here.
///
/// The values are lifted one-for-one from `DefaultStyle.css`, which still styles the OBS
/// browser source. Changing the HUD's look means changing both to keep them in sync.
struct DanmakuStyle: Equatable {
    var fontSize: CGFloat = 21
    var nameOpacity: CGFloat = 0.75
    var backdropAlpha: CGFloat = 0.38
    var showsAvatar = true

    /// Space around a row, outside the backdrop.
    var horizontalMargin: CGFloat = 8
    var verticalMargin: CGFloat = 3
    /// Space inside the backdrop, around the text.
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 7
    var cornerRadius: CGFloat = 9
    var shadowAlpha: CGFloat = 0.5
    var shadowBlur: CGFloat = 2

    var nameFontSize: CGFloat { max(fontSize - 2, 9) }
    /// Avatars track the font size; two sliders fighting each other buys nothing.
    var avatarSize: CGFloat { (fontSize * 1.3).rounded() }
    var avatarSpacing: CGFloat { 10 }

    /// Source of truth for both renderers — the OBS page receives this over the relay
    /// rather than carrying its own copy. Danmaku regularly wrap to two or three lines,
    /// which is exactly where a tight leading starts to hurt.
    static let lineHeightRatio: CGFloat = 1.5
    var lineHeight: CGFloat { (fontSize * Self.lineHeightRatio).rounded() }
    /// Full-image emotes (the dress-up ones).
    var largeEmoticonHeight: CGFloat { 60 }
    var giftIconHeight: CGFloat { (fontSize * 1.4).rounded() }

    var messageFont: NSFont { .systemFont(ofSize: fontSize, weight: .regular) }
    var nameFont: NSFont { .systemFont(ofSize: nameFontSize, weight: .medium) }

    var backdropColor: NSColor {
        NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 14 / 255, alpha: backdropAlpha)
    }

    /// Super chats and new guards share the backdrop, a touch darker to set them apart.
    var highlightBackdropColor: NSColor {
        NSColor(
            srgbRed: 12 / 255, green: 12 / 255, blue: 14 / 255,
            alpha: min(backdropAlpha + 0.14, 1)
        )
    }

    var accentColor: NSColor {
        NSColor(srgbRed: 235 / 255, green: 197 / 255, blue: 133 / 255, alpha: 0.95)
    }

    var messageColor: NSColor { NSColor(white: 1, alpha: 0.97) }
    var separatorColor: NSColor { NSColor(white: 1, alpha: 0.45) }
    var mutedColor: NSColor { NSColor(white: 1, alpha: 0.42) }

    /// Rank shows up as name color only — no badges, no filled chips.
    func nameColor(for rank: DanmakuAuthor.Rank) -> NSColor {
        switch rank {
        case .owner:
            accentColor
        case .moderator:
            NSColor(srgbRed: 145 / 255, green: 187 / 255, blue: 222 / 255, alpha: 0.95)
        case .guardMember:
            NSColor(srgbRed: 160 / 255, green: 205 / 255, blue: 198 / 255, alpha: 0.95)
        case .viewer:
            NSColor(white: 1, alpha: nameOpacity)
        }
    }

    /// Enough to stay readable over a bright stream, restrained enough not to smear.
    var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    @MainActor
    static func current(_ prefs: Preferences = .shared) -> DanmakuStyle {
        var style = DanmakuStyle(
            fontSize: prefs.fontSize,
            nameOpacity: prefs.nameOpacity,
            backdropAlpha: prefs.backdropAlpha
        )
        if prefs.preset == .minimal {
            // Minimal: drop the avatar, tighten the rows, lean harder on the shadow.
            // Backdrop opacity still follows the slider (the preset already zeroes it).
            style.showsAvatar = false
            style.horizontalMargin = 0
            style.verticalMargin = 0
            style.verticalPadding = 3
            style.shadowAlpha = 0.85
            style.shadowBlur = 3
        }
        return style
    }
}
