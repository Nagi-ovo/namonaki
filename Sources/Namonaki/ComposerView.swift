import AppKit
import Combine

/// 发弹幕的小输入窗。HUD 平时对鼠标隐形，输入和表情选择单独放在这个 AppKit 控制器里。
@MainActor
final class ComposerViewController: NSViewController, NSTextFieldDelegate {
    private enum Status: Equatable {
        case idle
        case sending
        case sent(String)
        case failed(String)
    }

    private let account = BilibiliAccount.shared
    private let model = ComposerModel.shared
    private let input = NSTextField()
    private let faceButton = NSButton()
    private let sendButton = NSButton()
    private let progress = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let statusLabel = AppKitUI.label(
        "",
        size: 11,
        color: .secondaryLabelColor,
        wrapping: true
    )
    private let countLabel = AppKitUI.label(
        "",
        size: 10,
        color: .tertiaryLabelColor,
        monospaced: true
    )

    private var status: Status = .idle
    private var cancellables = Set<AnyCancellable>()
    private var resetTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var isUpdatingInput = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 104))
        preferredContentSize = view.frame.size

        input.placeholderString = "说点什么…"
        input.font = .systemFont(ofSize: 15)
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(submit)

        let inputBackground = NSView()
        inputBackground.wantsLayer = true
        inputBackground.layer?.cornerRadius = 8
        inputBackground.layer?.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.10).cgColor
        inputBackground.addSubview(input)
        input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: inputBackground.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: inputBackground.trailingAnchor, constant: -12),
            input.centerYAnchor.constraint(equalTo: inputBackground.centerYAnchor),
            inputBackground.heightAnchor.constraint(equalToConstant: 36),
        ])

        faceButton.image = NSImage(
            systemSymbolName: "face.smiling",
            accessibilityDescription: "选择表情"
        )
        faceButton.toolTip = "选择表情"
        faceButton.bezelStyle = .rounded
        faceButton.target = self
        faceButton.action = #selector(showEmoticons)

        sendButton.image = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "发送"
        )
        sendButton.toolTip = "发送"
        sendButton.bezelStyle = .rounded
        sendButton.bezelColor = .controlAccentColor
        sendButton.contentTintColor = .white
        sendButton.target = self
        sendButton.action = #selector(submit)

        for button in [faceButton, sendButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 34),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])

        let inputRow = AppKitUI.stack(
            [inputBackground, faceButton, sendButton],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        inputBackground.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 13),
            statusIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = AppKitUI.stack(
            [statusIcon, statusLabel, statusSpacer, countLabel],
            orientation: .horizontal,
            spacing: 6,
            alignment: .centerY
        )

        let content = AppKitUI.stack(
            [inputRow, statusRow],
            spacing: 8,
            alignment: .width
        )
        AppKitUI.installTopStack(
            content,
            in: view,
            insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        model.$text
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if self.input.stringValue != text {
                    self.isUpdatingInput = true
                    self.input.stringValue = text
                    self.isUpdatingInput = false
                }
                if case .failed = self.status { self.status = .idle }
                self.updateUI()
            }
            .store(in: &cancellables)

        model.$focusToken
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.focusInput() }
            .store(in: &cancellables)

        account.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateUI() }
            }
            .store(in: &cancellables)

        updateUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInput()
        Task { await account.refreshEmoticons() }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingInput else { return }
        model.text = input.stringValue
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.deleteBackward(_:)),
              let range = textView.string.range(
                of: #"@[^\s@]+\s?$"#,
                options: .regularExpression
              ) else { return false }

        var value = textView.string
        value.removeSubrange(range)
        textView.string = value
        input.stringValue = value
        model.text = value
        return true
    }

    private var displayLimit: Int {
        account.detectedDanmakuLimit ?? DanmakuLengthPolicy.advertisedLimit
    }

    private var hint: String {
        if let limit = account.detectedDanmakuLimit {
            if model.text.count > limit { return "发送时会自动截到实测上限 \(limit) 字" }
            return "B 站实测上限 \(limit) 字"
        }
        if model.text.count > DanmakuLengthPolicy.advertisedLimit {
            return "会先尝试原文；B 站拒绝后按 60 / 50 / 40 / 30 / 20 字回退"
        }
        guard account.isLoggedIn else { return "还没登录，去设置里登录 B 站账号" }
        guard let room = account.effectiveRoomID else { return "还没设置直播间号" }
        let who = account.userName.map { "以 \($0) 的身份" } ?? ""
        return "\(who)发到直播间 \(room)"
    }

    private func focusInput() {
        guard isViewLoaded else { return }
        view.window?.makeFirstResponder(input)
    }

    private func updateUI() {
        guard isViewLoaded else { return }
        let trimmed = model.text.trimmingCharacters(in: .whitespaces)
        let isSending = status == .sending
        faceButton.isEnabled = account.isLoggedIn && !isSending
        sendButton.isEnabled = !trimmed.isEmpty && !isSending
        sendButton.image?.isTemplate = true
        sendButton.imagePosition = isSending ? .noImage : .imageOnly
        isSending ? progress.startAnimation(nil) : progress.stopAnimation(nil)

        countLabel.stringValue = "\(model.text.count)/\(displayLimit)"
        let overLimit = model.text.count > displayLimit
        countLabel.textColor = overLimit ? .systemOrange : .tertiaryLabelColor
        countLabel.font = NSFont.monospacedSystemFont(
            ofSize: 10,
            weight: overLimit ? .semibold : .regular
        )

        switch status {
        case .idle:
            setStatusPresentation(text: hint, symbol: nil, color: .secondaryLabelColor)
        case .sending:
            setStatusPresentation(text: "发送中…", symbol: nil, color: .secondaryLabelColor)
        case .sent(let message):
            setStatusPresentation(
                text: message,
                symbol: "checkmark.circle.fill",
                color: .systemGreen
            )
        case .failed(let message):
            setStatusPresentation(
                text: message,
                symbol: "exclamationmark.triangle.fill",
                color: .systemOrange
            )
        }
    }

    private func setStatusPresentation(text: String, symbol: String?, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusIcon.isHidden = symbol == nil
        statusIcon.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: text)
        }
        statusIcon.contentTintColor = color
    }

    private func setStatus(_ status: Status, resetAfter delay: Duration? = nil) {
        resetTask?.cancel()
        self.status = status
        updateUI()
        guard let delay else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if case .sent = self.status {
                self.status = .idle
                self.updateUI()
            }
        }
    }

    @objc private func showEmoticons() {
        if let popover, popover.isShown {
            popover.close()
            return
        }

        let picker = EmoticonPickerViewController { [weak self] emoticon in
            self?.popover?.close()
            self?.sendEmoticon(emoticon)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        self.popover = popover
        popover.show(relativeTo: faceButton.bounds, of: faceButton, preferredEdge: .maxY)
    }

    private func sendEmoticon(_ emoticon: BilibiliAccount.Emoticon) {
        setStatus(.sending)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await account.send(emoticon: emoticon)
                setStatus(.sent("已发送"), resetAfter: .seconds(1.5))
            } catch {
                setStatus(.failed(error.localizedDescription))
            }
        }
    }

    @objc private func submit() {
        let content = model.text
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty,
              status != .sending else { return }
        setStatus(.sending)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await account.sendText(content)
                model.text = ""
                if result.wasTruncated {
                    let limit = result.detectedLimit ?? result.sentLength
                    setStatus(
                        .sent("已按 \(limit) 字上限发送，截去 \(result.truncatedCount) 字"),
                        resetAfter: .seconds(1.5)
                    )
                } else {
                    setStatus(.sent("已发送"), resetAfter: .seconds(1.5))
                }
            } catch {
                setStatus(.failed(error.localizedDescription))
            }
        }
    }
}
