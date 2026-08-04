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
    private let progress = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let statusLabel = AppKitUI.label(
        "",
        size: 11,
        color: .secondaryLabelColor,
        wrapping: true
    )
    /// Sits inside the input well. Normally it just says the return key sends; it turns
    /// into a countdown once there is little room left.
    private let trailingLabel = AppKitUI.label(
        "",
        size: 12,
        color: .tertiaryLabelColor,
        monospaced: true
    )

    private var status: Status = .idle
    private var cancellables = Set<AnyCancellable>()
    private var resetTask: Task<Void, Never>?
    private var popover: NSPopover?
    private var isUpdatingInput = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 82))
        preferredContentSize = view.frame.size

        input.placeholderString = "弹幕内容"
        input.font = .systemFont(ofSize: 15)
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(submit)

        // There is no send button: the return key sends, and a button next to the field
        // that does the same thing is the single loudest bit of chat-app costume.
        faceButton.image = NSImage(
            systemSymbolName: "face.smiling",
            accessibilityDescription: "选择表情"
        )
        faceButton.toolTip = "选择表情"
        faceButton.isBordered = false
        faceButton.bezelStyle = .accessoryBar
        faceButton.contentTintColor = .secondaryLabelColor
        faceButton.target = self
        faceButton.action = #selector(showEmoticons)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let inputRow = NSView()
        inputRow.wantsLayer = true
        inputRow.layer?.cornerRadius = 8
        inputRow.layer?.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.10).cgColor

        for subview in [input, faceButton, trailingLabel, progress] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            inputRow.addSubview(subview)
        }
        trailingLabel.alignment = .right
        NSLayoutConstraint.activate([
            inputRow.heightAnchor.constraint(equalToConstant: 36),

            input.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: 12),
            input.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: faceButton.leadingAnchor, constant: -8),

            faceButton.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            faceButton.widthAnchor.constraint(equalToConstant: 20),
            // Enough of a gap that the glyph and the countdown read as two things.
            faceButton.trailingAnchor.constraint(
                equalTo: trailingLabel.leadingAnchor, constant: -12
            ),

            trailingLabel.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            // Fixed so the field does not twitch as the number changes width.
            trailingLabel.widthAnchor.constraint(equalToConstant: 18),
            trailingLabel.trailingAnchor.constraint(
                equalTo: inputRow.trailingAnchor, constant: -12
            ),

            progress.centerXAnchor.constraint(equalTo: trailingLabel.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
        ])

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 13),
            statusIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = AppKitUI.stack(
            [statusIcon, statusLabel],
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
        // The limit itself is not worth a permanent line — the countdown in the field
        // covers it. Only say something when it changes what will happen.
        if let limit = account.detectedDanmakuLimit {
            if model.text.count > limit { return "发送时会自动截到实测上限 \(limit) 字" }
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
        let isSending = status == .sending
        faceButton.isEnabled = account.isLoggedIn && !isSending
        isSending ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        trailingLabel.isHidden = isSending

        // A running count of something you are nowhere near is noise. It only appears
        // once the remaining room is small enough to change what you type.
        let remaining = displayLimit - model.text.count
        if remaining <= 10 {
            trailingLabel.stringValue = "\(remaining)"
            trailingLabel.textColor = remaining <= 3 ? .systemRed : .secondaryLabelColor
            trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            trailingLabel.stringValue = "⏎"
            trailingLabel.textColor = .tertiaryLabelColor
            trailingLabel.font = .systemFont(ofSize: 12)
        }

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
