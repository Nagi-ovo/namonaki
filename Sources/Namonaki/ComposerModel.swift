import Foundation
import Combine

/// 发送框的共享状态。回复某人时先把 "@某人 " 填进去，
/// 窗口是复用的，所以得有个外部能写的地方。
@MainActor
final class ComposerModel: ObservableObject {
    static let shared = ComposerModel()

    @Published var text = ""
    /// 每次要求聚焦就 +1，复用中的 AppKit 输入窗靠它重新拿焦点。
    @Published var focusToken = 0

    private init() {}

    func prepareReply(to name: String) {
        let mention = "@\(name) "
        text = text.hasPrefix(mention) ? text : mention
        focusToken += 1
    }

    func focus() {
        focusToken += 1
    }
}
