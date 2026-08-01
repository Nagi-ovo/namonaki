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
    @State private var revealed = false
    @State private var hint: String?

    private var isSet: Bool {
        !prefs.roomURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSet ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(isSet ? "房间已设置" : "还没设置房间")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            // 地址里带身份码，直播时可能被拍到，所以默认只显示到主机名
            Group {
                if revealed {
                    TextField("", text: $prefs.roomURL, prompt: Text("http://127.0.0.1:12450/room/…"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    Text(maskedDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.08))
                        )
                }
            }

            HStack(spacing: 8) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button(revealed ? "隐藏" : "临时显示") {
                    toggleReveal()
                }
                .disabled(!isSet && !revealed)

                Spacer()

                Button("清除") {
                    prefs.roomURL = ""
                    revealed = false
                    hint = nil
                }
                .disabled(!isSet)
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hint.hasPrefix("✓") ? Color.green : Color.orange)
            }

            Divider()

            Toggle(isOn: $prefs.showDebugMessages) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示连接状态消息")
                    Text("Connecting / Disconnected 那些提示。平时关掉画面更干净，排查掉线时再打开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("怎么拿地址")
                    .font(.system(size: 12, weight: .medium))
                Text("打开 blivechat 页面 → 填身份码 → 点「复制房间URL」→ 回来点上面的粘贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开 blivechat 页面") {
                    if let url = URL(string: "http://127.0.0.1:12450") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer()

            Text("地址里含身份码，等同密码。默认隐藏，「临时显示」8 秒后自动收起。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { revealed = false }
    }

    private var maskedDescription: String {
        let raw = prefs.roomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "—" }
        guard let url = URL(string: raw), let host = url.host else { return "••••••••" }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "http")://\(host)\(port)/room/••••••••••"
    }

    private func pasteFromClipboard() {
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hint = "剪贴板是空的"
            return
        }
        guard let url = URL(string: text), url.scheme != nil, url.host != nil else {
            hint = "剪贴板里不像是个网址"
            return
        }
        prefs.roomURL = text
        revealed = false
        hint = url.path.contains("/room/") ? "✓ 已设置，弹幕窗正在重新加载" : "✓ 已设置（注意：这不像房间地址）"
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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("头像大小")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(prefs.avatarSize))px")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $prefs.avatarSize, in: 16...48, step: 1)
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
                Button(copied ? "已复制" : "复制给 OBS") { copyCSS() }
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
