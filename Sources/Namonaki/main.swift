import AppKit

// 改名前的配置和凭证要先搬过来，否则一升级全部归零
MainActor.assumeIsolated { Migration.runIfNeeded() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 菜单栏常驻，不占 Dock
app.setActivationPolicy(.accessory)
app.run()
