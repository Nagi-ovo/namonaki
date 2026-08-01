import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 菜单栏常驻，不占 Dock
app.setActivationPolicy(.accessory)
app.run()
