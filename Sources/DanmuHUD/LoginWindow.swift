import AppKit
import WebKit

/// B 站登录窗口。就是个普通 WebView，扫码或密码登录都行，
/// 登录成功后从 WebView 的 Cookie 里取 SESSDATA / bili_jct 存进钥匙串。
@MainActor
final class LoginWindow: NSWindow {
    private let webView: WKWebView
    private var timer: Timer?
    private let onSuccess: () -> Void

    init(onSuccess: @escaping () -> Void) {
        self.onSuccess = onSuccess

        let config = WKWebViewConfiguration()
        // 用独立的存储，别和弹幕窗那个 WebView 混在一起
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "登录 B 站"
        isReleasedWhenClosed = false
        center()
        webView.autoresizingMask = [.width, .height]
        contentView = webView
        webView.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))

        startPolling()
    }

    /// 登录成功没有明确回调，轮询 Cookie 最省事
    private func startPolling() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCookies() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                guard BilibiliAccount.shared.adoptCookies(cookies) else { return }
                self.stopPolling()
                await BilibiliAccount.shared.refreshProfile()
                self.onSuccess()
                self.close()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    override func close() {
        stopPolling()
        super.close()
    }
}
