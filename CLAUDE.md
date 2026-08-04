# Namonaki

macOS 菜单栏 app，在桌面上悬浮一个 B 站直播弹幕窗。AppKit 写窗口，内嵌 WKWebView
加载本地 blivechat 的房间页，样式靠注入 CSS 控制。

## 跑起来

```
./build.sh          # swift build + 组 .app + 本地签名，产物在 build/Namonaki.app
pkill -x Namonaki; open build/Namonaki.app    # 双击不会重启已在运行的实例，必须先杀
```

不再依赖 Python / uv 进程。App 自己在 `127.0.0.1:12451` 提供内置渲染页
和 WebSocket relay。`Resources/Renderer` 是随 app 打包的 blivechat 前端产物。

只在修改 `../blivechat/frontend` 时用 **bun** 重建，不要用 npm：

```
cd ../blivechat/frontend
PROD_SOURCE_MAP=false bun run build
rsync -a --delete dist/ ../../namonaki/Resources/Renderer/
```

被拦的两个 postinstall 都是 core-js 的赞助广告，忽略即可。

## 踩过的坑

**同一个身份码不能同时开多路直连。** `OpenLiveRuntime` 维护唯一上游，
HUD 和 OBS 都从 `LocalRelayServer` 收消息。OBS 必须用设置页「复制 OBS 地址」生成的
`127.0.0.1:12451` URL，不要再用旧 blivechat 房间 URL。切换过来前先停掉旧 Python
blivechat，否则它残留的开放平台 session 仍会占名额。

**收弹幕的网络边界是硬编码 allowlist。** 身份码只能 POST 到
`https://api1.blive.chat` / `api2.blive.chat` 的 start / heartbeat / end 三个路径；
WSS 只允许 `wss://broadcastlv.chat.bilibili.com:443/sub`。不要放宽为任意 URL。
公共服务端代码会在 `7007` 时记录格式正确但无效的身份码，所以必须保留本地格式校验，
且不能对 `7007` 自动重试。不要宣称第三方服务器“什么都不记录”。

**窗口拉不到屏幕顶部**，内置屏卡住、外接屏正常时，三件事缺一不可：override
`constrainFrameRect` 原样返回、窗口 level 高过菜单栏（`CGWindowLevelForKey(.statusWindow) + 1`）、
Info.plist 里 `NSPrefersDisplaySafeAreaCompatibilityMode = false`（关掉刘海安全区兼容模式，
否则系统会缩小屏幕可用区域）。

**存窗口位置要存 `window.frame`，恢复时也要用 `setFrame`**，别把它当 `contentRect`
传给 init，差一个标题栏的高度，每次启动往下掉一截。

**`LSUIElement` 的 app 默认没有主菜单**，Cmd+C/V 全都失效，输入框粘贴不了。必须自己建一份
最小的编辑菜单（见 `AppDelegate.setUpMainMenu`）。同理，菜单栏 app 平时不是激活状态，
所以 ⌘E 这类快捷键只在 app 激活时才响应，别指望它随时可用。

**头像 URL 必须在 Swift 映射层统一改成 HTTPS。** B 站会给
`//i0.hdslb.com/…` 或 `http://…`；`OpenLiveEventMapper.secureURL` 负责升级。不要重新打开
`NSAllowsArbitraryLoadsInWebContent`，内置页 CSP 也只放行 B 站图片域名。

**blivechat 页面上有两个 `id="items"`**——`Ticker.vue`（顶部付费滚动条）一个，
`ChatRenderer/index.vue`（真正的弹幕容器）一个，而 Ticker 在 DOM 顺序上排在前面。
所以 `document.querySelector('#items')` 拿到的一直是 Ticker 那个。注入的 JS 和 CSS
凡是要选弹幕容器，**必须写成 `#item-offset #items`**。blivechat 自己用 Vue 的 ref，
不受影响，坏的只有我们注入的部分——这个坑一次报废了三轮修复。

同理，存历史 HTML 前要把节点里的 `id` 剥掉，否则铺回页面后又制造一批同 id 元素。

**WKWebView 会吃掉所有鼠标事件**，窗口就拖不动。靠一层透明的 `DragOverlay` 接管拖动，
滚轮再转发回 WebView。它的 `hitTest` 只在编辑模式返回自己。

**macOS 不看像素透不透明**——窗口整个矩形都算它的地盘。所以非编辑模式一律
`ignoresMouseEvents = true`，否则那一大片透明区域会挡住后面的东西。

## 身份码

在 https://play-live.bilibili.com/ 拿，12–14 位大写字母数字。**等同密码**，
日志和截图都要脱敏。它只存在本机 `credentials.json`（0600），不存 UserDefaults；
旧版 `roomURL` 会在首次启动时拆出身份码后删除。刷新身份码后只需在 app 里重新粘贴，
OBS 的本机 URL 不需改。

## 发弹幕

收弹幕走 blivechat 的开放平台接口，**只读**。发送必须用本人登录态，是另一套：
WebView 扫码登录 → 取 Cookie 里的 `SESSDATA` / `bili_jct` → 存钥匙串 →
`POST api.live.bilibili.com/msg/send`（form 编码，`csrf` 要等于 `bili_jct`）。
本地限速 1.2 秒一条，B 站的 `10031` 就是发太快。

接口规格出自 bilibili-API-collect，**原仓库已被清空**（只剩一张说明图），
参考还存活的 fork：`github.com/pskdje/bilibili-API-collect`，文档在 `docs/live/danmaku.md`。

**装扮表情要加 `upower_` 前缀**，这条任何文档里都没有，是抓官方请求抓出来的：
`msg=upower_[MyGO_哈？！]` + `dm_type=1` + `emoticonOptions=[object Object]`
（官方前端自己把对象拼错成了这个字面量，值不重要，缺了才是问题）+
`data_extend={"trackid":"-99998"}`。少任何一样服务端都只当纯文本，显示成 `[xxx]`。

表情分两类，靠图片路径区分：`/bfs/garb/` 是装扮表情，直播能渲染成图；
`/bfs/emote/` 是评论区基础表情（小黄脸、热词系列），直播只显示文字，这是 B 站的限制。

抓包方法：浏览器扩展的网络面板抓不到这条 POST，得在页面里 hook
`XMLHttpRequest.prototype.send` 和 `window.fetch` 才拿得到。

## 样式

`DefaultStyle.css` 是基础样式表，顶部几个 CSS 变量（字号 / 用户名不透明度 / 头像大小 /
衬底浓度）由设置面板的滑杆覆盖。`StylePreset` 的三套预设共用这一份 CSS，只改变量和少量补丁。

改了内置样式记得给 `Preferences.currentCSSVersion` +1，否则老用户存在 UserDefaults 里的
旧 CSS 不会升级，新规则永远不生效。

样式在 HUD 窗口和 OBS 浏览器源之间共用，设置面板有「复制给 OBS」。设计取向是克制：
不用卡片、徽章色块、高饱和色，靠字重和透明度分层。
