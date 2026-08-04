<p align="center">
  <img src="docs/images/logo.png" width="128" alt="Namonaki">
</p>

# 弹幕窗 Namonaki

macOS 上的 B 站直播弹幕悬浮窗。窗口和弹幕都是原生 AppKit 画的，鼠标不压在弹幕上时
窗口不接收事件、不挡后面的东西；右键弹幕可以直接回复，也能发表情。

写给主播自己看：OBS 那边把弹幕铺进画面是给观众看的，主播盯弹幕往往还得另开网页或者切窗口。

<p align="center">
  <img src="docs/images/hud.png" width="300" alt="桌面上的弹幕悬浮窗">
  &nbsp;&nbsp;
  <img src="docs/images/composer.png" width="420" alt="发送框和表情面板">
</p>

## 能做什么

- **悬浮窗看弹幕**：无边框、背景透明、可置顶，透明度和位置可调
- **平时不挡路**：只有鼠标压在某条弹幕上时窗口才接收事件，其余时候点击直接穿透过去
- **右键回复**：右键一条弹幕直接 @ 对方，左键仍然可以选中复制文字
- **发弹幕和表情**：⌥⌘D 唤出发送框，支持直播间表情和自己的装扮表情
- **三套样式预设**：字号 / 用户名不透明度 / 衬底浓度实时可调
- **和 OBS 共用一条连接**：App 只建一条 B 站连接，HUD 原生渲染，OBS 走本机 relay 的网页；
  调滑杆两边一起变，不用手动同步
- **冷启动不空白**：本地留最近 40 条，重开先铺回去

## 装 Namonaki

运行需要 macOS 14 或更新，编译需要 Xcode 16 或更新（Swift 6）：

```sh
git clone https://github.com/nagi-studio/namonaki.git && cd namonaki
./build.sh
open build/Namonaki.app
```

不需要 Python、uv，也不用另外起 blivechat。第一次打开会自动弹设置面板：

1. 去 https://play-live.bilibili.com/ 复制 12–14 位身份码。
2. 在「连接」里粘贴，点「保存并连接」。
3. OBS 需要弹幕时，点「复制 OBS 地址」，把本机 URL 设成浏览器源。

菜单栏会多一个气泡图标，功能都在那儿。两个全局快捷键：

- **⌥⌘E** 进出编辑模式（窗口显示边框，这时才能拖动和缩放）
- **⌥⌘D** 打开发送框

## 想发弹幕的话

设置 → 账号 → 登录 B 站，扫码即可。发送走 B 站官方接口，本地限速 1.2 秒一条，
再快会撞 B 站风控（错误码 `10031`）。

**收弹幕和发弹幕是两条独立的路**：收只认开放平台身份码，发才需要你的账号登录态。
不想发弹幕就完全不用登录。

## 连接与隐私

- App 把身份码通过 HTTPS 发给 `api1.blive.chat` / `api2.blive.chat`，换取 B 站开放平台会话。
  **这是 blivechat 项目维护的公共服务，既不是本项目的服务器，也不是 B 站官方的。**
- 这台公共服务器必然能看到来源 IP、身份码，以及会话的 room / game ID。按目前开源的服务端
  代码，格式正确但已过期或无效的身份码在返回 `7007` 时会写进服务端日志。App 会先做本地格式
  校验、也不对 `7007` 自动重试，但这只能少写几条，替第三方服务器承诺「什么都不记录」是做不到的。
- 弹幕内容由 App 直连 `broadcastlv.chat.bilibili.com` 收，不经过上面那台服务器。
  服务器返回的 WSS 地址有本地 allowlist，不会跟着跳到任意域名。
- HUD 和 OBS 只连本机 `127.0.0.1:12451`。OBS 地址里只带随机的本机令牌，不带身份码。
- 身份码和 B 站账号 Cookie（`SESSDATA` / `bili_jct`）都放在
  `~/Library/Application Support/Namonaki/credentials.json`，目录 0700、文件 0600，
  不进 UserDefaults、不进日志。**注意这是明文 JSON，只靠文件权限挡着，不是钥匙串**——
  钥匙串试过，但每次重新编译签名就变、系统当成另一个 app 反复要密码，只好退回文件。
- Cookie 只发给 B 站官方的发送接口。收到的弹幕内容和本机 OBS 令牌不会发给那台公共服务器。

## 已知限制

**表情**：直播间表情和装扮表情（图片路径 `/bfs/garb/`）能渲染成图；评论区的基础表情包
（小黄脸、热词那些，路径 `/bfs/emote/`）发进直播弹幕只会显示成 `[xxx]` 文字——这是 B 站的
限制，面板里给这类包打了「只出文字」标记。

**没有签名和公证**：`build.sh` 只做本地占位签名（ad-hoc），不涉及 Apple 开发者账号。
自己编译出来的直接能开；换成从别处下载的压缩包，macOS 会拦下来，要去
「系统设置 → 隐私与安全性」点「仍要打开」。

**只编译当前架构**：`build.sh` 的产物不是 universal binary，换一种 CPU 架构要重新编译。

**身份码等同密码**：设置页默认用密码框隐藏，点「显示」8 秒后自动收起，直播和截图时注意别露出来。

## 开发 OBS 渲染页

桌面弹幕窗是原生绘制的，不涉及网页。OBS 浏览器源用的是 `web/` 里的 Svelte 页，
产物已提交在 `Resources/Renderer`，普通编译不需要前端工具。改了 `web/` 才要重建
（用 **bun**，不要用 npm）：

```sh
cd web && bun install && bun run build
```

## 致谢

**[blivechat](https://github.com/xfgryujk/blivechat)**（作者 xfgryujk，MIT）。这个项目欠它最多，
而且不止是「参考过」：

- 开放平台那套协议怎么用，是照着它的实现读懂的；
- 早期版本直接内嵌了它的前端页面；
- 到今天为止，换取开放平台会话走的仍然是**它维护的公共服务** `api1.blive.chat` /
  `api2.blive.chat`。也就是说 Namonaki 每建立一次连接，都在用别人自费维护的服务器。

许可证全文见 [`Resources/ThirdPartyNotices.md`](Resources/ThirdPartyNotices.md)。

**[bilibili-API-collect](https://github.com/pskdje/bilibili-API-collect)** —— 发弹幕接口
（`msg/send`）的字段规格来源，文档在 `docs/live/danmaku.md`。原仓库已被清空，链接指向仍然存活的
fork。装扮表情要加 `upower_` 前缀这一条哪份文档里都没有，是自己抓官方请求补出来的。

弹幕收发依赖 B 站直播开放平台。本项目与 B 站、blivechat 均无关联，用出问题别去找他们。

截图里的表情包来自 B 站装扮，版权归原作者，仅用于说明功能。

## 许可证

MIT，见 [LICENSE](LICENSE)。
