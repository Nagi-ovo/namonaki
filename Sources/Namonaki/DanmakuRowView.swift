import AppKit

/// One row in the list. Subclasses measure themselves and lay out their own content.
///
/// Layout is manual rather than Auto Layout: there are many rows and only one width to
/// solve for, and when a late-arriving image changes a row's height only that row is
/// remeasured.
@MainActor
class DanmakuRow: NSView {
    var style: DanmakuStyle {
        didSet {
            guard style != oldValue else { return }
            styleDidChange()
        }
    }

    /// Fired when an image lands and the row no longer fits its old height.
    var onSizeChanged: (() -> Void)?

    /// Who right-click replies to. Dividers and status lines have no author.
    var author: String? { nil }
    /// Used to find the row again when a super chat is deleted.
    var messageID: String? { nil }

    init(style: DanmakuStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override var isFlipped: Bool { true }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat { 0 }

    func styleDidChange() {
        needsDisplay = true
        needsLayout = true
    }
}

/// The message text.
///
/// A text view rather than a label, because a selectable NSTextField does not draw its
/// own selection: clicking one swaps in the window's field editor, a shared NSTextView
/// laid over that row, which lays the text out on its own terms. That reflowed the row
/// and pushed text outside the backdrop, and it stuck, because an overlay window that
/// ignores the mouse almost never hands first responder back. A text view is the
/// responder itself, so there is one layout and it never changes.
@MainActor
final class DanmakuTextView: NSTextView {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    /// Selection needs first responder, but the row must not show a focus ring.
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }
}

// MARK: - A message

@MainActor
final class DanmakuMessageRow: DanmakuRow {
    private let message: DanmakuMessage
    private let label = DanmakuTextView()
    private let avatarView = NSImageView()
    /// Full-image emote or gift icon. Sits after the text, wrapping to its own line if
    /// there is not enough room.
    private var trailingImageView: NSImageView?
    private var trailingImageURL: String?
    private var trailingImageHeight: CGFloat = 0
    private var trailingImageAspect: CGFloat = 1

    var onReply: ((String) -> Void)?

    override var author: String? {
        let name = message.author?.name ?? ""
        return name.isEmpty ? nil : name
    }

    override var messageID: String? { message.id }

    /// Super chats and new guards get a heavier backdrop plus a gold rule.
    private var isHighlighted: Bool {
        switch message {
        case .superChat, .member: true
        default: false
        }
    }

    /// Events get more room above and below than ordinary chatter. Only vertical — the
    /// avatars have to stay in one column down the whole feed.
    private var verticalMargin: CGFloat {
        style.verticalMargin + (isHighlighted ? 5 : 0)
    }

    init(message: DanmakuMessage, style: DanmakuStyle) {
        self.message = message
        super.init(style: style)

        label.isSelectable = true
        label.isEditable = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.usesFontPanel = false
        label.allowsUndo = false
        // A text view pads and insets its text by default; the row already owns its
        // padding, so both have to go or the text sits off-centre.
        label.textContainerInset = .zero
        label.textContainer?.lineFragmentPadding = 0
        // The row owns the geometry: if the container tracked the view instead, the
        // width handed to `textSize(forWidth:)` would be ignored and nothing would wrap.
        label.textContainer?.widthTracksTextView = false
        label.isHorizontallyResizable = false
        label.isVerticallyResizable = false
        label.menuProvider = { [weak self] in self?.replyMenu() }
        addSubview(label)

        avatarView.imageScaling = .scaleAxesIndependently
        avatarView.wantsLayer = true
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(avatarView)

        configureTrailingImage()
        applyText()
        loadImages()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        replyMenu()
    }

    private func replyMenu() -> NSMenu? {
        let menu = NSMenu()
        if let author, onReply != nil {
            let reply = NSMenuItem(
                title: "回复 @\(author)",
                action: #selector(replyAction),
                keyEquivalent: ""
            )
            reply.target = self
            menu.addItem(reply)
            menu.addItem(.separator())
        }
        let copyItem = NSMenuItem(title: "拷贝", action: #selector(copyText), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        return menu
    }

    @objc private func replyAction() {
        guard let author else { return }
        onReply?(author)
    }

    /// Copies the selection, or the whole message when nothing is selected — right
    /// clicking without selecting first should still get you the text.
    @objc private func copyText() {
        let full = label.string
        let selected = label.selectedRange()
        let text = selected.length > 0
            ? (full as NSString).substring(with: selected)
            : full
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func styleDidChange() {
        applyText()
        configureTrailingImage()
        super.styleDidChange()
        onSizeChanged?()
    }

    // MARK: Content

    private func configureTrailingImage() {
        let (url, height): (String?, CGFloat)
        switch message {
        case .text(let text):
            (url, height) = (text.emoticonURL, style.largeEmoticonHeight)
        case .gift(let gift):
            (url, height) = (gift.giftIconURL.isEmpty ? nil : gift.giftIconURL, style.giftIconHeight)
        default:
            (url, height) = (nil, 0)
        }

        trailingImageHeight = height
        guard let url, !url.isEmpty else {
            trailingImageView?.removeFromSuperview()
            trailingImageView = nil
            trailingImageURL = nil
            return
        }
        guard trailingImageURL != url else { return }

        trailingImageURL = url
        let view = trailingImageView ?? {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            addSubview(view)
            trailingImageView = view
            return view
        }()
        view.image = nil
    }

    private func applyText() {
        label.textStorage?.setAttributedString(attributedContent())
    }

    /// Lays the text out against a fixed width and reports what it actually used.
    /// Both measuring and positioning go through here so they cannot disagree.
    private func textSize(forWidth width: CGFloat) -> NSSize {
        guard let container = label.textContainer, let manager = label.layoutManager else {
            return .zero
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: min(ceil(used.width), width), height: ceil(used.height))
    }

    private func attributedContent() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = breakMode
        // Fixed line height rather than added leading, so it stays put across the mixed
        // name/message sizes on one line — the same thing CSS `line-height` does.
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight

        let result = NSMutableAttributedString()
        let shadow = style.textShadow

        func append(_ text: String, font: NSFont, color: NSColor) {
            guard !text.isEmpty else { return }
            result.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: shadow,
            ]))
        }

        let author = message.author ?? DanmakuAuthor()
        // Super chats and new guards carry the accent already; the rank colour would only
        // compete with the gold rule next to it.
        let nameColor = isHighlighted ? style.accentColor : style.nameColor(for: author.rank)
        append(author.name, font: style.nameFont, color: nameColor)

        switch message {
        case .text(let text):
            // Without the colon the name and the message run together and it stops being
            // obvious who said what.
            append("：", font: style.nameFont, color: style.separatorColor)
            // For a full-image emote the text is only the emote's `[name]`, and the image
            // itself follows — printing both would say the same thing twice.
            if text.emoticonURL == nil {
                append(text.content, font: style.messageFont, color: style.messageColor)
            }

        case .superChat(let superChat):
            append("  ¥\(superChat.price)", font: style.nameFont, color: style.accentColor)
            append("\n" + superChat.content, font: style.messageFont, color: style.messageColor)

        case .member(let member):
            let count = member.num > 1 ? "\(member.num)\(member.unit)" : ""
            append(
                "　开通了\(count)\(member.levelName)",
                font: style.messageFont,
                color: style.messageColor
            )

        case .gift(let gift):
            append(
                "　送出 \(gift.giftName) ×\(gift.num)",
                font: style.messageFont,
                color: style.messageColor
            )

        case .deleteSuperChat:
            break
        }
        return result
    }

    private func loadImages() {
        let author = message.author ?? DanmakuAuthor()
        if !author.avatarURL.isEmpty {
            RemoteImageLoader.shared.load(author.avatarURL) { [weak self] image in
                self?.avatarView.image = image
            }
        }
        guard let url = trailingImageURL else { return }
        RemoteImageLoader.shared.load(url) { [weak self] image in
            guard let self, self.trailingImageURL == url else { return }
            self.trailingImageView?.image = image
            let size = image.size
            self.trailingImageAspect = size.height > 0 ? size.width / size.height : 1
            // The row just grew; the list has to re-lay everything below it.
            self.onSizeChanged?()
        }
    }

    // MARK: Wrapping

    private var breakMode: NSLineBreakMode = .byWordWrapping

    /// AppKit has no `overflow-wrap: break-word`. Word wrapping alone lets an unbroken
    /// run — a pasted link, a wall of latin characters — run past the row and get
    /// clipped. Character wrapping never overflows but splits ordinary words mid-way, so
    /// it is switched on only for the messages that actually need it.
    private func updateBreakMode(forContentWidth width: CGFloat) {
        let text = label.attributedString()
        guard text.length > 0 else { return }

        // CJK has no spaces, so a long Chinese message counts as one run and ends up
        // character-wrapped — which is exactly how browsers break it anyway.
        let longest = text.string
            .components(separatedBy: .whitespacesAndNewlines)
            .max(by: { $0.count < $1.count }) ?? ""
        let attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        let overflows = (longest as NSString).size(withAttributes: attributes).width > width

        let wanted: NSLineBreakMode = overflows ? .byCharWrapping : .byWordWrapping
        guard wanted != breakMode else { return }
        breakMode = wanted
        applyText()
    }

    // MARK: Measuring and layout

    /// Where the avatar, the text and the trailing image end up. Measuring and laying out
    /// share it so the two can never disagree.
    private struct Layout {
        var contentOrigin: NSPoint
        var contentWidth: CGFloat
        var labelSize: NSSize
        var labelOrigin: NSPoint
        var imageRect: NSRect?
        var height: CGFloat
    }

    private func computeLayout(forWidth width: CGFloat) -> Layout {
        let avatarSlot = style.showsAvatar ? style.avatarSize + style.avatarSpacing : 0
        // Identical for every row: the gold rule is 3pt wide and the content already
        // starts 12pt inside the backdrop, so there is nothing to make room for.
        let originX = style.horizontalMargin + style.horizontalPadding
        let contentX = originX + avatarSlot
        let contentWidth = max(
            width - contentX - style.horizontalMargin - style.horizontalPadding,
            40
        )

        updateBreakMode(forContentWidth: contentWidth)
        let labelSize = textSize(forWidth: contentWidth)

        var imageSize = NSSize.zero
        if trailingImageView != nil {
            let height = trailingImageHeight
            imageSize = NSSize(
                width: min((height * trailingImageAspect).rounded(), contentWidth),
                height: height
            )
        }

        var labelOrigin = NSPoint(x: contentX, y: 0)
        var imageRect: NSRect?
        var contentHeight = labelSize.height

        if imageSize != .zero {
            let gap: CGFloat = 6
            if labelSize.width + gap + imageSize.width <= contentWidth {
                // Fits on one line: centre the text and the image against each other.
                contentHeight = max(labelSize.height, imageSize.height)
                labelOrigin.y = ((contentHeight - labelSize.height) / 2).rounded()
                imageRect = NSRect(
                    x: contentX + labelSize.width + gap,
                    y: ((contentHeight - imageSize.height) / 2).rounded(),
                    width: imageSize.width,
                    height: imageSize.height
                )
            } else {
                contentHeight = labelSize.height + 4 + imageSize.height
                imageRect = NSRect(
                    x: contentX,
                    y: labelSize.height + 4,
                    width: imageSize.width,
                    height: imageSize.height
                )
            }
        }

        let innerHeight = max(contentHeight, style.showsAvatar ? style.avatarSize : 0)
        let height = innerHeight + (style.verticalPadding + verticalMargin) * 2

        return Layout(
            contentOrigin: NSPoint(x: originX, y: verticalMargin + style.verticalPadding),
            contentWidth: contentWidth,
            labelSize: labelSize,
            labelOrigin: labelOrigin,
            imageRect: imageRect,
            height: height
        )
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        computeLayout(forWidth: width).height.rounded(.up)
    }

    override func layout() {
        super.layout()
        let plan = computeLayout(forWidth: bounds.width)
        let top = plan.contentOrigin.y
        let innerHeight = bounds.height - (style.verticalPadding + verticalMargin) * 2

        if style.showsAvatar {
            avatarView.isHidden = false
            let size = style.avatarSize
            avatarView.frame = NSRect(
                x: plan.contentOrigin.x,
                y: top + ((innerHeight - size) / 2).rounded(),
                width: size,
                height: size
            )
            avatarView.layer?.cornerRadius = size / 2
        } else {
            avatarView.isHidden = true
        }

        label.frame = NSRect(
            x: plan.labelOrigin.x,
            y: top + plan.labelOrigin.y,
            width: plan.contentWidth,
            height: plan.labelSize.height
        )

        if let rect = plan.imageRect, let view = trailingImageView {
            view.isHidden = false
            view.frame = rect.offsetBy(dx: 0, dy: top)
        } else {
            trailingImageView?.isHidden = true
        }
    }

    // MARK: Backdrop

    private static let highlightBarWidth: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSRect(
            x: style.horizontalMargin,
            y: verticalMargin,
            width: max(bounds.width - style.horizontalMargin * 2, 0),
            height: max(bounds.height - verticalMargin * 2, 0)
        )
        guard inset.width > 0, inset.height > 0 else { return }

        let color = isHighlighted ? style.highlightBackdropColor : style.backdropColor
        if color.alphaComponent > 0.001 {
            color.setFill()
            NSBezierPath(
                roundedRect: inset,
                xRadius: style.cornerRadius,
                yRadius: style.cornerRadius
            ).fill()
        }

        guard isHighlighted else { return }
        // Clip to the rounded backdrop so the rule follows the corner instead of poking
        // out of it.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: inset,
            xRadius: style.cornerRadius,
            yRadius: style.cornerRadius
        ).setClip()
        style.accentColor.setFill()
        NSBezierPath(rect: NSRect(
            x: inset.minX,
            y: inset.minY,
            width: Self.highlightBarWidth,
            height: inset.height
        )).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Divider, placeholder, status

/// Marks where the restored history ends. Dimming the old messages instead would just
/// read as "not loaded yet".
@MainActor
final class DanmakuDividerRow: DanmakuRow {
    private let label = NSTextField(labelWithString: "")

    init(text: String, style: DanmakuStyle) {
        super.init(style: style)
        label.stringValue = text
        label.alignment = .center
        addSubview(label)
        applyStyle()
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 1, alpha: 0.38)
        label.shadow = style.textShadow
    }

    override func styleDidChange() {
        applyStyle()
        super.styleDidChange()
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat { 30 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 12, width: max(bounds.width - 28, 0), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(rect: NSRect(x: 14, y: 8, width: max(bounds.width - 28, 0), height: 1)).fill()
    }
}

/// Connection status. Hidden unless "show debug messages" is on in settings.
@MainActor
final class DanmakuStatusRow: DanmakuRow {
    private let label = NSTextField(labelWithString: "")

    init(text: String, style: DanmakuStyle) {
        super.init(style: style)
        label.stringValue = text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        applyStyle()
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = style.mutedColor
        label.shadow = style.textShadow
    }

    override func styleDidChange() {
        applyStyle()
        super.styleDidChange()
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat { 22 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 20, y: 3, width: max(bounds.width - 40, 0), height: 16)
    }
}

/// With no messages the window is fully transparent, which makes it impossible to find.
/// A faint placeholder marks the spot until the first message arrives.
@MainActor
final class DanmakuPlaceholderRow: DanmakuRow {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet {
            label.stringValue = text
            needsLayout = true
        }
    }

    override init(style: DanmakuStyle) {
        super.init(style: style)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = style.mutedColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.shadow = style.textShadow
        addSubview(label)
    }

    override func styleDidChange() {
        label.textColor = style.mutedColor
        label.shadow = style.textShadow
        super.styleDidChange()
    }

    private func labelHeight(forWidth width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = max(width - 40, 40)
        return label.fittingSize.height
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        labelHeight(forWidth: width) + 48
    }

    override func layout() {
        super.layout()
        let height = labelHeight(forWidth: bounds.width)
        label.frame = NSRect(
            x: 20,
            y: (bounds.height - height) / 2,
            width: max(bounds.width - 40, 0),
            height: height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 8, dy: 10)
        guard box.width > 0, box.height > 0 else { return }
        NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 14 / 255, alpha: 0.22).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        path.fill()
        NSColor(white: 1, alpha: 0.22).setStroke()
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }
}
