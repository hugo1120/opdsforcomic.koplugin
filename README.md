# opdsforcomic.koplugin

KOReader 的漫画 OPDS 客户端：在线看漫画，带页面预取、两级缓存、自动裁剪、双页与拆页。
An OPDS client for KOReader: read comics from a server, with page prefetching, two-level caching, auto crop, two-page and split modes.

**语言 / Language:** [中文](#中文) · [English](#english)

---

<a id="screenshots"></a>

### 实机截图 · Screenshots

<table>
<tr>
<td width="50%"><a href="示范截图/screenshot_20260917_141119.png"><img src="示范截图/screenshot_20260917_141119.png" width="440" alt="Kobo 实机截图 1"></a></td>
<td width="50%"><a href="示范截图/screenshot_20260917_141125.png"><img src="示范截图/screenshot_20260917_141125.png" width="440" alt="Kobo 实机截图 2"></a></td>
</tr>
<tr>
<td width="50%"><a href="示范截图/screenshot_20260917_141133.png"><img src="示范截图/screenshot_20260917_141133.png" width="440" alt="Kobo 实机截图 3"></a></td>
<td width="50%"><a href="示范截图/screenshot_20260917_141140.png"><img src="示范截图/screenshot_20260917_141140.png" width="440" alt="Kobo 实机截图 4"></a></td>
</tr>
</table>

Kobo 墨水屏实机，点图看原图 · on a Kobo, tap an image for the full size.

---

<a id="中文"></a>

## 中文

### 这是什么

从 OPDS 服务器（Suwayomi、Komga 等，部署方式见文末[服务端](#服务端)）直接看漫画，不用先下载到本地。派生自 KOReader 内置的 `opds.koplugin`，两者可同时启用。

- **翻页不看转圈**：提前抓取后续页，内存缓存 16 MB，可选磁盘缓存（默认关，上限 64 MB）。
- **自动去掉白边**（默认关）。
- **三种显示方式**：单页 / 双页 / 拆页。拆页能把一张横着的跨页扫描切成两页分别看。
- **文件夹快捷方式**：在文件夹里点一下就进 OPDS，不用走菜单。

### 安装

1. 到 [Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases) 下载 `opdsforcomic.koplugin.zip`
2. 解压，得到 `opdsforcomic.koplugin` 文件夹（名字已正确，不用改名）
3. 整个文件夹放进 KOReader 的 `plugins/` 目录：

   | 设备 | 路径 |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux 桌面 | `~/.config/koreader/plugins/` |

4. 完全退出 KOReader 再启动

> 从源码仓库（`Code → Download ZIP`）下载的话，解压出的文件夹叫 `opdsforcomic.koplugin-main`，要重命名为 `opdsforcomic.koplugin`——KOReader 靠目录名识别插件。

### 第一次使用

```
① 填服务器地址  →  ② 建一个快捷方式  →  ③ 点它，挑一部开始看
```

#### ① 填服务器地址

```
文件管理器  →  顶部「扳手」图标  →  搜索标签  →  OPDS catalog (Comic)
```

进去后点左上角菜单，选 `Add catalog`：

```
┌────────────────────────────────────────┐
│  Add OPDS catalog                      │
├────────────────────────────────────────┤
│  Title      [ My Server            ]   │
│  URL        [ http://192.168.1.5:4567  │
│               /api/opds/v1.2       ]   │
│  Username   [                      ]   │
│  Password   [                      ]   │
├────────────────────────────────────────┤
│  [ Cancel ]                [ Save ]    │
└────────────────────────────────────────┘
```

**地址格式取决于你用的服务器，两者不一样**（假设服务器在 `192.168.1.5`）：

| 服务器 | 地址 | 默认端口 |
|---|---|---|
| **Suwayomi** | `http://192.168.1.5:4567/api/opds/v1.2` | 4567 |
| **Komga** | `http://192.168.1.5:25600/opds/v1.2/catalog` | 25600 |

两个都要注意：

- **结尾不能少写**。Suwayomi 要带 `/api/opds/v1.2`（只写到 `/api/opds` 或 `/opds` 返回 404）；Komga 要带 `/opds/v1.2/catalog`（`/catalog` 是路径的一部分）。
- **Komga 必须用 `v1.2`，不要用 `v2`。** Komga 也提供 `/opds/v2/catalog`，但 KOReader 在 v2 下不支持页流：Komga 官方兼容表里，v2 那一行 KOReader 的「流式传输」是否，v1.2 那一行才是是。本插件的预取和逐页加载依赖页流，填 v2 就退化成整本下载。
- 用户名密码按服务器实际情况填：**Komga 用你的 Komga 账号**（它的 OPDS 走 Basic Auth，没有账号就留空）；**Suwayomi** 只在服务端开了登录保护（`AUTH_MODE=basic_auth`）时才需要填。

#### ② 建一个快捷方式

在**任意**文件夹里放一个**空文件**，把扩展名改成 `.opdscomic`：

```
/mnt/onboard/comics/              ← 你平时的漫画文件夹
├── OPDS for Comic.opdscomic      ← 新建一个空文件，改成这个名字
├── Vol.01.cbz
└── Vol.02.cbz
```

- 内容留空即可，写什么都不会被读取。
- 文件名随你改（`快捷方式.opdscomic`、`看漫画.opdscomic` 都行），**扩展名必须是 `.opdscomic`**。
- 想放几个、放在哪一层都可以。

#### ③ 点它

回到文件管理器，那个文件就在列表里，和其它文件一样。**点它直接进 OPDS 界面**：

```
┌──────────────────────────────────────────┐
│  /mnt/onboard/comics                     │
├──────────────────────────────────────────┤
│  OPDS for Comic.opdscomic            0 B │   ← 点这一行
│  Vol.01.cbz                       3.2 MB │
│  Vol.02.cbz                       3.1 MB │
└──────────────────────────────────────────┘
                    │
                    ↓
┌──────────────────────────────────────────┐
│  菜单  OPDS catalog (Comic)              │
├──────────────────────────────────────────┤
│  Downloads                               │
│  My Server                               │
│    Ongoing                               │
│    Completed                             │
└──────────────────────────────────────────┘
```

### 阅读界面

点击屏幕**中间三分之一**唤出底部**图标工具栏**（和 KOReader 自带阅读界面一样的风格），从左到右：**适屏 / 旋转 / 跳页 / 裁剪 / 明暗 / 关闭**。

```
┌──────────────────────────────────────────┐
│                                          │
│              漫 画 页 面                 │
│                                          │
├──────────────────────────────────────────┤
│      底部一行是图标按钮                  │
└──────────────────────────────────────────┘
```

「明暗」：扫描发白或太暗时调它，认准原样 **1.0**：

| 档位 | 0.5 ~ 0.9 | 1.0 | 2 ~ 10 |
|---|---|---|---|
| 步长 | 0.1 | — | 1.0 |
| 效果 | 提亮 | 原样 | 加深 |

提亮很敏感，0.1 一档才够用；加深很不敏感——白底 240 在 2.0 档只到 226、4.0 档才到 200，墨水屏上看不出来，所以上面这半跨度大、一直开到 10。JPEG / PNG / GIF / WebP / SVG 都支持。

### 显示方式面板

**长按 `Rotate`** 打开：

```
┌────────────────────────────────┐
│  Rotate 90                     │
│  Two pages                     │  ← 左右两页并排
│  Split two-page scans        ✓ │  ← 把跨页横图切回单页
│  Right to left               ✓ │  ← 日式漫画读法
│  First page is cover           │  ← 第 1 页单独一屏
└────────────────────────────────┘
```

三种显示方式（单页 / 双页 / 拆页）**互斥**，开一个会自动关掉另一个。

**双页**：左右并排显示两页。转到横屏会自动打开，转回竖屏自动恢复单页。

**拆页**：有些资源把跨页存成**一张横图**。直接看字太小，开双页又变成四页一屏。打开拆页后，每张图会量一次宽高比，判断是「两页并排」就按中线切开：

```
     一张横图里有两页                     开启拆页后
┌────────────┬────────────┐      ┌──────────┐ ┌──────────┐
│            │            │      │          │ │          │
│   page 1   │   page 2   │  →   │  page 1  │ │  page 2  │
│            │            │      │          │ │          │
└────────────┴────────────┘      └──────────┘ └──────────┘
      一屏两页，字太小                   各占一屏，看得清
```

`Go to` 和页码仍按服务器的原始页号显示，不需要自己换算。

> 已知短板：扫描时就转了 90° 的**单页**也是横的，会被切开。本地没有任何信息能把它和跨页区分开，遇到就只能关掉这个开关。

### 常见问题

**「从右到左」为什么默认开启？**
这是漫画插件，日式漫画从右往左读。左开本的书在显示面板里关掉。

**磁盘缓存要不要开？**
默认关闭。开着能减少重新下载，代价是占存储空间（上限 64 MB）。

**关闭阅读界面后，服务器上的进度为什么变了？**
缓存命中率高时真实请求很少，服务器记的进度会停住，所以关闭时会补发一次进度。

### 服务端

本插件是客户端，需要你自己有一个 OPDS 服务器。以下两个都经过实机验证。

#### Suwayomi

[github.com/Suwayomi/Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) —— 桌面版漫画服务器（Tachiyomi/Mihon 的重写），带内置扩展商店，可以直接在里面装图源。

Docker 部署（官方 compose 示例见 [docker-tachidesk](https://github.com/Suwayomi/docker-tachidesk)）：

```bash
docker run -d --name suwayomi \
  -p 4567:4567 \
  -v /path/to/data:/home/suwayomi/.local/share/Tachidesk \
  ghcr.io/suwayomi/suwayomi-server:preview
```

装完后浏览器打开 `http://<主机>:4567` 完成初始化、装图源。插件里填 `http://<主机>:4567/api/opds/v1.2`。

#### Komga

[github.com/gotson/komga](https://github.com/gotson/komga) —— 面向漫画/杂志/电子书的媒体服务器，扫描你**已有的**文件目录（不联网抓取），支持 OPDS、Kobo Sync、KOReader Sync。官网 [komga.org](https://komga.org)。

Docker 部署（完整说明见 [komga.org/docs/installation/docker](https://komga.org/docs/installation/docker)）：

```bash
docker run -d --name komga \
  --user 1000:1000 \
  -p 25600:25600 \
  -v /path/to/config:/config \
  -v /path/to/data:/data \
  --restart unless-stopped \
  gotson/komga
```

`--user 1000:1000` 用你宿主机的 `id <用户名>` 结果替换，否则挂载目录会出现权限问题。`/data` 选一个同时放书和导入位置的文件夹。装完后浏览器打开 `http://<主机>:25600`，新建一个库指向你的漫画目录。插件里填 `http://<主机>:25600/opds/v1.2/catalog`。

> 两者取向不同：**Suwayomi** 自带图源、能在线抓取更新，适合追连载；**Komga** 只管你本地已有的文件，元数据和阅读进度管理更细。

### 许可

**AGPL-3.0**，全文见 [LICENSE](LICENSE)。本插件派生自 KOReader 内置的 `opds.koplugin`（AGPL-3.0）。

每个版本的 [Release 说明](https://github.com/hugo1120/opdsforcomic.koplugin/releases) 里有改动清单与已知限制。

---

<a id="english"></a>

## English

### What this is

Read comics straight from an OPDS server (Suwayomi, Komga, … — see [the server side](#the-server-side) at the end) without downloading them first. A fork of KOReader's bundled `opds.koplugin`; both can be enabled at once.

- **No spinner between pages**: the next pages are fetched ahead of you — 16 MB in RAM, plus an optional disk cache (off by default, 64 MB).
- **Automatic margin cropping** (off by default).
- **Three display modes**: single page / two pages / split, the last cutting a landscape spread scan back into two pages.
- **Folder shortcut**: one tap in a folder opens the catalog, no menu needed.

### Installation

1. Download `opdsforcomic.koplugin.zip` from [Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases)
2. Unzip it — you get an `opdsforcomic.koplugin` folder (already named correctly)
3. Move the whole folder into KOReader's `plugins/` directory:

   | Device | Path |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux desktop | `~/.config/koreader/plugins/` |

4. Quit KOReader completely and start it again

> If you downloaded the source repository instead (`Code → Download ZIP`), the folder unpacks as `opdsforcomic.koplugin-main` and must be renamed to `opdsforcomic.koplugin` — KOReader identifies a plugin by its directory name.

### Getting started

```
① Enter a server  →  ② Make a shortcut  →  ③ Tap it, pick something to read
```

#### ① Enter a server

```
File manager  →  wrench icon (top bar)  →  Search tab  →  OPDS catalog (Comic)
```

Open the menu at the top left, then `Add catalog`:

```
┌────────────────────────────────────────┐
│  Add OPDS catalog                      │
├────────────────────────────────────────┤
│  Title      [ My Server            ]   │
│  URL        [ http://192.168.1.5:4567  │
│               /api/opds/v1.2       ]   │
│  Username   [                      ]   │
│  Password   [                      ]   │
├────────────────────────────────────────┤
│  [ Cancel ]                [ Save ]    │
└────────────────────────────────────────┘
```

**The address differs between servers** (assuming the server is at `192.168.1.5`):

| Server | Address | Default port |
|---|---|---|
| **Suwayomi** | `http://192.168.1.5:4567/api/opds/v1.2` | 4567 |
| **Komga** | `http://192.168.1.5:25600/opds/v1.2/catalog` | 25600 |

Two things to watch on both:

- **The path has to be complete.** Suwayomi needs `/api/opds/v1.2` — stopping at `/api/opds` or `/opds` returns a 404. Komga needs `/opds/v1.2/catalog`; `/catalog` is part of the path.
- **On Komga, use `v1.2`, not `v2`.** Komga also serves `/opds/v2/catalog`, but KOReader does not support page streaming over v2 (Komga's own compatibility table lists page streaming as **No** for KOReader on v2), and this plugin's prefetching and per-page loading depend on it. The v1.2 row is the one that says **Yes**.
- Username and password depend on the server: **Komga wants your Komga account** (its OPDS uses Basic Auth; leave them empty if the server has no account); **Suwayomi** needs them only when the server has login protection on (`AUTH_MODE=basic_auth`).

#### ② Make a shortcut

Put an **empty file** with a `.opdscomic` extension into **any** folder:

```
/mnt/onboard/comics/              ← wherever your comics live
├── OPDS for Comic.opdscomic      ← new, empty, named like this
├── Vol.01.cbz
└── Vol.02.cbz
```

- Leave it empty; the contents are never read.
- Rename it to anything you like (`read.opdscomic`, whatever) — the **`.opdscomic` extension is what matters**.
- Put as many as you want, at any depth.

#### ③ Tap it

Back in the file manager the file sits in the list like any other. **Tapping it opens the catalog:**

```
┌──────────────────────────────────────────┐
│  /mnt/onboard/comics                     │
├──────────────────────────────────────────┤
│  OPDS for Comic.opdscomic            0 B │   ← tap this row
│  Vol.01.cbz                       3.2 MB │
│  Vol.02.cbz                       3.1 MB │
└──────────────────────────────────────────┘
                    │
                    ↓
┌──────────────────────────────────────────┐
│  menu  OPDS catalog (Comic)              │
├──────────────────────────────────────────┤
│  Downloads                               │
│  My Server                               │
│    Ongoing                               │
│    Completed                             │
└──────────────────────────────────────────┘
```

### The reading view

Tap the **middle third** of the screen to bring up the bottom **icon toolbar** (same style as KOReader's own readers), left to right: **Scale / Rotate / Go to / Crop / Tone / Close**.

```
┌──────────────────────────────────────────┐
│                                          │
│               a comic page               │
│                                          │
├──────────────────────────────────────────┤
│      bottom row is the icon toolbar      │
└──────────────────────────────────────────┘
```

**Tone**: for washed-out or too-dark scans. **1.0** is untouched:

| Value | 0.5 – 0.9 | 1.0 | 2 – 10 |
|---|---|---|---|
| Step | 0.1 | — | 1.0 |
| Effect | brightens | untouched | darkens |

Brightening shows at once, so it needs the fine step; darkening barely shows on e-ink — a white 240 only reaches 226 at 2.0 and 200 at 4.0 — so the top half is coarse and goes up to 10. Works on JPEG / PNG / GIF / WebP / SVG.

### The display panel

**Long press `Rotate`**:

```
┌────────────────────────────────┐
│  Rotate 90                     │
│  Two pages                     │  ← two pages side by side
│  Split two-page scans        ✓ │  ← cut a spread scan into single pages
│  Right to left               ✓ │  ← manga reading order
│  First page is cover           │  ← page 1 on a screen of its own
└────────────────────────────────┘
```

The three display modes (single / two pages / split) are **mutually exclusive**; turning one on turns another off.

**Two pages**: two pages side by side. Going landscape switches it on, returning to portrait switches it back.

**Split**: some releases store a spread as **one landscape image** — too small to read as-is, and two-page mode would put four pages on screen. With the split on, each image's aspect ratio is measured once and a two-page spread is cut at the middle:

```
     one landscape image                       with the split on
┌────────────┬────────────┐      ┌──────────┐ ┌──────────┐
│            │            │      │          │ │          │
│   page 1   │   page 2   │  →   │  page 1  │ │  page 2  │
│            │            │      │          │ │          │
└────────────┴────────────┘      └──────────┘ └──────────┘
      two pages, too small              one page each, readable
```

`Go to` and the page counter keep the server's original page numbers, so nothing has to be converted by hand.

> Known gap: a **single** page stored rotated a quarter turn is also landscape and will be cut. Nothing local can tell it from a spread, so that one switch has to be turned off.

### Common questions

**Why is "Right to left" on by default?**
This is a comic plugin and manga reads right to left. Turn it off for left-bound books, in the display panel.

**Should I turn on the disk cache?**
It is off by default. On, it saves re-downloading, at the cost of up to 64 MB of storage.

**Why did my position on the server change after closing the reader?**
A high cache hit rate means very few real requests, so the server's recorded position stalls; closing the viewer sends one report to catch it up.

### The server side

This plugin is the client; you need an OPDS server of your own. These two are the ones it has been tested against.

#### Suwayomi

[github.com/Suwayomi/Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) — a desktop manga server (a rewrite of Tachiyomi/Mihon) with a built-in extension store, so sources are installed from inside it.

Docker (official compose example in [docker-tachidesk](https://github.com/Suwayomi/docker-tachidesk)):

```bash
docker run -d --name suwayomi \
  -p 4567:4567 \
  -v /path/to/data:/home/suwayomi/.local/share/Tachidesk \
  ghcr.io/suwayomi/suwayomi-server:preview
```

Then open `http://<host>:4567` in a browser to finish setup and install sources. In the plugin, enter `http://<host>:4567/api/opds/v1.2`.

#### Komga

[github.com/gotson/komga](https://github.com/gotson/komga) — a media server for comics, magazines and eBooks that scans files **you already have** (it does not fetch anything). Supports OPDS, Kobo Sync and KOReader Sync. Website: [komga.org](https://komga.org).

Docker (full instructions at [komga.org/docs/installation/docker](https://komga.org/docs/installation/docker)):

```bash
docker run -d --name komga \
  --user 1000:1000 \
  -p 25600:25600 \
  -v /path/to/config:/config \
  -v /path/to/data:/data \
  --restart unless-stopped \
  gotson/komga
```

Replace `--user 1000:1000` with the output of `id <your_user>` on the host, or the mounted folders will hit permission problems. Pick a `/data` folder that holds both your books and the import location. Then open `http://<host>:25600` and add a library pointing at your comics. In the plugin, enter `http://<host>:25600/opds/v1.2/catalog`.

> They answer different questions: **Suwayomi** brings its own sources and can fetch new chapters, which suits following ongoing series; **Komga** only serves files you already have, with finer control over metadata and reading progress.

### License

**AGPL-3.0**, full text in [LICENSE](LICENSE). This plugin derives from KOReader's bundled `opds.koplugin`, which is AGPL-3.0.

Each release's [notes](https://github.com/hugo1120/opdsforcomic.koplugin/releases) list what changed and what is known to be limited.
