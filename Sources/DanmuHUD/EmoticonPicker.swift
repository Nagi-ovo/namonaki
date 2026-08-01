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

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 8)]

    @State private var selectedPack: String?

    private var currentPack: BilibiliAccount.EmotePack? {
        account.packs.first { $0.id == selectedPack } ?? account.packs.first
    }

    var body: some View {
        if account.packs.isEmpty {
            legacyBody
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 包切换：横着滚，16 个包塞不下就滑
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(account.packs) { pack in
                            Button {
                                selectedPack = pack.id
                            } label: {
                                Text(pack.name)
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(pack.id == currentPack?.id
                                                  ? Color.accentColor.opacity(0.85)
                                                  : Color.secondary.opacity(0.12))
                                    )
                                    .foregroundStyle(pack.id == currentPack?.id ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }

                Divider()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(currentPack?.items ?? []) { emoticon in
                            Button {
                                guard !emoticon.locked else { return }
                                onPick(emoticon)
                            } label: {
                                cell(emoticon)
                            }
                            .buttonStyle(.plain)
                            .help(emoticon.descript)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 240)
            }
            .frame(width: 340)
        }
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
            .frame(width: 48, height: 48)
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
