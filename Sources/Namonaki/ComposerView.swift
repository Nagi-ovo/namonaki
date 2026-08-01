import SwiftUI
import AppKit

/// 发弹幕的小输入框。弹幕窗平时对鼠标隐形，所以发送单独开一个能聚焦的小窗。
struct ComposerView: View {
    @ObservedObject private var account = BilibiliAccount.shared
    @ObservedObject private var model = ComposerModel.shared
    @State private var status: Status = .idle
    @State private var showEmoticons = false
    @FocusState private var focused: Bool

    private var text: String {
        get { model.text }
        nonmutating set { model.text = newValue }
    }

    /// B 站普通用户的弹幕上限是 20 字。超了服务端会返回 1003212，
    /// 但那时候话已经打完了，白等一轮——不如在这儿就拦住。
    private let maxLength = 20

    private var overLimit: Bool { model.text.count > maxLength }

    private enum Status: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("说点什么…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { submit() }
                    // @某某 是一个整体，删的时候应该一次删掉，
                    // 而不是让人按十几下退格
                    .onKeyPress(.delete) {
                        guard let range = model.text.range(
                            of: #"@[^\s@]+\s?$"#, options: .regularExpression
                        ) else { return .ignored }
                        model.text.removeSubrange(range)
                        return .handled
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.12))
                    )

                Button {
                    showEmoticons.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.bordered)
                .disabled(!account.isLoggedIn)
                .popover(isPresented: $showEmoticons, arrowEdge: .bottom) {
                    EmoticonPicker { emoticon in
                        showEmoticons = false
                        sendEmoticon(emoticon)
                    }
                }

                Button {
                    submit()
                } label: {
                    if status == .sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending || overLimit)
            }

            HStack(spacing: 6) {
                switch status {
                case .idle:
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .sending:
                    Text("发送中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .sent:
                    Label("已发送", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(text.count)/\(maxLength)")
                    .font(.system(size: 10, weight: overLimit ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(overLimit ? Color.orange : Color.secondary.opacity(0.6))
            }
        }
        .padding(14)
        .frame(width: 420)
        .onAppear {
            focused = true
            Task { await account.refreshEmoticons() }
        }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        // 改了文字就把上一条错误清掉，否则删到合法长度了红字还挂在那儿
        .onChange(of: model.text) { _, _ in
            if case .failed = status { status = .idle }
        }
    }

    private var hint: String {
        if overLimit { return "超出 \(model.text.count - maxLength) 字，发不出去" }
        guard account.isLoggedIn else { return "还没登录，去设置里登录 B 站账号" }
        guard let room = account.effectiveRoomID else { return "还没设置直播间号" }
        let who = account.userName.map { "以 \($0) 的身份" } ?? ""
        return "\(who)发到直播间 \(room)"
    }

    private func sendEmoticon(_ emoticon: BilibiliAccount.Emoticon) {
        status = .sending
        Task {
            do {
                try await account.send(emoticon: emoticon)
                status = .sent
                try? await Task.sleep(for: .seconds(1.5))
                if status == .sent { status = .idle }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func submit() {
        let content = text
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !overLimit else {
            status = .failed("超出 \(content.count - maxLength) 字，B 站最多 \(maxLength) 字")
            return
        }
        status = .sending
        Task {
            do {
                try await account.send(content)
                text = ""
                status = .sent
                try? await Task.sleep(for: .seconds(1.5))
                if status == .sent { status = .idle }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
