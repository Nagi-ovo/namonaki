import AppKit
import Combine

/// AppKit 图片加载器。内存缓存避免表情 popover 每次打开都重新请求。
@MainActor
private enum EmoticonImageLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for rawURL: String) async -> NSImage? {
        if let cached = cache.object(forKey: rawURL as NSString) {
            return cached
        }
        guard let url = URL(string: rawURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: rawURL as NSString)
        return image
    }
}

@MainActor
private final class EmoticonButton: NSButton {
    private let lockView = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var item: BilibiliAccount.Emoticon?
    var onPick: ((BilibiliAccount.Emoticon) -> Void)?
    var onHover: ((BilibiliAccount.Emoticon?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pick)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 7

        lockView.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: "未解锁"
        )
        lockView.contentTintColor = .secondaryLabelColor
        lockView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockView)
        NSLayoutConstraint.activate([
            lockView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            lockView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            lockView.widthAnchor.constraint(equalToConstant: 11),
            lockView.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    func configure(with item: BilibiliAccount.Emoticon) {
        self.item = item
        toolTip = item.locked ? "\(item.descript)（未解锁）" : item.descript
        isEnabled = !item.locked
        alphaValue = item.locked ? 0.3 : 1
        lockView.isHidden = !item.locked
        image = NSImage(
            systemSymbolName: "face.smiling",
            accessibilityDescription: item.descript
        )

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let loaded = await EmoticonImageLoader.image(for: item.url),
                  !Task.isCancelled,
                  self?.item?.id == item.id else { return }
            self?.image = loaded
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        if let item { onHover?(item) }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        onHover?(nil)
    }

    @objc private func pick() {
        guard let item, !item.locked else { return }
        onPick?(item)
    }
}

/// 直播间表情面板。表情按直播间发放，换房间后列表也会变。
@MainActor
final class EmoticonPickerViewController: NSViewController {
    private let account = BilibiliAccount.shared
    private let onPick: (BilibiliAccount.Emoticon) -> Void
    private var cancellables = Set<AnyCancellable>()
    private var footerLabel: NSTextField?

    private var selectedPackID: String {
        get { UserDefaults.standard.string(forKey: "lastEmotePackID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastEmotePackID") }
    }

    private var currentPack: BilibiliAccount.EmotePack? {
        account.visiblePacks.first { $0.id == selectedPackID } ?? account.visiblePacks.first
    }

    init(onPick: @escaping (BilibiliAccount.Emoticon) -> Void) {
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 430))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        account.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reload() }
            }
            .store(in: &cancellables)
        reload()
    }

    private func reload() {
        view.subviews.forEach { $0.removeFromSuperview() }
        footerLabel = nil

        if account.visiblePacks.isEmpty {
            installLegacyBody()
        } else {
            installPackBody()
        }
    }

    private func installPackBody() {
        preferredContentSize = NSSize(width: 420, height: 430)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for pack in account.visiblePacks {
            let title = pack.liveRenderable ? pack.name : "\(pack.name)（只出文字）"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = pack.id
        }
        let selected = currentPack ?? account.visiblePacks[0]
        selectedPackID = selected.id
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected.id }) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = #selector(selectPack(_:))
        popup.controlSize = .small

        let badge = AppKitUI.label(
            "直播不出图",
            size: 9,
            weight: .medium,
            color: .systemOrange
        )
        badge.isHidden = selected.liveRenderable
        let header = AppKitUI.stack(
            [popup, badge, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        let headerHost = insetHost(header, top: 7, left: 12, bottom: 7, right: 12)

        let scroll = gridScrollView(items: selected.items, columns: 5)
        let footer = AppKitUI.label(
            "\(selected.name) · \(selected.items.count) 个",
            size: 10,
            color: .secondaryLabelColor
        )
        footerLabel = footer
        let footerHost = insetHost(footer, top: 6, left: 12, bottom: 6, right: 12)

        let outer = AppKitUI.stack(
            [headerHost, AppKitUI.separator(), scroll, AppKitUI.separator(), footerHost],
            spacing: 0,
            alignment: .width
        )
        installEdges(outer)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func installLegacyBody() {
        if account.emoticons.isEmpty {
            preferredContentSize = NSSize(width: 300, height: 150)
            let title = AppKitUI.label("没有可用表情", size: 12, weight: .medium)
            let detail = AppKitUI.label(
                "表情按直播间发放，可能是还没加载完，或者这个直播间没开表情。",
                size: 11,
                color: .secondaryLabelColor,
                wrapping: true
            )
            detail.alignment = .center
            let reload = NSButton(title: "重新加载", target: self, action: #selector(refresh))
            reload.controlSize = .small
            let body = AppKitUI.stack(
                [title, detail, reload],
                spacing: 7,
                alignment: .centerX
            )
            installCentered(body, horizontalInset: 20)
        } else {
            preferredContentSize = NSSize(width: 320, height: 260)
            installEdges(gridScrollView(items: account.emoticons, columns: 4))
        }
    }

    private func gridScrollView(
        items: [BilibiliAccount.Emoticon],
        columns: Int
    ) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let document = FlippedView()
        let grid = AppKitUI.stack([], spacing: 6, alignment: .leading)
        var rowViews: [NSView] = []

        for item in items {
            let button = EmoticonButton(frame: .zero)
            button.configure(with: item)
            button.onPick = { [weak self] in self?.onPick($0) }
            button.onHover = { [weak self] hovered in self?.updateFooter(hovered) }
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 72),
                button.heightAnchor.constraint(equalToConstant: 72),
            ])
            rowViews.append(button)

            if rowViews.count == columns {
                grid.addArrangedSubview(gridRow(rowViews))
                rowViews = []
            }
        }
        if !rowViews.isEmpty {
            grid.addArrangedSubview(gridRow(rowViews))
        }

        document.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -10),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
        ])
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func gridRow(_ views: [NSView]) -> NSStackView {
        let row = AppKitUI.stack(
            views + [flexibleSpacer()],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        return row
    }

    private func updateFooter(_ hovered: BilibiliAccount.Emoticon?) {
        if let hovered {
            footerLabel?.stringValue = hovered.descript
        } else if let pack = currentPack {
            footerLabel?.stringValue = "\(pack.name) · \(pack.items.count) 个"
        }
    }

    @objc private func selectPack(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        selectedPackID = id
        reload()
    }

    @objc private func refresh() {
        Task { await account.refreshEmoticons() }
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func insetHost(
        _ content: NSView,
        top: CGFloat,
        left: CGFloat,
        bottom: CGFloat,
        right: CGFloat
    ) -> NSView {
        let host = NSView()
        host.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: top),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: left),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -right),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottom),
        ])
        return host
    }

    private func installEdges(_ content: NSView) {
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installCentered(_ content: NSView, horizontalInset: CGFloat) {
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -horizontalInset),
        ])
    }
}
