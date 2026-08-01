import AppKit
import WebKit
import Combine

/// 接管右键菜单的 WebView。左键要留给网页做文字选中，
/// 所以回复只能挂在右键上，而右键默认会弹 WebKit 自己的菜单。
@MainActor
final class ChatWebView: WKWebView {
    var hoveredAuthor: (() -> String?)?
    var onReply: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard let author = hoveredAuthor?(), !author.isEmpty else { return }
        menu.removeAllItems()
        let item = NSMenuItem(title: "回复 @\(author)", action: #selector(replyAction), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func replyAction() {
        onReply?()
    }
}

/// 桌面上那个半透明弹幕窗。
/// 无标题栏、背景透明、平时对鼠标隐形，编辑模式下可拖可缩放。
@MainActor
final class HUDWindow: NSWindow {
    private let webView: ChatWebView
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared
    private weak var dragOverlay: DragOverlay?

    /// 编辑布局模式：窗口临时可点、可拖、可缩放，并画出边框好让人看清范围。
    /// 平时是关的，窗口对鼠标完全隐形。
    private(set) var isEditingLayout = false

    /// JS 定期上报的每条弹幕的位置和作者，用来判断鼠标有没有悬在弹幕上
    fileprivate struct MessageHit {
        let rect: NSRect
        let author: String
    }
    fileprivate var messageHits: [MessageHit] = []
    private var hoverTimer: Timer?
    /// 鼠标正悬在某条弹幕上——这时窗口临时接收鼠标事件，好让人右键回复
    private var hoveringAuthor: String?

    func setEditingLayout(_ editing: Bool) {
        isEditingLayout = editing
        // 只有编辑时才接鼠标事件；其余时候整个窗口对鼠标隐形，
        // 免得那一大片透明区域挡住后面的东西。
        ignoresMouseEvents = !editing
        dragOverlay?.showsGuide = editing
        dragOverlay?.isEditing = editing
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
        webView = ChatWebView(frame: .zero, configuration: config)

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
        webView.hoveredAuthor = { [weak self] in self?.hoveringAuthor }
        webView.onReply = { [weak self] in self?.replyToHovered() }

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
        installMessageTracking()
        bindPreferences()
        startHoverTracking()
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

        prefs.$showOutline
            .sink { [weak self] on in self?.dragOverlay?.showsOutline = on }
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

        // 同一个身份码不能同时开多个直连（OBS 的浏览器源 + 这个窗口就会打架，
        // B 站会把 session 踢掉）。走服务器转发的话，blivechat 后端只占一个名额，
        // 前端要开几个都行。
        items.removeAll { $0.name == "relayMessagesByServer" }
        items.append(URLQueryItem(name: "relayMessagesByServer", value: "true"))

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

    /// 让页面定期上报每条弹幕的位置和作者。
    /// 有了这些矩形，才能判断鼠标是不是悬在弹幕上——窗口平时对鼠标隐形，
    /// 只有悬在弹幕上时才临时接收事件，这样右键回复和「不挡路」能同时成立。
    private func installMessageTracking() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "danmuRects")
        controller.add(MessageRectBridge(window: self), name: "danmuRects")
        controller.removeScriptMessageHandler(forName: "danmuHistory")
        controller.add(HistoryBridge(), name: "danmuHistory")
        installUserScript()
    }

    private var messageTrackingJS: String {
        """
        (function () {
          function report() {
            try {
              var nodes = document.querySelectorAll(
                'yt-live-chat-text-message-renderer, yt-live-chat-paid-message-renderer'
              );
              var out = [];
              for (var i = 0; i < nodes.length; i++) {
                var r = nodes[i].getBoundingClientRect();
                if (r.height <= 0 || r.bottom < 0 || r.top > window.innerHeight) { continue; }
                var nameEl = nodes[i].querySelector('#author-name');
                out.push({
                  x: r.left, y: r.top, w: r.width, h: r.height,
                  name: nameEl ? nameEl.textContent.trim() : ''
                });
              }
              window.webkit.messageHandlers.danmuRects.postMessage({
                items: out, viewportHeight: window.innerHeight
              });
            } catch (e) {}
          }
          setInterval(report, 250);
          report();

          // 新来的消息存一份，下次启动铺回去。带 data-history 的是上次铺回来的，
          // 别再上报一遍，否则历史会自我复制越滚越多。
          var seen = new WeakSet();
          function reportNew() {
            try {
              var nodes = document.querySelectorAll(
                'yt-live-chat-text-message-renderer:not([data-history]),'
                + 'yt-live-chat-paid-message-renderer:not([data-history])'
              );
              for (var i = 0; i < nodes.length; i++) {
                if (seen.has(nodes[i])) { continue; }
                seen.add(nodes[i]);
                window.webkit.messageHandlers.danmuHistory.postMessage(nodes[i].outerHTML);
              }
            } catch (e) {}
          }
          setInterval(reportNew, 500);
        })();
        """
    }

    /// 把上次存下来的弹幕铺回窗口，免得冷启动时一片空白
    private func restoreHistory() {
        let items = HistoryStore.shared.all
        guard !items.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: items),
              let literal = String(data: data, encoding: .utf8) else { return }

        // 页面初始化会清空消息区，插进去的历史转眼就没了。
        // 所以插完还要盯着：被清掉就重新插回来，直到有真弹幕进来为止。
        let js = """
        (function () {
          try {
            var scroller = document.querySelector('#item-scroller');
            var items = document.querySelector('#items');
            if (!items) { return 'no-items'; }

            function build() {
              var host = document.createElement('div');
              host.id = 'blc-history';
              host.innerHTML = \(literal).join('');
              for (var i = 0; i < host.children.length; i++) {
                host.children[i].setAttribute('data-history', '1');
              }
              return host;
            }

            // #items 的高度由 blivechat 用 JS 控着（滚动动画要用），
            // 塞进去的内容撑不开它，整块就塌成 0 高。
            // 插到滚动容器里、它管辖的 #item-offset 之前，才能正常占位。
            function place() {
              if (document.getElementById('blc-history')) { return; }
              var sc = document.querySelector('#item-scroller');
              var offset = document.querySelector('#item-offset');
              if (!sc || !offset) { return; }
              sc.insertBefore(build(), offset);
              sc.scrollTop = sc.scrollHeight;
            }

            place();

            // 页面把它抹掉就再放一次，最多补 20 次，避免无限打架
            var tries = 0;
            var guard = setInterval(function () {
              if (tries++ > 20) { clearInterval(guard); return; }
              place();
            }, 400);

            var host = document.getElementById('blc-history');
            var first = host && host.children[0];
            return JSON.stringify({
              placed: !!host,
              kids: host ? host.children.length : -1,
              hostH: host ? host.getBoundingClientRect().height : -1,
              hostDisplay: host ? getComputedStyle(host).display : '',
              firstTag: first ? first.tagName : '',
              firstH: first ? first.getBoundingClientRect().height : -1,
              firstDisplay: first ? getComputedStyle(first).display : '',
              itemsDisplay: getComputedStyle(items).display,
              itemsH: items.getBoundingClientRect().height
            });
          } catch (e) { return 'error:' + e.message; }
        })();
        """
        webView.evaluateJavaScript(js) { result, error in
            Log.write("restoreHistory -> \(result ?? "nil") error=\(error?.localizedDescription ?? "none")")
        }
    }

    /// 轮询鼠标位置。用轮询而不是全局事件监听，是为了不碰辅助功能权限。
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
            applyHover(nil)
            return
        }

        let local = NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
        let hit = messageHits.first { $0.rect.contains(local) }
        applyHover(hit?.author)
    }

    private func applyHover(_ author: String?) {
        guard hoveringAuthor != author else { return }
        hoveringAuthor = author
        dragOverlay?.hoveredAuthor = author
        ignoresMouseEvents = author == nil
    }

    /// 右键弹幕时用的
    fileprivate func replyToHovered() {
        guard let author = hoveringAuthor, !author.isEmpty else { return }
        ComposerModel.shared.prepareReply(to: author)
        (NSApp.delegate as? AppDelegate)?.openComposer()
    }

    /// 页面一加载就自动注入，比等 didFinish 再 evaluate 可靠得多。
    /// 注意 removeAllUserScripts 是一刀切的，所以每次重装都得把弹幕位置上报
    /// 那段一起加回去——之前漏了这条，右键回复一直没反应就是因为它被清掉了。
    private func installUserScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for source in [cssInjectionJS, messageTrackingJS] {
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
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

    /// 把当前位置和大小收藏起来
    func rememberSpot() {
        prefs.bookmarkFrame = NSStringFromRect(frame)
    }

    /// 回到收藏的位置
    func recallSpot() {
        guard !prefs.bookmarkFrame.isEmpty else { return }
        let target = NSRectFromString(prefs.bookmarkFrame)
        guard target.width > 0, target.height > 0 else { return }
        setFrame(target, display: true)
        orderFrontRegardless()
    }

    /// 直接按数字摆放，设置面板里手填坐标用
    func applyFrame(x: Double, y: Double, width: Double, height: Double) {
        setFrame(NSRect(x: x, y: y, width: max(width, 120), height: max(height, 80)), display: true)
        orderFrontRegardless()
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
        // 页面刚渲染完 #items 可能还没挂上，稍等一下再铺历史
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            self.restoreHistory()
        }
    }
}

/// 收下新弹幕的 HTML，存进历史
private final class HistoryBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let html = message.body as? String else { return }
        Task { @MainActor in
            HistoryStore.shared.append(html)
        }
    }
}

/// 把 JS 上报的弹幕矩形转成 AppKit 坐标存起来。
/// 网页坐标原点在左上，NSView 在左下，得翻一下 y。
private final class MessageRectBridge: NSObject, WKScriptMessageHandler {
    private weak var window: HUDWindow?

    init(window: HUDWindow) {
        self.window = window
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let items = payload["items"] as? [[String: Any]],
              let viewportHeight = payload["viewportHeight"] as? Double else { return }

        let hits = items.compactMap { item -> HUDWindow.MessageHit? in
            guard let x = item["x"] as? Double, let y = item["y"] as? Double,
                  let w = item["w"] as? Double, let h = item["h"] as? Double else { return nil }
            return HUDWindow.MessageHit(
                rect: NSRect(x: x, y: viewportHeight - y - h, width: w, height: h),
                author: item["name"] as? String ?? ""
            )
        }

        Task { @MainActor in
            self.window?.messageHits = hits
        }
    }
}

/// 透明拖动层：按住任意位置都能挪窗口，滚轮转发给底下的 WebView。
/// 编辑布局时还会画一圈边框，让人看清窗口到底占多大。
private final class DragOverlay: NSView {
    weak var forwardTarget: NSView?

    var isEditing = false
    /// 鼠标底下那条弹幕的作者，非空时这层才接管点击
    var hoveredAuthor: String? {
        didSet { needsDisplay = true }
    }

    var showsGuide = false {
        didSet { needsDisplay = true }
    }

    /// 常驻的淡边框。没弹幕时窗口全透明，不画点东西根本找不着它在哪。
    var showsOutline = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只有编辑模式才接管。平时一律放行给下面的 WebView——
        // 左键要留给网页选中复制文字，回复走右键菜单。
        isEditing ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        forwardTarget?.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsGuide else {
            if showsOutline {
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                path.lineWidth = 1
                NSColor.white.withAlphaComponent(0.22).setStroke()
                path.stroke()
            }
            return
        }

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
