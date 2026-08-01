import AppKit
import Carbon.HIToolbox

/// 全局快捷键。菜单栏 app 平时不是激活状态，普通的菜单快捷键根本收不到，
/// 所以得走 Carbon 这套系统级注册——好处是不需要辅助功能权限。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// ⌥⌘E 切换编辑模式，⌥⌘D 打开发弹幕窗口。
    /// 都带 ⌥ 是为了避开 ⌘E / ⌘D 这种各家 app 都在用的组合——
    /// 全局注册会把它从所有 app 手里抢过来。
    enum Action: UInt32 {
        case toggleEditing = 1
        case compose = 2
    }

    var onFire: ((Action) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        guard refs.isEmpty else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let raw = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let action = Action(rawValue: raw) else { return }
                        GlobalHotKey.shared.onFire?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        add(keyCode: UInt32(kVK_ANSI_E), action: .toggleEditing)
        add(keyCode: UInt32(kVK_ANSI_D), action: .compose)
    }

    private func add(keyCode: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x444D_4855), id: action.rawValue)  // 'DMHU'
        RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs.append(ref)
    }
}
