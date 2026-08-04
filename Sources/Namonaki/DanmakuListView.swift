import AppKit

/// The danmaku feed, drawn natively.
///
/// Rows stack downwards from the top and the view follows the newest message unless the
/// user has scrolled up. Everything is laid out by hand against a single width, so a
/// late-arriving emote only costs one remeasure pass.
@MainActor
final class DanmakuListView: NSView {
    /// Right-click → reply to this author.
    var onReply: ((String) -> Void)?

    /// Shown in the placeholder box while the feed is empty.
    var emptyText: String = "弹幕会出现在这里" {
        didSet { placeholderRow.text = emptyText }
    }

    var style: DanmakuStyle {
        didSet {
            guard style != oldValue else { return }
            for row in rows { row.style = style }
            placeholderRow.style = style
            relayout()
        }
    }

    private let scrollView = DanmakuScrollView()
    private let documentView = FlippedView()
    private let placeholderRow: DanmakuPlaceholderRow
    private var rows: [DanmakuRow] = []
    /// Stick to the newest message until the user scrolls away from the bottom.
    private var following = true
    /// Old messages are cheap to keep but not free; this is well past a screenful.
    private let rowLimit = 200

    init(style: DanmakuStyle) {
        self.style = style
        placeholderRow = DanmakuPlaceholderRow(style: style)
        super.init(frame: .zero)

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        let clipView = ClearClipView()
        clipView.drawsBackground = false
        clipView.backgroundColor = .clear
        scrollView.contentView = clipView
        scrollView.documentView = documentView
        scrollView.onUserScroll = { [weak self] in
            guard let self else { return }
            self.following = self.isNearBottom
        }
        addSubview(scrollView)

        placeholderRow.text = emptyText
        documentView.addSubview(placeholderRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    // MARK: Feed

    func append(_ message: DanmakuMessage) {
        if case .deleteSuperChat(let ids) = message {
            remove(ids: Set(ids))
            return
        }
        if case .gift(let gift) = message, !gift.isPaid {
            // Free gifts arrive constantly and would bury the conversation. The OBS page
            // hides them too.
            return
        }

        let row = DanmakuMessageRow(message: message, style: style)
        row.onReply = { [weak self] author in self?.onReply?(author) }
        add(row, animated: true)
    }

    /// Restores the previous session's messages, followed by a divider so it is obvious
    /// where the live feed starts.
    func restore(_ messages: [DanmakuMessage]) {
        guard !messages.isEmpty else { return }
        for message in messages {
            let row = DanmakuMessageRow(message: message, style: style)
            row.onReply = { [weak self] author in self?.onReply?(author) }
            add(row, animated: false)
        }
        add(DanmakuDividerRow(text: "以上是上次的记录", style: style), animated: false)
    }

    func appendStatus(_ text: String) {
        add(DanmakuStatusRow(text: text, style: style), animated: true)
    }

    func clear() {
        for row in rows { row.removeFromSuperview() }
        rows.removeAll()
        following = true
        relayout()
    }

    private func add(_ row: DanmakuRow, animated: Bool) {
        row.onSizeChanged = { [weak self] in self?.relayout() }
        rows.append(row)
        documentView.addSubview(row)

        if rows.count > rowLimit {
            let excess = rows.count - rowLimit
            for row in rows.prefix(excess) { row.removeFromSuperview() }
            rows.removeFirst(excess)
        }

        relayout()

        guard animated else { return }
        row.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
            row.animator().alphaValue = 1
        }
    }

    private func remove(ids: Set<String>) {
        let survivors = rows.filter { row in
            guard let id = row.messageID, ids.contains(id) else { return true }
            row.removeFromSuperview()
            return false
        }
        guard survivors.count != rows.count else { return }
        rows = survivors
        relayout()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        relayout()
    }

    private func relayout() {
        let width = scrollView.contentSize.width
        guard width > 1 else { return }

        var y: CGFloat = 0
        for row in rows {
            let height = row.fittingHeight(forWidth: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }

        placeholderRow.isHidden = !rows.isEmpty
        if rows.isEmpty {
            let height = placeholderRow.fittingHeight(forWidth: width)
            placeholderRow.frame = NSRect(x: 0, y: 0, width: width, height: height)
            y = height
        }

        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(y, scrollView.contentSize.height)
        )
        if following { scrollToBottom() }
    }

    private var isNearBottom: Bool {
        let visible = scrollView.documentVisibleRect
        return visible.maxY >= documentView.frame.height - 40
    }

    private func scrollToBottom() {
        let target = max(documentView.frame.height - scrollView.contentSize.height, 0)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Hit testing

    /// The row under a point in window coordinates, or nil if the pointer is over empty
    /// space. `HUDWindow` uses this to decide when the window should stop being
    /// transparent to the mouse.
    func row(atWindowPoint point: NSPoint) -> DanmakuRow? {
        let local = documentView.convert(point, from: nil)
        guard scrollView.documentVisibleRect.contains(local) else { return nil }
        return rows.last { $0.frame.contains(local) }
    }

    /// Scroll wheel forwarding target for the drag overlay.
    var scrollTarget: NSView { scrollView }
}

/// Notifies on user-driven scrolling only. Programmatic scrolls also fire the clip view's
/// bounds notification, so watching that would make our own auto-follow look like the
/// user scrolling away.
@MainActor
final class DanmakuScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}

/// The window is transparent, so the clip view must not paint over it. Rows are
/// layer-backed, which makes every ancestor layer-backed too — an empty `draw` is not
/// enough, the layer's own background colour has to go as well.
final class ClearClipView: NSClipView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {}

    override func updateLayer() {
        layer?.backgroundColor = nil
    }
}
