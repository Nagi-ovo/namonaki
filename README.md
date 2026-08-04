<p align="center">
  <img src="docs/images/logo.png" width="128" alt="Namonaki">
</p>

# 弹幕窗 Namonaki

开播的时候，弹幕飘在桌面上，鼠标碰不到它，不挡你手上的活。想回谁一句，右键那条弹幕。

OBS 那边把弹幕铺进画面是给观众看的。这个是给你自己看的。

<p align="center">
  <img src="docs/images/hud.png" width="300" alt="桌面上的弹幕悬浮窗">
  &nbsp;&nbsp;
  <img src="docs/images/composer.png" width="420" alt="发送框和表情面板">
</p>

## 能做什么

- 无边框、透明、可置顶，位置和透明度随便调
- 鼠标不压在弹幕上，点击直接穿过去，后面的窗口照样点
- 右键一条弹幕直接 @ 他，左键能选中复制
- ⌥⌘D 发弹幕，直播间表情和自己的装扮表情都能发
- 三套预设，字号、用户名深浅、衬底浓度随时拉
- OBS 也要弹幕的话共用同一条连接，拉滑杆两边一起变
- 关掉重开，最近 40 条还在

## 装

macOS 14 以上。去 [Releases](https://github.com/nagi-studio/namonaki/releases) 下载，
Apple Silicon 拿 arm64 那个，Intel 或者不确定拿 universal。

**第一次打开会被拦。** 这个包没有 Apple 开发者签名，去「系统设置 → 隐私与安全性」点「仍要打开」。

自己编译也行，要 Xcode 16：

```sh
git clone https://github.com/nagi-studio/namonaki.git && cd namonaki
./build.sh && open build/Namonaki.app
```

菜单栏会多一个气泡图标。第一次启动自动弹设置面板，去
https://play-live.bilibili.com/ 复制身份码粘进去，点「保存并连接」就完事了。

两个快捷键：**⌥⌘E** 进出编辑模式（这时才能拖窗口和缩放），**⌥⌘D** 发弹幕。

OBS 要用的话，设置页点「复制 OBS 地址」，粘进浏览器源。

## 发弹幕要登录

收弹幕只认身份码，发弹幕得用你自己的账号：设置 → 账号 → 扫码登录。
本地限速 1.2 秒一条，再快 B 站会拦（错误码 `10031`）。

不想发就不用登录，两条路互不影响。

## 身份码和隐私

三件事你该知道：

1. 身份码换会话走的是 `api1.blive.chat`，那是 **blivechat 的公共服务器**，不是我的，也不是 B 站官方的。
   它能看到你的 IP 和身份码。身份码错的时候（`7007`）服务端会记一笔，所以 App 本地先校验格式、也不自动重试。
2. 弹幕内容不经过它。App 直连 `broadcastlv.chat.bilibili.com` 收，OBS 那条也只走本机 `127.0.0.1:12451`。
3. 身份码和登录 Cookie 存在 `~/Library/Application Support/Namonaki/credentials.json`，权限 0600。
   是明文 JSON，不是钥匙串——够本机自用，但别当保险箱。

身份码等同密码，直播和截图别露出来。

## 已知限制

装扮表情（`/bfs/garb/`）在直播里能显示成图，评论区那些基础表情包（小黄脸、热词，`/bfs/emote/`）
只会显示成 `[xxx]` 文字。B 站的限制，面板里给这类包标了「只出文字」。

## 改 OBS 那个页面

桌面弹幕窗是原生画的，不涉及网页。OBS 用的是 `web/` 里的 Svelte 页，产物已经提交在
`Resources/Renderer`，所以普通编译不用装前端工具。改了 `web/` 才要重建，用 bun：

```sh
cd web && bun install && bun run build
```

## 致谢

**[blivechat](https://github.com/xfgryujk/blivechat)**（xfgryujk，MIT）。开放平台协议怎么用，
是照着它的实现读懂的；早期版本直接内嵌过它的前端。现在渲染页自己写了，但换会话还是走它的公共服务
`api1.blive.chat` / `api2.blive.chat`——别人自费在跑的服务器。许可证全文在
[`Resources/ThirdPartyNotices.md`](Resources/ThirdPartyNotices.md)。

**[bilibili-API-collect](https://github.com/pskdje/bilibili-API-collect)**。发弹幕接口的字段规格出自这里
（`docs/live/danmaku.md`）。原仓库已经被清空，上面这个链接是还活着的 fork。装扮表情要加 `upower_`
前缀那条哪儿都没写，是自己抓包抓出来的。

本项目跟 B 站、blivechat 都没关系，用出问题别去找他们。截图里的表情包版权归原作者。

## 许可证

MIT，见 [LICENSE](LICENSE)。
