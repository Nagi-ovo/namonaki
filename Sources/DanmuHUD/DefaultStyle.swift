import Foundation

/// 默认弹幕样式。这份 CSS 在 HUD 窗口和 OBS 浏览器源里通用，
/// 改一处两边都变。设计取向是克制：无卡片、无描边徽章、无高饱和色，
/// 只靠字重、透明度和一条细竖线拉开层次。
///
/// 顶部几个 CSS 变量对应设置面板里的滑杆，滑杆会覆盖这里的默认值。
enum DefaultStyle {
    static let css = """
    :root {
      --blc-font-size: 21px;
      --blc-name-opacity: 0.75;
      --blc-avatar-size: 26px;
      --blc-backdrop-alpha: 0.38;
    }

    /* ---------- 画布 ---------- */
    html, body,
    yt-live-chat-renderer,
    yt-live-chat-item-list-renderer,
    #item-scroller,
    #items {
      background: transparent !important;
    }
    body {
      margin: 0 !important;
      overflow: hidden !important;
      font-family: "PingFang SC", -apple-system, BlinkMacSystemFont,
                   "Helvetica Neue", "Hiragino Sans GB", sans-serif !important;
      -webkit-font-smoothing: antialiased;
    }
    ::-webkit-scrollbar { display: none !important; }

    /* ---------- 单条弹幕 ---------- */
    /* 衬底：浅色画面上光靠文字阴影读不清，垫一层深色才稳。
       叠在深色游戏画面上时，把设置里的浓度拖到 0 就完全透明。 */
    yt-live-chat-text-message-renderer {
      display: flex !important;
      align-items: flex-start !important;
      padding: 7px 12px !important;
      margin: 3px 8px !important;
      border-radius: 9px !important;
      background: rgba(12, 12, 14, var(--blc-backdrop-alpha)) !important;
      backdrop-filter: blur(2px);
      animation: blc-in 260ms cubic-bezier(0.22, 0.61, 0.36, 1) both;
    }
    @keyframes blc-in {
      from { opacity: 0; transform: translateY(6px); }
      to   { opacity: 1; transform: none; }
    }

    #timestamp { display: none !important; }

    /* 头像和第一行文字视觉对齐，靠 flex 而不是行内对齐 */
    #author-photo {
      flex: 0 0 auto !important;
      width: var(--blc-avatar-size) !important;
      height: var(--blc-avatar-size) !important;
      margin: 2px 10px 0 0 !important;
      border-radius: 50% !important;
      overflow: hidden !important;
    }
    #author-photo img {
      width: 100% !important;
      height: 100% !important;
      border-radius: 50% !important;
      object-fit: cover !important;
      display: block !important;
    }

    #content {
      flex: 1 1 auto !important;
      min-width: 0 !important;
      line-height: 1.5 !important;
      /* 亮画面上也读得清，但阴影要收着点，糊了反而更难认 */
      text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
    }

    #author-name {
      font-size: calc(var(--blc-font-size) - 2px) !important;
      font-weight: 500 !important;
      color: rgba(255, 255, 255, var(--blc-name-opacity)) !important;
      margin-right: 9px !important;
    }
    #author-name::after { content: none !important; }

    #message {
      font-size: var(--blc-font-size) !important;
      font-weight: 400 !important;
      color: rgba(255, 255, 255, 0.97) !important;
      letter-spacing: 0.01em;
    }

    /* 徽章一律隐藏，身份改用文字颜色表达 */
    #chat-badges,
    yt-live-chat-author-badge-renderer { display: none !important; }

    /* ---------- 身份：只换色，不加块 ---------- */
    yt-live-chat-text-message-renderer[author-type="owner"] #author-name {
      color: rgba(235, 197, 133, 0.95) !important;
    }
    yt-live-chat-text-message-renderer[author-type="moderator"] #author-name {
      color: rgba(145, 187, 222, 0.95) !important;
    }
    yt-live-chat-text-message-renderer[blc-guard-level="1"] #author-name,
    yt-live-chat-text-message-renderer[blc-guard-level="2"] #author-name,
    yt-live-chat-text-message-renderer[blc-guard-level="3"] #author-name {
      color: rgba(160, 205, 198, 0.95) !important;
    }

    /* ---------- 表情 ---------- */
    .emoji {
      width: calc(var(--blc-font-size) + 1px) !important;
      height: calc(var(--blc-font-size) + 1px) !important;
      vertical-align: -4px !important;
      margin: 0 2px !important;
    }
    .blc-large-emoji {
      width: 64px !important;
      height: 64px !important;
      vertical-align: middle !important;
    }

    /* ---------- 醒目留言 / 上舰 ---------- */
    yt-live-chat-paid-message-renderer,
    yt-live-chat-membership-item-renderer {
      margin: 8px 14px !important;
      padding: 10px 12px !important;
      border: none !important;
      border-left: 2px solid rgba(235, 197, 133, 0.75) !important;
      border-radius: 2px !important;
      background: rgba(255, 255, 255, 0.06) !important;
      box-shadow: none !important;
      animation: blc-in 300ms cubic-bezier(0.22, 0.61, 0.36, 1) both;
    }
    yt-live-chat-paid-message-renderer #header,
    yt-live-chat-membership-item-renderer #header {
      background: transparent !important;
      padding: 0 !important;
    }
    yt-live-chat-paid-message-renderer #content,
    yt-live-chat-membership-item-renderer #content {
      background: transparent !important;
      padding: 4px 0 0 0 !important;
    }
    yt-live-chat-paid-message-renderer #author-name,
    yt-live-chat-membership-item-renderer #author-name {
      color: rgba(235, 197, 133, 0.95) !important;
      font-weight: 500 !important;
    }
    yt-live-chat-paid-message-renderer #purchase-amount,
    yt-live-chat-paid-message-renderer #purchase-amount-chip {
      color: rgba(255, 255, 255, 0.78) !important;
      font-size: calc(var(--blc-font-size) - 4px) !important;
      font-weight: 400 !important;
      background: transparent !important;
      padding: 0 !important;
    }

    /* 顶部滚动的付费条：默认不显示，需要就删掉这段 */
    yt-live-chat-ticker-renderer { display: none !important; }
    """
}
