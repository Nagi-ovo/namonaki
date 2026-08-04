import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionTab()
                .tabItem { Label("连接", systemImage: "link") }
            ScrollView { DanmakuTab().padding(.trailing, 4) }
                .tabItem { Label("弹幕", systemImage: "textformat.size") }
            WindowTab()
                .tabItem { Label("窗口", systemImage: "macwindow") }
            AccountTab()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
            StyleTab()
                .tabItem { Label("CSS", systemImage: "curlybraces") }
        }
        .padding(14)
        .frame(width: 480, height: 460)
    }
}

// MARK: - 连接

private struct ConnectionTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var runtime = OpenLiveRuntime.shared
    @State private var draft = Preferences.shared.authCode
    @State private var revealed = false
    @State private var hint: String?
    @State private var copiedOBS = false

    private var isSet: Bool { !prefs.authCode.isEmpty }

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var statusColor: Color {
        if case .failed = runtime.relayState { return .red }
        switch runtime.connectionState {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary.opacity(0.5)
        case .connecting, .authenticating, .reconnecting: return .orange
        }
    }

    private var statusLabel: String {
        if case .failed = runtime.relayState {
            return "本机转发启动失败（端口 12451 可能被占用）"
        }
        return runtime.connectionState.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("开放平台身份码")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Group {
                        if revealed {
                            TextField("12–14 位大写字母或数字", text: $draft)
                        } else {
                            SecureField("12–14 位大写字母或数字", text: $draft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    Button(revealed ? "隐藏" : "显示") { toggleReveal() }
                        .disabled(draft.isEmpty)
                }

                HStack(spacing: 8) {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])

                    Button("保存并连接") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(normalizedDraft == prefs.authCode)

                    Spacer()

                    Button("清除") {
                        draft = ""
                        prefs.authCode = ""
                        revealed = false
                        hint = nil
                    }
                    .disabled(!isSet && draft.isEmpty)
                }
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hint.hasPrefix("✓") ? Color.green : Color.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OBS 浏览器源")
                            .font(.system(size: 12, weight: .medium))
                        Text("HUD 和 OBS 共用同一条 B 站连接，不再抢 session。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copiedOBS ? "已复制" : "复制 OBS 地址") { copyOBSURL() }
                        .disabled(runtime.obsURL == nil)
                }

                Text("http://127.0.0.1:…/room/native?token=••••••••")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: $prefs.showDebugMessages) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在弹幕窗显示连接状态")
                    Text("平时关掉更干净，排查掉线时再打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Spacer()

            Text("隐私：身份码会发给 api1/api2.blive.chat 换取 B 站会话；不会进 OBS 地址或 App 日志。账号 Cookie 和弹幕内容不会发给该服务。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = prefs.authCode }
        .onDisappear { revealed = false }
    }

    private func pasteFromClipboard() {
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hint = "剪贴板是空的"
            return
        }
        let candidates = [text.uppercased()] + text
            .uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard let code = candidates.first(where: OpenLiveRuntime.isValidAuthCode) else {
            hint = "没找到 12–14 位身份码"
            return
        }
        draft = code
        revealed = false
        hint = "✓ 已识别，点「保存并连接」"
    }

    private func save() {
        guard OpenLiveRuntime.isValidAuthCode(normalizedDraft) else {
            hint = "身份码应为 12–14 位大写字母或数字"
            return
        }
        draft = normalizedDraft
        prefs.authCode = normalizedDraft
        revealed = false
        hint = "✓ 已保存，正在连接"
    }

    private func copyOBSURL() {
        guard let url = runtime.obsURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedOBS = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedOBS = false
        }
    }

    private func toggleReveal() {
        revealed.toggle()
        guard revealed else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            revealed = false
        }
    }
}

// MARK: - 弹幕

private struct DanmakuTab: View {
    @ObservedObject private var prefs = Preferences.shared

    private var preset: StylePreset { prefs.preset }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("风格")
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(
                    get: { prefs.preset },
                    set: { prefs.apply($0) }
                )) {
                    ForEach(StylePreset.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("衬底浓度")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(prefs.backdropAlpha < 0.02 ? "无" : "\(Int(prefs.backdropAlpha * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $prefs.backdropAlpha, in: 0...0.85)
                Text("弹幕背后垫的深色块。浅色桌面上调高才看得清；叠在深色画面上拖到 0 就全透明。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("弹幕字号")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(prefs.fontSize))px")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $prefs.fontSize, in: 14...34, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("用户名清晰度")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(prefs.nameOpacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $prefs.nameOpacity, in: 0.3...1.0)
                Text("调低会让用户名往后退，正文更突出；调到 100% 就和正文一样清楚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


            Button("回到「\(preset.title)」的默认值") {
                prefs.apply(preset)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 窗口

private struct WindowTab: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("不透明度")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(prefs.opacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $prefs.opacity, in: 0.25...1.0)
            }

            Divider()

            Toggle(isOn: $prefs.alwaysOnTop) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("始终置顶")
                    Text("开：永远盖在最上面。关：点哪个窗口，哪个窗口就压到弹幕上面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $prefs.showOutline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示窗口轮廓")
                    Text("画一圈淡边框标出窗口范围。没弹幕时窗口是全透明的，容易找不着")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            PositionEditor()

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("怎么调整位置和大小")
                    .font(.system(size: 12, weight: .medium))
                Text("平时弹幕窗对鼠标完全隐形，透明区域也不会挡住后面的东西。要挪位置或改大小，用菜单栏图标里的「调整位置和大小」（⌘E）——窗口会显示边框，这时可以随便拖边缘缩放，调完再按一次关掉。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - 位置

/// 直接按数字摆窗口，外加一个「记住 / 回到」的收藏位
private struct PositionEditor: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var x = ""
    @State private var y = ""
    @State private var w = ""
    @State private var h = ""

    private var hud: HUDWindow? { (NSApp.delegate as? AppDelegate)?.hud }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("位置和大小")
                .font(.system(size: 13, weight: .medium))

            HStack(spacing: 6) {
                field("X", $x)
                field("Y", $y)
                field("宽", $w)
                field("高", $h)
                Button("应用") { apply() }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("记住当前位置") {
                    hud?.rememberSpot()
                    load()
                }
                .controlSize(.small)

                Button("回到记住的位置") {
                    hud?.recallSpot()
                    load()
                }
                .controlSize(.small)
                .disabled(prefs.bookmarkFrame.isEmpty)

                Spacer()

                Button("读取当前") { load() }
                    .controlSize(.small)
            }

            Text("坐标原点在屏幕左下角。想固定在某个位置，摆好后点「记住当前位置」，以后一键回来。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { load() }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 60)
        }
    }

    private func load() {
        guard let frame = hud?.frame else { return }
        x = String(Int(frame.minX))
        y = String(Int(frame.minY))
        w = String(Int(frame.width))
        h = String(Int(frame.height))
    }

    private func apply() {
        guard let hud,
              let px = Double(x), let py = Double(y),
              let pw = Double(w), let ph = Double(h) else { return }
        hud.applyFrame(x: px, y: py, width: pw, height: ph)
        load()
    }
}

// MARK: - 账号（发弹幕用）

private struct AccountTab: View {
    @ObservedObject private var account = BilibiliAccount.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(account.isLoggedIn ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(account.isLoggedIn
                     ? (account.userName.map { "已登录：\($0)" } ?? "已登录")
                     : "未登录")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            HStack(spacing: 8) {
                Button(account.isLoggedIn ? "重新登录" : "登录 B 站账号") {
                    (NSApp.delegate as? AppDelegate)?.showLogin()
                }
                if account.isLoggedIn {
                    Button("退出登录") { account.signOut() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("发送到哪个直播间")
                    .font(.system(size: 13, weight: .medium))
                TextField(
                    "",
                    text: $account.manualRoomID,
                    prompt: Text(account.roomID.map { "留空就用你自己的直播间 \($0)" } ?? "填直播间号")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                Text("登录后会自动认出你自己的直播间。想发到别人的直播间就在这里填房间号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("表情系列")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("刷新") { Task { await account.refreshEmoticons() } }
                        .controlSize(.small)
                }
                if account.packs.isEmpty {
                    Text("登录后点刷新，会列出你拥有的表情包。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(account.packs) { pack in
                                Toggle(isOn: Binding(
                                    get: { !account.hiddenPackIDs.contains(pack.id) },
                                    set: { show in
                                        if show {
                                            account.hiddenPackIDs.remove(pack.id)
                                        } else {
                                            account.hiddenPackIDs.insert(pack.id)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(pack.name).font(.system(size: 12))
                                        Text("\(pack.items.count)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if !pack.liveRenderable {
                                            Text("只出文字")
                                                .font(.system(size: 9))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: 110)
                    Text("标「只出文字」的是评论区表情包，发到直播弹幕只会显示成 [xxx]，B 站不给渲染成图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text("登录凭证存在本机文件里（只有你能读），不上传任何地方。发送走 B 站官方接口，本地限速每秒最多一条，避免撞风控。收弹幕仍然走 blivechat 的只读接口，和这套登录无关。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 样式

private struct StyleTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("弹幕样式 CSS")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(copied ? "已复制" : "复制 OBS CSS") { copyCSS() }
                    .controlSize(.small)
                Button("恢复默认") { prefs.resetCSS() }
                    .controlSize(.small)
            }

            TextEditor(text: $prefs.customCSS)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )

            Text("改完自动生效。同一份粘进 OBS 浏览器源的「自定义 CSS」，两边就一模一样。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyCSS() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prefs.customCSS, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
