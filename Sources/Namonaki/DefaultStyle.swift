import Foundation

/// Optional custom CSS for the OBS browser source.
///
/// The bundled page (built from `web/`) already carries the full look, and the app pushes
/// the slider values to it live — nothing has to be pasted for OBS to match the HUD. This
/// sheet exists only for people who want to go further, so it ships as a documented
/// starting point rather than a copy of the stylesheet.
enum DefaultStyle {
    static let css = """
    /* Namonaki · OBS 浏览器源自定义样式
       ------------------------------------------------------------------
       这份是「额外覆盖」，不是完整样式表。页面自带默认外观，字号 / 用户名清晰度 /
       衬底浓度也会跟着 App 里的滑杆实时变，不用手动同步。
       想再改点什么，就在下面写；改完点「复制 OBS CSS」，粘进 OBS 浏览器源的
       「自定义 CSS」。

       可用的变量：
         --nmk-font-size        正文字号
         --nmk-name-opacity     用户名不透明度
         --nmk-backdrop-alpha   每条弹幕背后衬底的浓度（0 = 全透明）
         --nmk-avatar-size      头像直径
         --nmk-accent           主播 / 醒目留言 / 上舰用的强调色

       可用的选择器：
         .row                   一条消息
         .row--text             普通弹幕
         .row--superChat        醒目留言
         .row--member           上舰
         .row--gift             付费礼物
         .row--highlight        醒目留言和上舰共用的强调外观
         .avatar .name .colon .text .emote .gift-icon .price
         .status                连接状态提示
         :root[data-preset="minimal"]  极简预设下的额外规则
       ------------------------------------------------------------------ */

    /* 例：把弹幕靠底部对齐，上面留空
    .feed {
      display: flex;
      flex-direction: column;
      justify-content: flex-end;
    }
    */

    /* 例：去掉入场动画
    .row {
      animation: none;
    }
    */

    /* 例：换一个强调色
    :root {
      --nmk-accent: rgba(200, 170, 255, 0.95);
    }
    */
    """
}
