import AppKit
import WebKit
import Combine

/// 桌面上那个半透明弹幕窗。
/// 无标题栏、背景透明、可置顶、可鼠标穿透，整块区域都能拖动。
@MainActor
final class HUDWindow: NSWindow {
    private let webView: WKWebView
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared
    private weak var dragOverlay: DragOverlay?

    /// 编辑布局模式：窗口临时可点、可拖、可缩放，并画出边框好让人看清范围。
    /// 平时是关的，窗口对鼠标完全隐形。
    private(set) var isEditingLayout = false

    func setEditingLayout(_ editing: Bool) {
        isEditingLayout = editing
        // 只有编辑时才接鼠标事件；其余时候整个窗口对鼠标隐形，
        // 免得那一大片透明区域挡住后面的东西。
        ignoresMouseEvents = !editing
        dragOverlay?.showsGuide = editing
        if editing {
            // 要成为 key window 才收得到 Esc
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 编辑模式下按 Esc 直接完事，不用再摸回菜单栏
    override func cancelOperation(_ sender: Any?) {
        guard isEditingLayout else { return }
        onEditingEnded?()
    }

    /// 退出编辑后通知 AppDelegate 把菜单勾选状态同步过来
    var onEditingEnded: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: config)

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
        // disallowsTiling：拖到屏幕边缘时不要弹出 macOS 的窗口平铺提示，
        // 那东西对一个 HUD 窗口只会碍事
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .fullScreenDisallowsTiling]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // WKWebView 自己的白底也要去掉，否则窗口透明了内容还是白的
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        container.addSubview(webView)

        // WKWebView 会吃掉所有鼠标事件，窗口就拖不动了。
        // 盖一层透明视图接管拖动，滚轮再转发回去，这样还能翻历史弹幕。
        let overlay = DragOverlay(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.forwardTarget = webView
        container.addSubview(overlay)
        dragOverlay = overlay

        contentView = container

        // 存的是窗口 frame，但 init 收的是 contentRect，两者差一个标题栏高度。
        // 这里再按 frame 摆一次，否则每次启动都会往下掉一截。
        restoreSavedFrame()

        installUserScript()
        bindPreferences()
        reload()
    }

    private func bindPreferences() {
        prefs.$opacity
            .sink { [weak self] value in self?.alphaValue = value }
            .store(in: &cancellables)

        prefs.$alwaysOnTop
            .sink { [weak self] on in self?.level = on ? Self.overlayLevel : .normal }
            .store(in: &cancellables)


        prefs.$roomURL
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        prefs.$customCSS
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.injectCSS() }
            .store(in: &cancellables)

        // 字号 / 用户名清晰度 / 头像大小 / 衬底浓度，拖滑杆要立刻看到变化
        Publishers.CombineLatest4(
            prefs.$fontSize, prefs.$nameOpacity, prefs.$avatarSize, prefs.$backdropAlpha
        )
        .dropFirst()
        .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in self?.injectCSS() }
        .store(in: &cancellables)

        // 调试消息开关写在 URL 参数里，改了得重新载入
        prefs.$showDebugMessages
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        guard let url = resolvedRoomURL() else {
            webView.loadHTMLString(Self.placeholderHTML, baseURL: nil)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// blivechat 的连接状态提示（Connecting / Disconnected …）由 URL 参数控制，
    /// 这里按设置改写，用户不用回网页里翻开关。
    private func resolvedRoomURL() -> URL? {
        let raw = prefs.roomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: raw), comps.scheme != nil else { return nil }

        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "showDebugMessages" }
        items.append(URLQueryItem(name: "showDebugMessages", value: prefs.showDebugMessages ? "true" : "false"))
        comps.queryItems = items
        return comps.url
    }

    /// 把 CSS 塞进一个 JS 字符串字面量。用 JSON 编码最保险，
    /// 免得 CSS 里的引号、反斜杠把脚本弄坏。
    private var cssInjectionJS: String {
        // 滑杆的值写在样式表后面，这样能覆盖 CSS 里的默认变量
        let combined = prefs.customCSS + "\n\n/* 设置面板 */\n" + prefs.variableCSS
        let literal = (try? JSONSerialization.data(withJSONObject: [combined]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          function apply() {
            var head = document.head || document.documentElement;
            if (!head) { return; }
            var el = document.getElementById('danmu-hud-style');
            if (!el) {
              el = document.createElement('style');
              el.id = 'danmu-hud-style';
              head.appendChild(el);
            }
            el.textContent = \(literal);
            // blivechat 是单页应用，重渲染时可能把 style 冲掉，兜一下
            if (el.parentNode !== head) { head.appendChild(el); }
          }
          apply();
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', apply);
          }
          setTimeout(apply, 500);
          setTimeout(apply, 1500);
        })();
        """
    }

    /// 页面一加载就自动注入，比等 didFinish 再 evaluate 可靠得多
    private func installUserScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: cssInjectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    fileprivate func injectCSS() {
        installUserScript()
        webView.evaluateJavaScript(cssInjectionJS) { _, error in
            if let error {
                NSLog("[DanmuHUD] CSS 注入失败: \(error.localizedDescription)")
            }
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        // 存系统最终采用的 frame，不是我们请求的那个，否则重启后位置对不上
        prefs.saveFrame(frame)
    }

    /// 系统默认把窗口限制在屏幕可用区域内（菜单栏以下、边缘以内），
    /// 弹幕窗想拉到整屏高就会被卡住。这里直接放行。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// 比菜单栏（.mainMenu）高一级，否则内置屏上窗口顶边会被系统按在菜单栏下面，
    /// 副屏没有菜单栏所以感觉不到这个限制。
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1
    )

    /// 按保存的 frame 复位；窗口要是跑到屏幕外面了就拉回可见区域。
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

    /// 把窗口拉回主屏中间，尺寸也复位——窗口找不着了的时候用
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

    /// 铺满当前所在屏幕的高度。用 frame 而不是 visibleFrame，
    /// 这样才包括菜单栏和 Dock 占的那部分。
    func fillScreenHeight() {
        // 先用窗口中心点锁定目标屏幕，别在改 frame 的过程中让系统重新判断，
        // 否则跨屏边缘时 x 会来回跳。
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

    private static let placeholderHTML = """
    <html><body style="margin:0;background:transparent;
      font:15px/1.6 -apple-system,'PingFang SC',sans-serif;
      color:rgba(255,255,255,0.6);display:flex;align-items:center;
      justify-content:center;height:100vh;text-align:center;
      text-shadow:0 1px 3px rgba(0,0,0,0.6)">
      还没设置房间地址<br>菜单栏图标 → 设置
    </body></html>
    """
}

extension HUDWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        injectCSS()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectCSS()
    }
}

/// 透明拖动层：按住任意位置都能挪窗口，滚轮转发给底下的 WebView。
/// 编辑布局时还会画一圈边框，让人看清窗口到底占多大。
private final class DragOverlay: NSView {
    weak var forwardTarget: NSView?

    var showsGuide = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        Log.write("DragOverlay.mouseDown showsGuide=\(showsGuide)")
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 编辑模式才接管点击；平时让事件穿到下面，免得挡住网页交互
        showsGuide ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        forwardTarget?.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsGuide else { return }

        // 只描边不铺色，免得整块蓝把弹幕盖住
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let border = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        border.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        border.stroke()

        // 右下角的抓手，提示这里可以拖着缩放
        let grip = NSRect(x: bounds.maxX - 16, y: bounds.minY + 4, width: 12, height: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()

        drawHint()
    }

    /// 顶部那条「拖动调整 · 按 Esc 完成」的提示
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
