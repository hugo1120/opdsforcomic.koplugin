# opdsforcomic.koplugin

KOReader 的 OPDS 客户端插件，为漫画目录加上页面预加载与两级缓存。
An OPDS client plugin for KOReader, adding page prefetching and two-level caching for comic catalogs.

**语言 / Language:** [中文](#中文) · [English](#english)

---

<a id="中文"></a>

## 中文

Fork 自 KOReader 内置的 `opds.koplugin`，独立安装、独立配置，与它互不干扰——两者可以同时启用，各有各的菜单入口和配置文件。面向逐页流式的漫画目录（OPDS-PSE / Suwayomi 等）。

### 功能

**阅读**

- **预取与两级缓存**：翻页时提前抓取后续页，内存缓存 16 MB，磁盘缓存可选（默认关闭，上限 64 MB）；缓存按**源页**键控。
- **自动裁剪白边**（默认关闭）：用 96×96 采样网格估算内容边界，判定不确信时**原样返回、不裁**；四角检测背景色，黑底页不会被误裁。
- **三种显示模式**，长按 `Rotate` 打开面板：
  - **单页** / **双页**（左右并排）/ **拆页**（把跨页横图切回单页）。
  - **拆页**：解码后量一次宽高比，落在 1.15~2.1 之间认定为两页，按几何中点切半。`Go to` 与页码仍按源页号走，不必自己换算。
  - **旋转与双页联动**：横屏自动双页，竖屏自动单页。
  - **「从右到左」默认开启**（日式漫画读法）；左开本的书请在这里关掉。
- **阅读界面按钮**：`Scale`（适屏/原尺寸）、`Rotate`、`Go to`（预填当前页）、`Crop`、`Close`。**关闭只认按钮**——单指滑动关闭已禁用，避免误触直接退出整章。
- **离章补记一次阅读进度**：服务端只认「带 `updateProgress=true` 取一张图」，而缓存命中率高时真实请求很少、进度会停住，因此在关闭阅读界面时补发一次。

**入口**

- 菜单：`文件管理器 → 顶部扳手 → 搜索 → OPDS catalog (Comic)`
- 手势：`设置 → 手势 → 文件管理器` 搜 `OPDS Catalog (Comic)`
- **文件夹快捷方式**：在任意文件夹里放一个**空文件**，文件名随意、扩展名用 `.opdscomic`（例如 `OPDS for Comic.opdscomic`），**点它就直接进入 OPDS 界面**，不用每次走菜单。扩展名就是全部机制，文件内容不会被读取，改名也不会失效——名字只是你自己认它的标记。（没有做「生成快捷方式」的按钮：这件事每台设备只做一次，不值得在任何菜单里占一行。）

添加服务器时填 OPDS 地址，以 Suwayomi-Server 为例：`http://你的服务器:4567/api/opds/v1.2`。路径必须带全 `/api/opds/v1.2`；认证通常留空。

### 安装

1. 到 [Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases) 下载最新的 `opdsforcomic.koplugin.zip`
2. 解压，得到 `opdsforcomic.koplugin` 文件夹——**名字已经是对的，不用改**
3. 整个文件夹放进 KOReader 的 `plugins/` 目录：

   | 设备 | 路径 |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux 桌面 | `~/.config/koreader/plugins/` |

4. 完全退出 KOReader 再启动（插件只在启动时扫描）

从源码仓库下载的话，解压出的文件夹叫 `opdsforcomic.koplugin-main`，**要重命名为 `opdsforcomic.koplugin`**——KOReader 靠目录名识别插件。注意别多套一层（`opdsforcomic.koplugin/opdsforcomic.koplugin/main.lua` 是错的）。

### 许可

**AGPL-3.0**，全文见 [LICENSE](LICENSE)。这不是选择而是义务：本插件派生自 KOReader 内置的 `opds.koplugin`，而 KOReader 以 AGPL-3.0 授权，派生作品必须沿用。

> 每个版本的 Release 说明里有完整的设计取舍、实测数据与已知限制（[Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases)）。

---

<a id="english"></a>

## English

A fork of KOReader's bundled `opds.koplugin`, installed and configured separately — both can be enabled at once and each keeps its own menu entry and settings file. Built for paged comic catalogs (OPDS-PSE / Suwayomi and friends).

### Features

**Reading**

- **Prefetching and two-level caching**: the next pages are fetched ahead of the reader; 16 MB in RAM, an optional disk cache (off by default, 64 MB). Both are keyed by **source page**.
- **Automatic margin cropping** (off by default): a 96×96 sample grid estimates the content box and bails out to the page as it came whenever the verdict is not confident. The background colour is read from the corners, so a black-background page is not cropped away.
- **Three display modes**, from the panel behind a long press on `Rotate`:
  - **Single page** / **Two pages** (side by side) / **Split** (a landscape spread cut back into single pages).
  - **Split**: the aspect ratio is measured once after decoding, and 1.15–2.1 means two pages, cut at the geometric middle. `Go to` and the page counter stay in source pages, so nothing has to be converted by hand.
  - **Rotation and two-page travel together**: landscape opens two-page, portrait returns to single.
  - **Right to left is on by default** (manga reading order); turn it off for left-bound books.
- **Reading-view buttons**: `Scale`, `Rotate`, `Go to` (pre-filled with the current page), `Crop`, `Close`. **Closing is the button's job** — one-finger swipe-to-close is disabled, because on e-ink a drifting tap is indistinguishable from a short flick and a misread drops the whole chapter.
- **One progress report at chapter close**: the server's only per-page hook is "fetch an image with `updateProgress=true`", and a high cache hit rate means very few real requests, so recorded progress sits still. Closing the viewer sends one report.

**Getting in**

- Menu: `File manager → wrench icon → Search → OPDS catalog (Comic)`
- Gesture: `Settings → Gestures → File manager`, search for `OPDS Catalog (Comic)`
- **Folder shortcut**: put an **empty file** with a `.opdscomic` extension into any folder — the name is yours to choose (e.g. `OPDS for Comic.opdscomic`) — and **tapping it goes straight to the OPDS interface**, with no menu. The extension is the whole mechanism, the contents are never read, and renaming it does not break it: the name is just how you recognise it. (There is no "make a shortcut" button anywhere; this is done once per device and is not worth a row in a menu.)

For a server, enter its OPDS address; with Suwayomi-Server that is `http://your-server:4567/api/opds/v1.2`. The full `/api/opds/v1.2` is required; authentication can usually be left empty.

### Installation

1. Download the latest `opdsforcomic.koplugin.zip` from [Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases)
2. Unzip it — you get an `opdsforcomic.koplugin` folder, **already named correctly, no renaming needed**
3. Move the whole folder into KOReader's `plugins/` directory:

   | Device | Path |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux desktop | `~/.config/koreader/plugins/` |

4. Quit KOReader completely and start it again (plugins are only scanned at startup)

If you downloaded the source repository instead, the folder unpacks as `opdsforcomic.koplugin-main` and **must be renamed to `opdsforcomic.koplugin`** — KOReader identifies a plugin by its directory name. Do not nest an extra level (`opdsforcomic.koplugin/opdsforcomic.koplugin/main.lua` is wrong).

### License

**AGPL-3.0**, full text in [LICENSE](LICENSE). This is an obligation rather than a choice: the plugin derives from KOReader's bundled `opds.koplugin`, and KOReader is AGPL-3.0, which a derivative work must keep.

> Each release's notes carry the full design trade-offs, measurements and known limitations ([Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases)).
