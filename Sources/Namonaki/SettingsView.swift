import AppKit
import Combine

@MainActor
final class SettingsViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        preferredContentSize = NSSize(width: 500, height: 500)

        addPane(ConnectionSettingsController(), title: "连接", symbol: "link")
        addPane(DanmakuSettingsController(), title: "弹幕", symbol: "textformat.size")
        addPane(WindowSettingsController(), title: "窗口", symbol: "macwindow")
        addPane(AccountSettingsController(), title: "账号", symbol: "person.crop.circle")
        addPane(StyleSettingsController(), title: "CSS", symbol: "curlybraces")
    }

    private func addPane(_ controller: NSViewController, title: String, symbol: String) {
        controller.title = "弹幕窗设置"
        controller.preferredContentSize = NSSize(width: 500, height: 440)
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }
}

// MARK: - 通用布局

@MainActor
private class ScrollingSettingsController: NSViewController {
    let content = AppKitUI.stack([], spacing: 16, alignment: .width)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 440))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let document = FlippedView()
        scroll.documentView = document
        document.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        buildContent()
    }

    func buildContent() {}

    func add(_ view: NSView, spacingAfter: CGFloat? = nil) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let spacingAfter { content.setCustomSpacing(spacingAfter, after: view) }
    }
}

@MainActor
private final class StatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private func flexibleSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}

@MainActor
private func settingHeader(_ title: String, valueLabel: NSTextField) -> NSStackView {
    let titleLabel = AppKitUI.label(title, size: 13, weight: .medium)
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    return AppKitUI.stack(
        [titleLabel, flexibleSpacer(), valueLabel],
        orientation: .horizontal,
        spacing: 8,
        alignment: .centerY
    )
}

@MainActor
private func settingDetail(_ text: String, tertiary: Bool = false) -> NSTextField {
    AppKitUI.label(
        text,
        size: tertiary ? 10 : 11,
        color: tertiary ? .tertiaryLabelColor : .secondaryLabelColor,
        wrapping: true
    )
}

// MARK: - 连接

@MainActor
private final class ConnectionSettingsController: ScrollingSettingsController, NSTextFieldDelegate {
    private let prefs = Preferences.shared
    private let runtime = OpenLiveRuntime.shared
    private let statusDot = StatusDot()
    private let statusLabel = AppKitUI.label("", size: 13, weight: .medium, wrapping: true)
    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let revealButton = NSButton()
    private let saveButton = NSButton()
    private let clearButton = NSButton()
    private let hintLabel = settingDetail("")
    private let obsButton = NSButton()
    private let debugSwitch = NSSwitch()
    private var draft = Preferences.shared.authCode
    private var revealed = false
    private var revealTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    override func buildContent() {
        let statusRow = AppKitUI.stack(
            [statusDot, statusLabel, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        add(statusRow, spacingAfter: 14)

        let authTitle = AppKitUI.label("开放平台身份码", size: 12, weight: .medium)
        configureAuthField(secureField)
        configureAuthField(plainField)
        plainField.isHidden = true

        let fieldHost = NSView()
        fieldHost.addSubview(secureField)
        fieldHost.addSubview(plainField)
        for field in [secureField, plainField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: fieldHost.topAnchor),
                field.leadingAnchor.constraint(equalTo: fieldHost.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: fieldHost.trailingAnchor),
                field.bottomAnchor.constraint(equalTo: fieldHost.bottomAnchor),
            ])
        }

        revealButton.title = "显示"
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        let fieldRow = AppKitUI.stack(
            [fieldHost, revealButton],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        fieldHost.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let paste = NSButton(title: "从剪贴板粘贴", target: self, action: #selector(pasteFromClipboard))
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        paste.keyEquivalent = "v"
        paste.keyEquivalentModifierMask = [.command, .shift]
        saveButton.title = "保存并连接"
        saveButton.bezelColor = .controlAccentColor
        saveButton.target = self
        saveButton.action = #selector(save)
        clearButton.title = "清除"
        clearButton.target = self
        clearButton.action = #selector(clear)
        let actionRow = AppKitUI.stack(
            [paste, saveButton, flexibleSpacer(), clearButton],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )

        let authStack = AppKitUI.stack(
            [authTitle, fieldRow, actionRow, hintLabel],
            spacing: 7,
            alignment: .width
        )
        hintLabel.isHidden = true
        add(authStack)
        add(AppKitUI.separator())

        let obsTitle = AppKitUI.label("OBS 浏览器源", size: 12, weight: .medium)
        let obsDetail = settingDetail("HUD 和 OBS 共用同一条 B 站连接，不再抢 session。")
        let obsCopy = AppKitUI.stack([obsTitle, obsDetail], spacing: 2)
        obsButton.title = "复制 OBS 地址"
        obsButton.target = self
        obsButton.action = #selector(copyOBSURL)
        let obsRow = AppKitUI.stack(
            [obsCopy, flexibleSpacer(), obsButton],
            orientation: .horizontal,
            spacing: 12,
            alignment: .centerY
        )
        let maskedURL = AppKitUI.label(
            "http://127.0.0.1:…/room/native?token=••••••••",
            size: 10,
            color: .secondaryLabelColor,
            monospaced: true
        )
        add(AppKitUI.stack([obsRow, maskedURL], spacing: 7, alignment: .width))
        add(AppKitUI.separator())

        let debugCopy = AppKitUI.stack([
            AppKitUI.label("在弹幕窗显示连接状态", size: 13),
            settingDetail("平时关掉更干净，排查掉线时再打开。"),
        ], spacing: 2)
        debugSwitch.target = self
        debugSwitch.action = #selector(toggleDebug)
        let debugRow = AppKitUI.stack(
            [debugCopy, flexibleSpacer(), debugSwitch],
            orientation: .horizontal,
            spacing: 12,
            alignment: .centerY
        )
        add(debugRow)

        add(settingDetail(
            "隐私：身份码会发给 api1/api2.blive.chat 换取 B 站会话；不会进 OBS 地址或 App 日志。账号 Cookie 和弹幕内容不会发给该服务。",
            tertiary: true
        ))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        secureField.stringValue = draft
        plainField.stringValue = draft

        Publishers.CombineLatest(runtime.$connectionState, runtime.$relayState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatus() }
            .store(in: &cancellables)
        prefs.$authCode
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self else { return }
                if self.draft == Preferences.shared.authCode || self.draft.isEmpty {
                    self.draft = code
                    self.secureField.stringValue = code
                    self.plainField.stringValue = code
                }
                self.updateControls()
            }
            .store(in: &cancellables)
        prefs.$showDebugMessages
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.debugSwitch.state = .init(value) }
            .store(in: &cancellables)

        updateStatus()
        updateControls()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        setRevealed(false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        draft = field.stringValue
        if field === secureField { plainField.stringValue = draft }
        if field === plainField { secureField.stringValue = draft }
        setHint(nil)
        updateControls()
    }

    private func configureAuthField(_ field: NSTextField) {
        field.placeholderString = "12–14 位大写字母或数字"
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
    }

    private func updateStatus() {
        if case .failed = runtime.relayState {
            statusDot.color = .systemRed
            statusLabel.stringValue = "本机转发启动失败（端口 12451 可能被占用）"
            return
        }
        statusLabel.stringValue = runtime.connectionState.label
        switch runtime.connectionState {
        case .connected:
            statusDot.color = .systemGreen
        case .failed:
            statusDot.color = .systemRed
        case .idle:
            statusDot.color = .tertiaryLabelColor
        case .connecting, .authenticating, .reconnecting:
            statusDot.color = .systemOrange
        }
    }

    private func updateControls() {
        revealButton.isEnabled = !draft.isEmpty
        saveButton.isEnabled = normalizedDraft != prefs.authCode
        clearButton.isEnabled = !prefs.authCode.isEmpty || !draft.isEmpty
        obsButton.isEnabled = runtime.obsURL != nil
    }

    private func setHint(_ message: String?) {
        hintLabel.isHidden = message == nil
        hintLabel.stringValue = message ?? ""
        hintLabel.textColor = message?.hasPrefix("✓") == true ? .systemGreen : .systemOrange
    }

    private func setRevealed(_ value: Bool) {
        revealed = value
        plainField.isHidden = !value
        secureField.isHidden = value
        revealButton.title = value ? "隐藏" : "显示"
        revealTask?.cancel()
        if value {
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.setRevealed(false)
            }
        }
    }

    @objc private func toggleReveal() {
        setRevealed(!revealed)
        view.window?.makeFirstResponder(revealed ? plainField : secureField)
    }

    @objc private func pasteFromClipboard() {
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setHint("剪贴板是空的")
            return
        }
        let candidates = [text.uppercased()] + text
            .uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard let code = candidates.first(where: OpenLiveRuntime.isValidAuthCode) else {
            setHint("没找到 12–14 位身份码")
            return
        }
        draft = code
        secureField.stringValue = code
        plainField.stringValue = code
        setRevealed(false)
        setHint("✓ 已识别，点「保存并连接」")
        updateControls()
    }

    @objc private func save() {
        guard OpenLiveRuntime.isValidAuthCode(normalizedDraft) else {
            setHint("身份码应为 12–14 位大写字母或数字")
            return
        }
        draft = normalizedDraft
        secureField.stringValue = draft
        plainField.stringValue = draft
        prefs.authCode = draft
        setRevealed(false)
        setHint("✓ 已保存，正在连接")
        updateControls()
    }

    @objc private func clear() {
        draft = ""
        secureField.stringValue = ""
        plainField.stringValue = ""
        prefs.authCode = ""
        setRevealed(false)
        setHint(nil)
        updateControls()
    }

    @objc private func copyOBSURL() {
        guard let url = runtime.obsURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        obsButton.title = "已复制"
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.obsButton.title = "复制 OBS 地址"
        }
    }

    @objc private func toggleDebug() {
        prefs.showDebugMessages = debugSwitch.state == .on
    }
}

// MARK: - 弹幕

@MainActor
private final class DanmakuSettingsController: ScrollingSettingsController {
    private let prefs = Preferences.shared
    private let presetControl = NSSegmentedControl()
    private let summaryLabel = settingDetail("")
    private let backdropSlider = NSSlider()
    private let backdropValue = AppKitUI.label("", size: 12, color: .secondaryLabelColor, monospaced: true)
    private let fontSlider = NSSlider()
    private let fontValue = AppKitUI.label("", size: 12, color: .secondaryLabelColor, monospaced: true)
    private let nameSlider = NSSlider()
    private let nameValue = AppKitUI.label("", size: 12, color: .secondaryLabelColor, monospaced: true)
    private let resetButton = NSButton()
    private var cancellables = Set<AnyCancellable>()

    override func buildContent() {
        let styleTitle = AppKitUI.label("风格", size: 13, weight: .medium)
        presetControl.segmentCount = StylePreset.allCases.count
        for (index, preset) in StylePreset.allCases.enumerated() {
            presetControl.setLabel(preset.title, forSegment: index)
        }
        presetControl.segmentStyle = .rounded
        presetControl.target = self
        presetControl.action = #selector(changePreset)
        add(AppKitUI.stack([styleTitle, presetControl, summaryLabel], spacing: 7, alignment: .width))
        add(AppKitUI.separator())

        configureSlider(backdropSlider, min: 0, max: 0.85, action: #selector(changeBackdrop))
        let backdrop = AppKitUI.stack([
            settingHeader("衬底浓度", valueLabel: backdropValue),
            backdropSlider,
            settingDetail("弹幕背后垫的深色块。浅色桌面上调高才看得清；叠在深色画面上拖到 0 就全透明。"),
        ], spacing: 7, alignment: .width)
        add(backdrop)

        configureSlider(fontSlider, min: 14, max: 34, action: #selector(changeFont))
        fontSlider.numberOfTickMarks = 21
        fontSlider.allowsTickMarkValuesOnly = true
        add(AppKitUI.stack([
            settingHeader("弹幕字号", valueLabel: fontValue),
            fontSlider,
        ], spacing: 7, alignment: .width))

        configureSlider(nameSlider, min: 0.3, max: 1, action: #selector(changeNameOpacity))
        add(AppKitUI.stack([
            settingHeader("用户名清晰度", valueLabel: nameValue),
            nameSlider,
            settingDetail("调低会让用户名往后退，正文更突出；调到 100% 就和正文一样清楚。"),
        ], spacing: 7, alignment: .width))

        resetButton.target = self
        resetButton.action = #selector(resetPreset)
        resetButton.controlSize = .small
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let resetRow = AppKitUI.stack(
            [resetButton, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 0,
            alignment: .centerY
        )
        add(resetRow)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }

    private func refresh() {
        let all = StylePreset.allCases
        presetControl.selectedSegment = all.firstIndex(of: prefs.preset) ?? 0
        summaryLabel.stringValue = prefs.preset.summary
        backdropSlider.doubleValue = prefs.backdropAlpha
        backdropValue.stringValue = prefs.backdropAlpha < 0.02
            ? "无" : "\(Int(prefs.backdropAlpha * 100))%"
        fontSlider.doubleValue = prefs.fontSize
        fontValue.stringValue = "\(Int(prefs.fontSize))px"
        nameSlider.doubleValue = prefs.nameOpacity
        nameValue.stringValue = "\(Int(prefs.nameOpacity * 100))%"
        resetButton.title = "回到「\(prefs.preset.title)」的默认值"
    }

    @objc private func changePreset() {
        let index = presetControl.selectedSegment
        guard StylePreset.allCases.indices.contains(index) else { return }
        prefs.apply(StylePreset.allCases[index])
        refresh()
    }

    @objc private func changeBackdrop() {
        prefs.backdropAlpha = backdropSlider.doubleValue
        refresh()
    }

    @objc private func changeFont() {
        prefs.fontSize = fontSlider.doubleValue.rounded()
        refresh()
    }

    @objc private func changeNameOpacity() {
        prefs.nameOpacity = nameSlider.doubleValue
        refresh()
    }

    @objc private func resetPreset() {
        prefs.apply(prefs.preset)
        refresh()
    }
}

// MARK: - 窗口

@MainActor
private final class WindowSettingsController: ScrollingSettingsController, NSTextFieldDelegate {
    private let prefs = Preferences.shared
    private let opacitySlider = NSSlider()
    private let opacityValue = AppKitUI.label("", size: 12, color: .secondaryLabelColor, monospaced: true)
    private let topSwitch = NSSwitch()
    private let outlineSwitch = NSSwitch()
    private let xField = NSTextField()
    private let yField = NSTextField()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let recallButton = NSButton()
    private var cancellables = Set<AnyCancellable>()

    private var hud: HUDWindow? { (NSApp.delegate as? AppDelegate)?.hud }

    override func buildContent() {
        opacitySlider.minValue = 0.25
        opacitySlider.maxValue = 1
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(changeOpacity)
        add(AppKitUI.stack([
            settingHeader("不透明度", valueLabel: opacityValue),
            opacitySlider,
        ], spacing: 7, alignment: .width))
        add(AppKitUI.separator())

        let topCopy = AppKitUI.stack([
            AppKitUI.label("始终置顶", size: 13),
            settingDetail("开：永远盖在最上面。关：点哪个窗口，哪个窗口就压到弹幕上面"),
        ], spacing: 2)
        let topRow = AppKitUI.stack(
            [topCopy, flexibleSpacer(), topSwitch],
            orientation: .horizontal,
            spacing: 12,
            alignment: .centerY
        )
        topSwitch.target = self
        topSwitch.action = #selector(toggleAlwaysOnTop)
        add(topRow)

        let outlineCopy = AppKitUI.stack([
            AppKitUI.label("显示窗口轮廓", size: 13),
            settingDetail("画一圈淡边框标出窗口范围。没弹幕时窗口是全透明的，容易找不着"),
        ], spacing: 2)
        outlineSwitch.target = self
        outlineSwitch.action = #selector(toggleOutline)
        add(AppKitUI.stack(
            [outlineCopy, flexibleSpacer(), outlineSwitch],
            orientation: .horizontal,
            spacing: 12,
            alignment: .centerY
        ))
        add(AppKitUI.separator())

        add(buildPositionEditor())
        add(AppKitUI.separator())
        add(AppKitUI.stack([
            AppKitUI.label("怎么调整位置和大小", size: 12, weight: .medium),
            settingDetail("平时弹幕窗对鼠标完全隐形，透明区域也不会挡住后面的东西。要挪位置或改大小，用菜单栏图标里的「调整位置和大小」（⌘E）——窗口会显示边框，这时可以随便拖边缘缩放，调完再按一次关掉。"),
        ], spacing: 6, alignment: .width))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
        loadFrame()
    }

    private func buildPositionEditor() -> NSView {
        let fields = [
            positionField("X", field: xField),
            positionField("Y", field: yField),
            positionField("宽", field: widthField),
            positionField("高", field: heightField),
        ]
        let apply = NSButton(title: "应用", target: self, action: #selector(applyFrame))
        apply.controlSize = .small
        let fieldRow = AppKitUI.stack(
            fields + [apply, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 6,
            alignment: .bottom
        )

        let remember = NSButton(title: "记住当前位置", target: self, action: #selector(rememberFrame))
        remember.controlSize = .small
        recallButton.title = "回到记住的位置"
        recallButton.controlSize = .small
        recallButton.target = self
        recallButton.action = #selector(recallFrame)
        let read = NSButton(title: "读取当前", target: self, action: #selector(loadFrame))
        read.controlSize = .small
        let actions = AppKitUI.stack(
            [remember, recallButton, flexibleSpacer(), read],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )

        return AppKitUI.stack([
            AppKitUI.label("位置和大小", size: 13, weight: .medium),
            fieldRow,
            actions,
            settingDetail("坐标原点在屏幕左下角。想固定在某个位置，摆好后点「记住当前位置」，以后一键回来。"),
        ], spacing: 8, alignment: .width)
    }

    private func positionField(_ title: String, field: NSTextField) -> NSView {
        let label = AppKitUI.label(title, size: 9, color: .secondaryLabelColor)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return AppKitUI.stack([label, field], spacing: 2)
    }

    private func refresh() {
        opacitySlider.doubleValue = prefs.opacity
        opacityValue.stringValue = "\(Int(prefs.opacity * 100))%"
        topSwitch.state = .init(prefs.alwaysOnTop)
        outlineSwitch.state = .init(prefs.showOutline)
        recallButton.isEnabled = !prefs.bookmarkFrame.isEmpty
    }

    @objc private func changeOpacity() {
        prefs.opacity = opacitySlider.doubleValue
        refresh()
    }

    @objc private func toggleAlwaysOnTop() {
        prefs.alwaysOnTop = topSwitch.state == .on
    }

    @objc private func toggleOutline() {
        prefs.showOutline = outlineSwitch.state == .on
    }

    @objc private func loadFrame() {
        guard let frame = hud?.frame else { return }
        xField.stringValue = String(Int(frame.minX))
        yField.stringValue = String(Int(frame.minY))
        widthField.stringValue = String(Int(frame.width))
        heightField.stringValue = String(Int(frame.height))
    }

    @objc private func applyFrame() {
        guard let hud,
              let x = Double(xField.stringValue),
              let y = Double(yField.stringValue),
              let width = Double(widthField.stringValue),
              let height = Double(heightField.stringValue) else { return }
        hud.applyFrame(x: x, y: y, width: width, height: height)
        loadFrame()
    }

    @objc private func rememberFrame() {
        hud?.rememberSpot()
        loadFrame()
        refresh()
    }

    @objc private func recallFrame() {
        hud?.recallSpot()
        loadFrame()
    }
}

// MARK: - 账号（发弹幕用）

@MainActor
private final class AccountSettingsController: ScrollingSettingsController, NSTextFieldDelegate {
    private let account = BilibiliAccount.shared
    private let statusDot = StatusDot()
    private let statusLabel = AppKitUI.label("", size: 13, weight: .medium)
    private let loginButton = NSButton()
    private let signOutButton = NSButton()
    private let roomField = NSTextField()
    private let errorLabel = settingDetail("")
    private let packList = AppKitUI.stack([], spacing: 3, alignment: .width)
    private let packEmptyLabel = settingDetail("登录后点刷新，会列出你拥有的表情包。")
    private let packHelp = settingDetail("标「只出文字」的是评论区表情包，发到直播弹幕只会显示成 [xxx]，B 站不给渲染成图。")
    private var cancellables = Set<AnyCancellable>()

    override func buildContent() {
        let status = AppKitUI.stack(
            [statusDot, statusLabel, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        loginButton.target = self
        loginButton.action = #selector(login)
        signOutButton.title = "退出登录"
        signOutButton.target = self
        signOutButton.action = #selector(signOut)
        let loginActions = AppKitUI.stack(
            [loginButton, signOutButton, flexibleSpacer()],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        add(AppKitUI.stack([status, loginActions], spacing: 12, alignment: .width))
        add(AppKitUI.separator())

        roomField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        roomField.delegate = self
        add(AppKitUI.stack([
            AppKitUI.label("发送到哪个直播间", size: 13, weight: .medium),
            roomField,
            settingDetail("登录后会自动认出你自己的直播间。想发到别人的直播间就在这里填房间号。"),
            errorLabel,
        ], spacing: 7, alignment: .width))
        errorLabel.textColor = .systemOrange
        add(AppKitUI.separator())

        let packTitle = AppKitUI.label("表情系列", size: 13, weight: .medium)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshPacks))
        refresh.controlSize = .small
        let packHeader = AppKitUI.stack(
            [packTitle, flexibleSpacer(), refresh],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        let packScroll = NSScrollView()
        packScroll.drawsBackground = false
        packScroll.hasVerticalScroller = true
        packScroll.autohidesScrollers = true
        packScroll.borderType = .bezelBorder
        let packDocument = FlippedView()
        packDocument.addSubview(packList)
        packList.translatesAutoresizingMaskIntoConstraints = false
        packScroll.documentView = packDocument
        packDocument.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            packDocument.topAnchor.constraint(equalTo: packScroll.contentView.topAnchor),
            packDocument.leadingAnchor.constraint(equalTo: packScroll.contentView.leadingAnchor),
            packDocument.trailingAnchor.constraint(equalTo: packScroll.contentView.trailingAnchor),
            packDocument.widthAnchor.constraint(equalTo: packScroll.contentView.widthAnchor),
            packList.topAnchor.constraint(equalTo: packDocument.topAnchor, constant: 5),
            packList.leadingAnchor.constraint(equalTo: packDocument.leadingAnchor, constant: 7),
            packList.trailingAnchor.constraint(equalTo: packDocument.trailingAnchor, constant: -7),
            packList.bottomAnchor.constraint(equalTo: packDocument.bottomAnchor, constant: -5),
            packScroll.heightAnchor.constraint(equalToConstant: 110),
        ])
        add(AppKitUI.stack(
            [packHeader, packEmptyLabel, packScroll, packHelp],
            spacing: 7,
            alignment: .width
        ))
        packScroll.identifier = NSUserInterfaceItemIdentifier("packScroll")

        add(settingDetail(
            "登录凭证存在本机钥匙串里，不上传任何地方。发送走 B 站官方接口，本地限速每秒最多一条，避免撞风控。收弹幕仍然走 blivechat 的只读接口，和这套登录无关。",
            tertiary: true
        ))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        account.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === roomField else { return }
        account.manualRoomID = roomField.stringValue
    }

    private func refresh() {
        statusDot.color = account.isLoggedIn ? .systemGreen : .tertiaryLabelColor
        statusLabel.stringValue = account.isLoggedIn
            ? account.userName.map { "已登录：\($0)" } ?? "已登录"
            : "未登录"
        loginButton.title = account.isLoggedIn ? "重新登录" : "登录 B 站账号"
        signOutButton.isHidden = !account.isLoggedIn
        if view.window?.firstResponder !== roomField.currentEditor(),
           roomField.stringValue != account.manualRoomID {
            roomField.stringValue = account.manualRoomID
        }
        roomField.placeholderString = account.roomID.map {
            "留空就用你自己的直播间 \($0)"
        } ?? "填直播间号"
        errorLabel.stringValue = account.lastError ?? ""
        errorLabel.isHidden = account.lastError == nil
        rebuildPacks()
    }

    private func rebuildPacks() {
        packList.arrangedSubviews.forEach {
            packList.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for pack in account.packs {
            let checkbox = NSButton(checkboxWithTitle: pack.name, target: self, action: #selector(togglePack(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(pack.id)
            checkbox.state = .init(!account.hiddenPackIDs.contains(pack.id))
            checkbox.font = .systemFont(ofSize: 12)
            let count = AppKitUI.label(
                "\(pack.items.count)",
                size: 10,
                color: .secondaryLabelColor,
                monospaced: true
            )
            var views: [NSView] = [checkbox, count]
            if !pack.liveRenderable {
                views.append(AppKitUI.label("只出文字", size: 9, color: .systemOrange))
            }
            views.append(flexibleSpacer())
            let row = AppKitUI.stack(
                views,
                orientation: .horizontal,
                spacing: 6,
                alignment: .centerY
            )
            packList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: packList.widthAnchor).isActive = true
        }

        let packScroll = content.subviewsRecursive.first {
            $0.identifier?.rawValue == "packScroll"
        }
        let empty = account.packs.isEmpty
        packEmptyLabel.isHidden = !empty
        packScroll?.isHidden = empty
        packHelp.isHidden = empty
    }

    @objc private func login() {
        (NSApp.delegate as? AppDelegate)?.showLogin()
    }

    @objc private func signOut() {
        account.signOut()
        refresh()
    }

    @objc private func refreshPacks() {
        Task { await account.refreshEmoticons() }
    }

    @objc private func togglePack(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            account.hiddenPackIDs.remove(id)
        } else {
            account.hiddenPackIDs.insert(id)
        }
    }
}

// MARK: - CSS

@MainActor
private final class StyleSettingsController: NSViewController, NSTextViewDelegate {
    private let prefs = Preferences.shared
    private let textView = NSTextView()
    private let copyButton = NSButton()
    private var cancellables = Set<AnyCancellable>()
    private var copyTask: Task<Void, Never>?
    private var isApplyingCSS = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 440))

        let title = AppKitUI.label("OBS 浏览器源 CSS", size: 13, weight: .medium)
        copyButton.title = "复制 OBS CSS"
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyCSS)
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetCSS))
        reset.controlSize = .small
        let header = AppKitUI.stack(
            [title, flexibleSpacer(), copyButton, reset],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView

        let help = settingDetail(
            "这份 CSS 只管 OBS 里那一份。桌面弹幕窗是原生绘制的，样式在「外观」里调。"
                + "点「复制 OBS CSS」会连滑杆的取值一起复制，粘进浏览器源的「自定义 CSS」两边就一致。"
        )
        let content = AppKitUI.stack([header, scroll, help], spacing: 10, alignment: .width)
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        prefs.$customCSS
            .receive(on: RunLoop.main)
            .sink { [weak self] css in
                guard let self, self.textView.string != css else { return }
                self.isApplyingCSS = true
                self.textView.string = css
                self.isApplyingCSS = false
            }
            .store(in: &cancellables)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingCSS else { return }
        prefs.customCSS = textView.string
    }

    @objc private func copyCSS() {
        NSPasteboard.general.clearContents()
        // The sliders live outside the stylesheet, so append them or OBS would keep the
        // built-in defaults while the HUD follows the sliders.
        NSPasteboard.general.setString(
            prefs.customCSS + "\n\n/* 设置面板 */\n" + prefs.variableCSS,
            forType: .string
        )
        copyButton.title = "已复制"
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copyButton.title = "复制 OBS CSS"
        }
    }

    @objc private func resetCSS() {
        prefs.resetCSS()
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}
