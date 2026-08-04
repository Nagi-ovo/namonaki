import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var hud: HUDWindow?
    private var settingsWindow: NSWindow?
    private var composerWindow: NSWindow?
    private var loginWindow: LoginWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared
    private let runtime = OpenLiveRuntime.shared
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start(authCode: prefs.authCode)

        prefs.$authCode
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] code in self?.runtime.updateAuthCode(code) }
            .store(in: &cancellables)

        // Keep the OBS page on the same look as the HUD. The relay latches the last value,
        // so a browser source that connects later still gets it.
        Publishers.CombineLatest4(
            prefs.$fontSize, prefs.$nameOpacity, prefs.$backdropAlpha, prefs.$presetID
        )
        .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            guard let self else { return }
            self.runtime.publishStyle(self.prefs.obsStylePayload)
        }
        .store(in: &cancellables)

        let window = HUDWindow()
        window.alphaValue = prefs.opacity
        window.level = prefs.alwaysOnTop ? HUDWindow.overlayLevel : .normal
        window.setEditingLayout(false)
        window.onEditingEnded = { [weak self] in
            guard let self, let hud = self.hud else { return }
            hud.setEditingLayout(false)
            self.statusItem?.menu = self.buildMenu()
        }
        window.orderFrontRegardless()
        hud = window

        setUpMainMenu()
        setUpStatusItem()

        GlobalHotKey.shared.onFire = { [weak self] action in
            switch action {
            case .toggleEditing: self?.toggleEditing()
            case .compose: self?.showComposer()
            }
        }
        GlobalHotKey.shared.register()

        // 没配身份码时直接把设置面板推到脸上，省得找
        if prefs.authCode.isEmpty {
            showSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { [runtime] in
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - 主菜单

    /// LSUIElement 的 app 默认没有主菜单，Cmd+C/V 这些标准快捷键就无处响应，
    /// 输入框会变成「打不了字也粘不了」。这里补一份最小的编辑菜单。
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let composer = NSMenuItem(title: "发弹幕…", action: #selector(showComposer), keyEquivalent: "d")
        composer.keyEquivalentModifierMask = [.command, .option]
        composer.target = self
        appMenu.addItem(composer)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出弹幕窗", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.image?.accessibilityDescription = "弹幕"
        item.menu = buildMenu()
        statusItem = item

        // 开关状态变了，菜单上的勾也要跟着变
        Publishers.CombineLatest(prefs.$alwaysOnTop, prefs.$opacity)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.statusItem?.menu = self.buildMenu()
            }
            .store(in: &cancellables)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // —— 常用动作 ——
        let compose = NSMenuItem(title: "发弹幕…　⌥⌘D", action: #selector(showComposer), keyEquivalent: "")
        compose.target = self
        menu.addItem(compose)

        let editing = NSMenuItem(title: "调整位置和大小　⌥⌘E", action: #selector(toggleEditing), keyEquivalent: "")
        editing.target = self
        editing.state = (hud?.isEditingLayout ?? false) ? .on : .off
        menu.addItem(editing)

        menu.addItem(.separator())

        // —— 显示方式（开关类）——
        let visible = NSMenuItem(title: "显示弹幕窗", action: #selector(toggleHUD), keyEquivalent: "")
        visible.target = self
        visible.state = (hud?.isVisible ?? false) ? .on : .off
        menu.addItem(visible)

        let top = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        top.target = self
        top.state = prefs.alwaysOnTop ? .on : .off
        menu.addItem(top)

        let outline = NSMenuItem(title: "显示窗口轮廓", action: #selector(toggleOutline), keyEquivalent: "")
        outline.target = self
        outline.state = prefs.showOutline ? .on : .off
        menu.addItem(outline)

        menu.addItem(.separator())

        // —— 摆放（收进子菜单）——
        let placement = NSMenuItem(title: "摆放", action: nil, keyEquivalent: "")
        placement.submenu = buildPlacementMenu()
        menu.addItem(placement)

        let opacity = NSMenuItem(title: "不透明度（\(Int(prefs.opacity * 100))%）", action: nil, keyEquivalent: "")
        opacity.submenu = buildOpacityMenu()
        menu.addItem(opacity)

        menu.addItem(.separator())

        // —— 维护 ——
        let reload = NSMenuItem(title: "重新加载", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func buildPlacementMenu() -> NSMenu {
        let menu = NSMenu()

        let remember = NSMenuItem(title: "记住当前位置", action: #selector(rememberSpot), keyEquivalent: "")
        remember.target = self
        menu.addItem(remember)

        let recall = NSMenuItem(title: "回到记住的位置", action: #selector(recallSpot), keyEquivalent: "")
        recall.target = self
        recall.isEnabled = !prefs.bookmarkFrame.isEmpty
        menu.addItem(recall)

        menu.addItem(.separator())

        let fill = NSMenuItem(title: "铺满屏幕高度", action: #selector(fillHeight), keyEquivalent: "")
        fill.target = self
        menu.addItem(fill)

        let reset = NSMenuItem(title: "找不着了，拉回屏幕中间", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        return menu
    }

    private func buildOpacityMenu() -> NSMenu {
        let menu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.5, 0.35] {
            let entry = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = value
            entry.state = abs(prefs.opacity - value) < 0.02 ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: - 动作

    @objc private func toggleHUD() {
        guard let hud else { return }
        if hud.isVisible {
            hud.orderOut(nil)
        } else {
            hud.orderFrontRegardless()
        }
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleEditing() {
        Log.write("菜单项「调整位置和大小」被点击")
        guard let hud else { return }
        let next = !hud.isEditingLayout
        hud.setEditingLayout(next)
        if next {
            // 编辑时得能点到它，顺手抬到最前
            hud.orderFrontRegardless()
        }
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleOutline() {
        prefs.showOutline.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleAlwaysOnTop() {
        prefs.alwaysOnTop.toggle()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.opacity = value
    }

    @objc private func fillHeight() {
        hud?.fillScreenHeight()
    }

    @objc private func rememberSpot() {
        hud?.rememberSpot()
        statusItem?.menu = buildMenu()
    }

    @objc private func recallSpot() {
        hud?.recallSpot()
    }

    @objc private func resetPosition() {
        hud?.resetPosition()
        hud?.orderFrontRegardless()
    }

    @objc private func reload() {
        hud?.reload()
    }

    func openComposer() {
        showComposer()
        ComposerModel.shared.focus()
    }

    @objc private func showComposer() {
        if let composerWindow {
            composerWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ComposerViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "发弹幕"
        // No .fullSizeContentView: nothing is drawn into the title bar, and letting the
        // content slide under it put the input field on top of the traffic lights.
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        composerWindow = window
    }

    func showLogin() {
        if let loginWindow {
            loginWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = LoginWindow { [weak self] in
            self?.loginWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginWindow = window
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "弹幕窗设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        let fixedContentSize = NSSize(width: 500, height: 500)
        window.setContentSize(fixedContentSize)
        window.contentMinSize = fixedContentSize
        window.contentMaxSize = fixedContentSize
        // 空白处也能拖，不用非得抓标题栏
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
