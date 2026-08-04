import AppKit
import Combine

/// The translucent danmaku window on the desktop.
/// No title bar, transparent background, invisible to the mouse except while editing.
@MainActor
final class HUDWindow: NSWindow {
    private let listView: DanmakuListView
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared
    private let runtime = OpenLiveRuntime.shared
    private weak var dragOverlay: DragOverlay?

    /// Layout editing: the window temporarily accepts clicks, can be dragged and resized,
    /// and draws a border so its bounds are visible. Off the rest of the time.
    private(set) var isEditingLayout = false

    private var hoverTimer: Timer?
    /// Author under the pointer, if any — this is who right-click replies to.
    private var hoveringAuthor: String?
    /// Whether the pointer is over a row at all. The window only stops ignoring the mouse
    /// while this is true, so scrolling back through the feed keeps working.
    private var hoveringRow = false

    func setEditingLayout(_ editing: Bool) {
        isEditingLayout = editing
        // Only accept mouse events while editing; otherwise the whole window is
        // transparent to the mouse so its empty area does not block what is behind it.
        ignoresMouseEvents = !editing
        dragOverlay?.showsGuide = editing
        dragOverlay?.isEditing = editing
        if editing {
            // Has to be the key window to receive Esc.
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Esc leaves editing mode without going back to the menu bar.
    override func cancelOperation(_ sender: Any?) {
        guard isEditingLayout else { return }
        onEditingEnded?()
    }

    /// Lets AppDelegate re-sync the menu check mark after Esc.
    var onEditingEnded: (() -> Void)?

    init() {
        listView = DanmakuListView(style: .current())

        let frame = prefs.savedFrame ?? NSRect(x: 120, y: 120, width: 380, height: 620)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        minSize = NSSize(width: 180, height: 120)
        maxSize = NSSize(width: 100_000, height: 100_000)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        // fullScreenDisallowsTiling: dragging to a screen edge should not offer macOS
        // window tiling, which only gets in the way for a HUD.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .fullScreenDisallowsTiling]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        listView.frame = container.bounds
        listView.autoresizingMask = [.width, .height]
        listView.onReply = { [weak self] author in self?.reply(to: author) }
        container.addSubview(listView)

        // A scroll view swallows mouse events, so the window could not be dragged.
        // A transparent layer on top takes over dragging and forwards the wheel back
        // down so the feed still scrolls.
        let overlay = DragOverlay(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.forwardTarget = listView.scrollTarget
        container.addSubview(overlay)
        dragOverlay = overlay
        overlay.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }

        contentView = container

        // What is saved is the window frame, but init takes a content rect — they differ
        // by the title bar height. Re-apply it here or the window creeps down on every
        // launch.
        restoreSavedFrame()

        listView.restore(HistoryStore.shared.all)
        updatePlaceholder()
        bindPreferences()
        bindRuntime()
        startHoverTracking()
    }

    private func bindPreferences() {
        prefs.$opacity
            .sink { [weak self] value in self?.alphaValue = value }
            .store(in: &cancellables)

        prefs.$alwaysOnTop
            .sink { [weak self] on in self?.level = on ? Self.overlayLevel : .normal }
            .store(in: &cancellables)

        prefs.$authCode
            .sink { [weak self] _ in self?.updatePlaceholder() }
            .store(in: &cancellables)

        prefs.$showOutline
            .sink { [weak self] on in self?.dragOverlay?.showsOutline = on }
            .store(in: &cancellables)

        // Font size, name clarity, backdrop weight and the preset all feed the same
        // style; coalesce them so dragging a slider redraws once per frame, not per event.
        Publishers.CombineLatest4(
            prefs.$fontSize, prefs.$nameOpacity, prefs.$backdropAlpha, prefs.$presetID
        )
        .dropFirst()
        .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in self?.listView.style = .current() }
        .store(in: &cancellables)
    }

    private func bindRuntime() {
        runtime.messages
            .sink { [weak self] message in self?.receive(message) }
            .store(in: &cancellables)

        runtime.$connectionState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in
                guard let self, self.prefs.showDebugMessages else { return }
                self.listView.appendStatus(state.label)
            }
            .store(in: &cancellables)
    }

    private func receive(_ message: DanmakuMessage) {
        listView.append(message)
        if message.isWorthKeeping {
            HistoryStore.shared.append(message)
        }
    }

    private func updatePlaceholder() {
        listView.emptyText = prefs.authCode.isEmpty
            ? "还没设置身份码\n菜单栏图标 → 设置"
            : "弹幕会出现在这里"
    }

    /// Menu item "重新加载": start from a clean feed with the saved history back in place.
    func reload() {
        listView.clear()
        listView.restore(HistoryStore.shared.all)
        updatePlaceholder()
    }

    // MARK: - Hover

    /// Polls the pointer instead of installing a global event monitor, so the app never
    /// has to ask for accessibility permission.
    private func startHoverTracking() {
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        guard !isEditingLayout, isVisible else { return }

        let screenPoint = NSEvent.mouseLocation
        guard frame.contains(screenPoint) else {
            dragOverlay?.mouseInside = false
            dragOverlay?.hoveringCollapseButton = false
            applyHover(row: nil)
            return
        }

        let local = NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
        dragOverlay?.mouseInside = true
        dragOverlay?.hoveringCollapseButton =
            dragOverlay?.collapseButtonRect.contains(local) ?? false

        applyHover(row: isCollapsed ? nil : listView.row(atWindowPoint: local))
        refreshMouseTransparency()
    }

    private func applyHover(row: DanmakuRow?) {
        hoveringRow = row != nil
        guard hoveringAuthor != row?.author else { return }
        hoveringAuthor = row?.author
        dragOverlay?.hoveredAuthor = hoveringAuthor
        refreshMouseTransparency()
    }

    /// The window only accepts events while the pointer is over a row or the collapse
    /// button; otherwise the whole transparent rectangle would block what is behind it.
    private func refreshMouseTransparency() {
        guard !isEditingLayout else { return }
        ignoresMouseEvents = !hoveringRow && !(dragOverlay?.hoveringCollapseButton ?? false)
    }

    private func reply(to author: String) {
        guard !author.isEmpty else { return }
        ComposerModel.shared.prepareReply(to: author)
        (NSApp.delegate as? AppDelegate)?.openComposer()
    }

    // MARK: - Collapse

    private(set) var isCollapsed = false
    private var expandedHeight: CGFloat = 0

    func toggleCollapsed() {
        if isCollapsed {
            let top = frame.maxY
            let height = expandedHeight > 0 ? expandedHeight : 500
            setFrame(
                NSRect(x: frame.minX, y: top - height, width: frame.width, height: height),
                display: true
            )
            isCollapsed = false
        } else {
            expandedHeight = frame.height
            let top = frame.maxY
            // Collapsed, only the top strip remains; align to the top edge so it reads as
            // having folded upwards.
            setFrame(
                NSRect(x: frame.minX, y: top - Self.collapsedHeight,
                       width: frame.width, height: Self.collapsedHeight),
                display: true
            )
            isCollapsed = true
        }
        listView.isHidden = isCollapsed
        dragOverlay?.isCollapsed = isCollapsed
        dragOverlay?.needsDisplay = true
    }

    static let collapsedHeight: CGFloat = 34

    // MARK: - Frame

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // Save the frame the system settled on, not the one we asked for, or the position
        // will not match after a restart.
        prefs.saveFrame(frame)
    }

    /// The system normally keeps windows inside the usable screen area (below the menu
    /// bar, inside the edges), which stops the HUD from filling the screen height.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// One level above the menu bar, otherwise the built-in display pins the window's top
    /// edge below it. External displays have no menu bar, which is why the limit is
    /// invisible there.
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1
    )

    /// Restore the saved frame, pulling the window back on screen if it ended up outside.
    private func restoreSavedFrame() {
        guard let saved = prefs.savedFrame, saved.width > 0, saved.height > 0 else { return }

        let onScreen = NSScreen.screens.contains { $0.frame.intersects(saved) }
        if onScreen {
            setFrame(saved, display: false)
        } else {
            let bounds = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let size = NSSize(width: min(saved.width, bounds.width),
                              height: min(saved.height, bounds.height))
            setFrame(
                NSRect(x: bounds.midX - size.width / 2,
                       y: bounds.midY - size.height / 2,
                       width: size.width,
                       height: size.height),
                display: false
            )
        }
    }

    func rememberSpot() {
        prefs.bookmarkFrame = NSStringFromRect(frame)
    }

    func recallSpot() {
        guard !prefs.bookmarkFrame.isEmpty else { return }
        let target = NSRectFromString(prefs.bookmarkFrame)
        guard target.width > 0, target.height > 0 else { return }
        setFrame(target, display: true)
        orderFrontRegardless()
    }

    /// Place the window by numbers, for the coordinate fields in settings.
    func applyFrame(x: Double, y: Double, width: Double, height: Double) {
        setFrame(NSRect(x: x, y: y, width: max(width, 120), height: max(height, 80)), display: true)
        orderFrontRegardless()
    }

    /// Back to the middle of the main screen at the default size — for when the window
    /// has gone missing.
    func resetPosition() {
        let bounds = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let size = NSSize(width: 380, height: min(620, bounds.height))
        setFrame(
            NSRect(x: bounds.midX - size.width / 2,
                   y: bounds.midY - size.height / 2,
                   width: size.width,
                   height: size.height),
            display: true
        )
    }

    /// Fill the height of the current screen. Uses `frame`, not `visibleFrame`, so it
    /// covers the menu bar and Dock strips too.
    func fillScreenHeight() {
        // Pick the target screen from the window's centre first; letting the system
        // re-decide mid-resize makes x jump back and forth at screen edges.
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? screen ?? NSScreen.main else { return }

        let bounds = target.frame
        let width = min(frame.width, bounds.width)
        var x = frame.minX
        if x < bounds.minX {
            x = bounds.minX
        } else if x + width > bounds.maxX {
            x = bounds.maxX - width
        }

        setFrame(
            NSRect(x: x, y: bounds.minY, width: width, height: bounds.height),
            display: true,
            animate: false
        )
    }

    override var canBecomeKey: Bool { true }
}

/// Transparent drag layer: the window moves from anywhere in it, and the scroll wheel is
/// forwarded to the feed underneath. While editing the layout it also draws a border so
/// the window's real bounds are visible.
private final class DragOverlay: NSView {
    weak var forwardTarget: NSView?

    var isEditing = false
    /// Author of the row under the pointer; this layer only takes clicks while set.
    var hoveredAuthor: String? {
        didSet { needsDisplay = true }
    }

    /// The collapse button only appears while the pointer is inside the window.
    var mouseInside = false {
        didSet { if oldValue != mouseInside { needsDisplay = true } }
    }
    var hoveringCollapseButton = false {
        didSet { if oldValue != hoveringCollapseButton { needsDisplay = true } }
    }
    var isCollapsed = false
    var onToggleCollapse: (() -> Void)?

    var collapseButtonRect: NSRect {
        NSRect(x: bounds.maxX - 32, y: bounds.maxY - 28, width: 24, height: 24)
    }

    var showsGuide = false {
        didSet { needsDisplay = true }
    }

    /// A permanent faint outline. With no messages the window is fully transparent and
    /// there is nothing to aim at.
    var showsOutline = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if collapseButtonRect.contains(local) {
            onToggleCollapse?()
            return
        }
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if (mouseInside || isCollapsed), collapseButtonRect.contains(local) {
            return self
        }
        // Otherwise only editing mode takes over: left click belongs to text selection,
        // and replying happens through the row's right-click menu.
        return isEditing ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        forwardTarget?.scrollWheel(with: event)
    }

    /// Collapse/expand button in the top-right corner. Only visible while the pointer is
    /// inside, except when collapsed — otherwise there would be no way to get it back.
    private func drawCollapseButton() {
        guard mouseInside || isCollapsed else { return }

        let rect = collapseButtonRect
        let bg = NSBezierPath(ovalIn: rect)
        NSColor.black.withAlphaComponent(hoveringCollapseButton ? 0.68 : 0.42).setFill()
        bg.fill()

        let arrow = NSBezierPath()
        let mid = NSPoint(x: rect.midX, y: rect.midY)
        let w: CGFloat = 5, h: CGFloat = 3
        if isCollapsed {
            arrow.move(to: NSPoint(x: mid.x - w, y: mid.y + h))
            arrow.line(to: NSPoint(x: mid.x, y: mid.y - h))
            arrow.line(to: NSPoint(x: mid.x + w, y: mid.y + h))
        } else {
            arrow.move(to: NSPoint(x: mid.x - w, y: mid.y - h))
            arrow.line(to: NSPoint(x: mid.x, y: mid.y + h))
            arrow.line(to: NSPoint(x: mid.x + w, y: mid.y - h))
        }
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.92).setStroke()
        arrow.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawCollapseButton() }

        guard showsGuide else {
            if showsOutline {
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                path.lineWidth = 1
                NSColor.white.withAlphaComponent(0.22).setStroke()
                path.stroke()
            }
            return
        }

        // Stroke only — a filled tint would hide the danmaku underneath.
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let border = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        border.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        border.stroke()

        // Grip in the bottom-right corner, hinting that this is where you resize.
        let grip = NSRect(x: bounds.maxX - 16, y: bounds.minY + 4, width: 12, height: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()

        drawHint()
    }

    private func drawHint() {
        let text = "拖动调整 · 按 Esc 完成"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = NSRect(
            x: bounds.midX - (size.width + 20) / 2,
            y: bounds.maxY - size.height - 16,
            width: size.width + 20,
            height: size.height + 8
        )
        NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(
            at: NSPoint(x: pill.minX + 10, y: pill.minY + 4),
            withAttributes: attrs
        )
    }
}
