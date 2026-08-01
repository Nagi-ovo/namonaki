import SwiftUI

/// 直播间表情面板。表情是按直播间发的，换个房间列表就不一样。
struct EmoticonPicker: View {
    @ObservedObject private var account = BilibiliAccount.shared
    let onPick: (BilibiliAccount.Emoticon) -> Void

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 8)]

    var body: some View {
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
        AsyncImage(url: URL(string: emoticon.url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            }
        }
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
