import AppKit
import Carbon.HIToolbox

/// 全局快捷键（⌥⌘E）。菜单栏 app 平时不是激活状态，普通的菜单快捷键根本收不到，
/// 所以得走 Carbon 这套系统级注册——好处是不需要辅助功能权限。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotKey.shared.onFire?() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let id = EventHotKeyID(signature: OSType(0x444D_4855), id: 1)  // 'DMHU'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(cmdKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
