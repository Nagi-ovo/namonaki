# Namonaki

macOS 菜单栏 app，在桌面上悬浮一个 B 站直播弹幕窗。AppKit 写窗口，内嵌 WKWebView
加载本地 blivechat 的房间页，样式靠注入 CSS 控制。

## 跑起来

```
./build.sh          # swift build + 组 .app + 本地签名，产物在 build/Namonaki.app
pkill -x Namonaki; open build/Namonaki.app    # 双击不会重启已在运行的实例，必须先杀
```

依赖 blivechat 服务器跑在 `127.0.0.1:12450`（源码在 `../blivechat`）：

```
cd ../blivechat && uv run main.py --host 127.0.0.1 --port 12450
```

blivechat 前端用 **bun** 编译，不要用 npm：`cd frontend && bun install && bun run build`。
被拦的两个 postinstall 都是 core-js 的赞助广告，忽略即可。

## 踩过的坑

**同一个身份码不能同时开多路直连。** OBS 浏览器源和这个窗口各连各的，B 站会踢掉
session，报「配置上限」和 `Ending Open Live session`。解法是走服务器转发：URL 参数
`relayMessagesByServer=true`（app 里已强制加上），blivechat 后端只占一个名额。
**OBS 那条 URL 得手动开这个开关。** 服务器上残留的旧 session 只能靠重启 blivechat 清掉。

**窗口拉不到屏幕顶部**，内置屏卡住、外接屏正常时，三件事缺一不可：override
`constrainFrameRect` 原样返回、窗口 level 高过菜单栏（`CGWindowLevelForKey(.statusWindow) + 1`）、
Info.plist 里 `NSPrefersDisplaySafeAreaCompatibilityMode = false`（关掉刘海安全区兼容模式，
否则系统会缩小屏幕可用区域）。

**存窗口位置要存 `window.frame`，恢复时也要用 `setFrame`**，别把它当 `contentRect`
传给 init，差一个标题栏的高度，每次启动往下掉一截。

**`LSUIElement` 的 app 默认没有主菜单**，Cmd+C/V 全都失效，输入框粘贴不了。必须自己建一份
最小的编辑菜单（见 `AppDelegate.setUpMainMenu`）。同理，菜单栏 app 平时不是激活状态，
所以 ⌘E 这类快捷键只在 app 激活时才响应，别指望它随时可用。

**头像加载不出来（破图）** 是 ATS 拦的：blivechat 把头像 URL 的协议去掉了
（`//i0.hdslb.com/…`），页面是 http，头像就按 http 请求。Info.plist 里放行
`NSAllowsArbitraryLoadsInWebContent`。OBS 用 CEF 没这个限制，所以那边一直是好的。

**WKWebView 会吃掉所有鼠标事件**，窗口就拖不动。靠一层透明的 `DragOverlay` 接管拖动，
滚轮再转发回 WebView。它的 `hitTest` 只在编辑模式返回自己。

**macOS 不看像素透不透明**——窗口整个矩形都算它的地盘。所以非编辑模式一律
`ignoresMouseEvents = true`，否则那一大片透明区域会挡住后面的东西。

## 身份码

在 https://play-live.bilibili.com/ 拿，12–14 位大写字母数字。**等同密码**，房间 URL 里
就带着它，日志和截图都要脱敏。刷新会让旧的立刻作废，换了之后 app 和 OBS 两边都要重新粘。

排查时不要 `defaults read fun.nagi.namonaki`——会把带身份码的 roomURL 整条打出来。

## 发弹幕

收弹幕走 blivechat 的开放平台接口，**只读**。发送必须用本人登录态，是另一套：
WebView 扫码登录 → 取 Cookie 里的 `SESSDATA` / `bili_jct` → 存钥匙串 →
`POST api.live.bilibili.com/msg/send`（form 编码，`csrf` 要等于 `bili_jct`）。
本地限速 1.2 秒一条，B 站的 `10031` 就是发太快。

接口规格出自 bilibili-API-collect，**原仓库已被清空**（只剩一张说明图），
参考还存活的 fork：`github.com/pskdje/bilibili-API-collect`，文档在 `docs/live/danmaku.md`。

## 样式

`DefaultStyle.css` 是基础样式表，顶部几个 CSS 变量（字号 / 用户名不透明度 / 头像大小 /
衬底浓度）由设置面板的滑杆覆盖。`StylePreset` 的三套预设共用这一份 CSS，只改变量和少量补丁。

改了内置样式记得给 `Preferences.currentCSSVersion` +1，否则老用户存在 UserDefaults 里的
旧 CSS 不会升级，新规则永远不生效。

样式在 HUD 窗口和 OBS 浏览器源之间共用，设置面板有「复制给 OBS」。设计取向是克制：
不用卡片、徽章色块、高饱和色，靠字重和透明度分层。
