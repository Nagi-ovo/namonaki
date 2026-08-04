import AppKit
import Testing
@testable import Namonaki

@MainActor
struct DanmakuRenderingTests {
    private static func author(
        _ name: String,
        type: Int = 0,
        privilege: Int = 0
    ) -> DanmakuAuthor {
        DanmakuAuthor(name: name, uid: name, type: type, privilegeType: privilege)
    }

    private static func text(
        _ content: String,
        by name: String = "观众",
        type: Int = 0,
        emoticon: String? = nil
    ) -> DanmakuMessage {
        .text(DanmakuMessage.Text(
            id: UUID().uuidString,
            author: author(name, type: type),
            content: content,
            emoticonURL: emoticon
        ))
    }

    private static let width: CGFloat = 380

    @Test func wrappedMessagesGetTallerRows() {
        let style = DanmakuStyle()
        let short = DanmakuMessageRow(message: Self.text("好"), style: style)
        let long = DanmakuMessageRow(
            message: Self.text(String(repeating: "这条弹幕很长", count: 12)),
            style: style
        )

        let shortHeight = short.fittingHeight(forWidth: Self.width)
        #expect(shortHeight > 0)
        #expect(long.fittingHeight(forWidth: Self.width) > shortHeight * 2)
    }

    @Test func rowIsNeverShorterThanItsAvatar() {
        var style = DanmakuStyle()
        style.fontSize = 40
        let row = DanmakuMessageRow(message: Self.text("短"), style: style)

        #expect(row.fittingHeight(forWidth: Self.width) >= style.avatarSize)
    }

    /// A full-image emote replaces the text, so the row has to grow to the image height
    /// even though the label is just the author name.
    @Test func fullImageEmoteRowsMakeRoomForTheImage() {
        let style = DanmakuStyle()
        let plain = DanmakuMessageRow(message: Self.text("[MyGO_哈？！]"), style: style)
        let emote = DanmakuMessageRow(
            message: Self.text(
                "[MyGO_哈？！]",
                emoticon: "https://i0.hdslb.com/bfs/garb/example.png"
            ),
            style: style
        )

        let height = emote.fittingHeight(forWidth: Self.width)
        #expect(height > plain.fittingHeight(forWidth: Self.width))
        #expect(height >= style.largeEmoticonHeight)
    }

    @Test func minimalPresetRemovesTheAvatarColumn() {
        var minimal = DanmakuStyle()
        minimal.showsAvatar = false
        minimal.verticalPadding = 3
        minimal.verticalMargin = 0

        let withAvatar = DanmakuMessageRow(message: Self.text("短"), style: DanmakuStyle())
        let withoutAvatar = DanmakuMessageRow(message: Self.text("短"), style: minimal)

        #expect(
            withoutAvatar.fittingHeight(forWidth: Self.width)
                < withAvatar.fittingHeight(forWidth: Self.width)
        )
    }

    /// History is written and read back by us, so the round trip has to survive every case.
    @Test func historySurvivesACodableRoundTrip() throws {
        let messages: [DanmakuMessage] = [
            Self.text("你好", by: "主播", type: 3),
            Self.text("[dokidoki]", emoticon: "https://i0.hdslb.com/bfs/garb/a.png"),
            .gift(DanmakuMessage.Gift(
                id: "g", author: Self.author("土豪"), giftName: "小心心", num: 3, totalCoin: 500
            )),
            .member(DanmakuMessage.Member(
                id: "m", author: Self.author("新舰长", privilege: 3), num: 1, unit: "月"
            )),
            .superChat(DanmakuMessage.SuperChat(
                id: "sc", author: Self.author("提问的人"), content: "问个问题", price: 30
            )),
        ]

        let data = try JSONEncoder().encode(messages)
        #expect(try JSONDecoder().decode([DanmakuMessage].self, from: data) == messages)
    }

    @Test func freeGiftsAndDeletionsAreNotWorthKeeping() {
        #expect(Self.text("你好").isWorthKeeping)
        #expect(!DanmakuMessage.deleteSuperChat(ids: ["1"]).isWorthKeeping)
        #expect(!DanmakuMessage.gift(DanmakuMessage.Gift(totalFreeCoin: 100)).isWorthKeeping)
        #expect(DanmakuMessage.gift(DanmakuMessage.Gift(totalCoin: 100)).isWorthKeeping)
    }

    /// Renders a sample feed to `preview.png` so the look can be checked without a live
    /// room. Off by default; run with `NAMONAKI_RENDER_PREVIEW=<path>` to produce it.
    @Test func rendersPreviewImageWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["NAMONAKI_RENDER_PREVIEW"] else {
            return
        }

        let style = DanmakuStyle()
        let messages: [DanmakuMessage] = [
            Self.text("大家晚上好啊", by: "路过的观众"),
            Self.text("这个配色好看", by: "房管甲", type: 2),
            Self.text("欢迎来到直播间，今天讲讲把 WebView 换成原生渲染这件事", by: "主播", type: 3),
            .member(DanmakuMessage.Member(
                id: "m", author: Self.author("新上舰的", privilege: 3), num: 1, unit: "月"
            )),
            Self.text("终于不用开着网页了", by: "老舰长", type: 1),
            .superChat(DanmakuMessage.SuperChat(
                id: "sc",
                author: Self.author("提问的人"),
                content: "原生渲染之后表情还能显示吗？",
                price: 30
            )),
            .gift(DanmakuMessage.Gift(
                id: "g", author: Self.author("土豪"), giftName: "小花花", num: 3, totalCoin: 500
            )),
        ]

        let rows = messages.map { DanmakuMessageRow(message: $0, style: style) }
        let width: CGFloat = 420
        var y: CGFloat = 0
        let container = FlippedView()
        for row in rows {
            let height = row.fittingHeight(forWidth: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            container.addSubview(row)
            y += height
        }
        container.frame = NSRect(x: 0, y: 0, width: width, height: y)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)

        // Composite over a mid-tone so the translucent backdrops and shadows are visible.
        let image = NSImage(size: container.bounds.size)
        image.lockFocus()
        NSColor(srgbRed: 0.36, green: 0.40, blue: 0.44, alpha: 1).setFill()
        NSBezierPath(rect: container.bounds).fill()
        rep.draw(in: container.bounds)
        image.unlockFocus()

        let flattened = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init))
        let png = try #require(flattened.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
