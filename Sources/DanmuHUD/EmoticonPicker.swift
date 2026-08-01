import SwiftUI
import AppKit

/// 带内存缓存的图片。SwiftUI 的 AsyncImage 不缓存，popover 一关一开就重新请求，
/// 图片会闪空一下甚至加载不出来。
struct CachedImage: View {
    let url: String
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: url as NSString) {
            image = hit
            return
        }
        guard let link = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: link),
              let loaded = NSImage(data: data) else { return }
        Self.cache.setObject(loaded, forKey: url as NSString)
        image = loaded
    }
}

/// 直播间表情面板。表情是按直播间发的，换个房间列表就不一样。
struct EmoticonPicker: View {
    @ObservedObject private var account = BilibiliAccount.shared
    let onPick: (BilibiliAccount.Emoticon) -> Void

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    @State private var selectedPack: String?
    @State private var hovered: BilibiliAccount.Emoticon?

    private var currentPack: BilibiliAccount.EmotePack? {
        account.visiblePacks.first { $0.id == selectedPack } ?? account.visiblePacks.first
    }

    var body: some View {
        if account.visiblePacks.isEmpty {
            legacyBody
        } else {
            VStack(spacing: 0) {
                packTabs
                Divider()
                grid
                Divider()
                footer
            }
            // 必须钉死尺寸：popover 的大小由内容决定，不给约束的话
            // 网格会一路把它撑开，反而滚不动
            .frame(width: 420, height: 430)
        }
    }

    /// 用下拉而不是横向标签条：十几个系列排成一条根本拖不动
    private var packTabs: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(account.visiblePacks) { pack in
                    Button {
                        selectedPack = pack.id
                    } label: {
                        Text(pack.liveRenderable ? pack.name : "\(pack.name)（只出文字）")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentPack?.name ?? "选择表情系列")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let pack = currentPack, !pack.liveRenderable {
                Text("直播不出图")
                    .font(.system(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(currentPack?.items ?? []) { emoticon in
                    Button {
                        guard !emoticon.locked else { return }
                        onPick(emoticon)
                    } label: {
                        cell(emoticon)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hovered = hovering ? emoticon : (hovered == emoticon ? nil : hovered)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(hovered?.descript ?? currentPack.map { "\($0.name) · \($0.items.count) 个" } ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var legacyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if account.emoticons.isEmpty {
                VStack(spacing: 6) {
                    Text("没有可用表情")
                        .font(.system(size: 12, weight: .medium))
                    Text("表情按直播间发放，可能是还没加载完，或者这个直播间没开表情。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重新加载") {
                        Task { await account.refreshEmoticons() }
                    }
                    .controlSize(.small)
                }
                .frame(width: 260)
                .padding(20)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(account.emoticons) { emoticon in
                            Button {
                                guard !emoticon.locked else { return }
                                onPick(emoticon)
                            } label: {
                                cell(emoticon)
                            }
                            .buttonStyle(.plain)
                            .help(emoticon.locked ? "\(emoticon.descript)（未解锁）" : emoticon.descript)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 320, height: 260)
            }
        }
    }

    private func cell(_ emoticon: BilibiliAccount.Emoticon) -> some View {
        CachedImage(url: emoticon.url)
            .frame(width: 64, height: 64)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovered == emoticon ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        .opacity(emoticon.locked ? 0.3 : 1)
        .overlay(alignment: .bottomTrailing) {
            if emoticon.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
