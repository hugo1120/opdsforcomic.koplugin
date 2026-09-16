# opdsforcomic.koplugin

KOReader 的漫画 OPDS 客户端：在线看漫画，带页面预取、两级缓存、自动裁剪、双页与拆页。
An OPDS client for KOReader: read comics from a server, with page prefetching, two-level caching, auto crop, two-page and split modes.

**语言 / Language:** [中文](#中文) · [English](#english)

---

<a id="中文"></a>

## 中文

### 这是什么

从 OPDS 服务器（Suwayomi、Kavita、Komga 等）直接看漫画，不用先下载到本地。派生自 KOReader 内置的 `opds.koplugin`，两者可同时启用。

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

地址要带全 `/api/opds/v1.2`，只写到 `/api/opds` 或 `/opds` 会返回 404。用户名密码通常留空。

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

点击屏幕**中间三分之一**唤出底部按钮：

```
┌──────────────────────────────────────────┐
│                                          │
│              漫 画 页 面                 │
│                                          │
├──────────────────────────────────────────┤
│ Scale  Rotate  Go to  Crop  Close        │
└──────────────────────────────────────────┘
```

| 按钮 | 作用 |
|---|---|
| `Scale` | 适应屏幕 / 原始尺寸切换 |
| `Rotate` | 旋转 90°，并自动切换双页。**长按**打开显示方式面板 |
| `Go to` | 跳到指定页，输入框已预填当前页 |
| `Crop` | 自动裁剪开关，开启后按钮带 ✓ |
| `Close` | 关闭 |

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

### 许可

**AGPL-3.0**，全文见 [LICENSE](LICENSE)。本插件派生自 KOReader 内置的 `opds.koplugin`（AGPL-3.0）。

每个版本的 [Release 说明](https://github.com/hugo1120/opdsforcomic.koplugin/releases) 里有改动清单与已知限制。

---

<a id="english"></a>

## English

### What this is

Read comics straight from an OPDS server (Suwayomi, Kavita, Komga, …) without downloading them first. A fork of KOReader's bundled `opds.koplugin`; both can be enabled at once.

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

The address needs the full `/api/opds/v1.2`; stopping at `/api/opds` or `/opds` returns a 404. Username and password are usually left empty.

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

Tap the **middle third** of the screen to bring up the buttons:

```
┌──────────────────────────────────────────┐
│                                          │
│               a comic page               │
│                                          │
├──────────────────────────────────────────┤
│ Scale  Rotate  Go to  Crop  Close        │
└──────────────────────────────────────────┘
```

| Button | What it does |
|---|---|
| `Scale` | Fit to screen / original size |
| `Rotate` | Rotate 90°, which also toggles two-page. **Long press** opens the display panel |
| `Go to` | Jump to a page; the box is pre-filled with the current one |
| `Crop` | Auto-crop toggle, shows ✓ when on |
| `Close` | Close |

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

### License

**AGPL-3.0**, full text in [LICENSE](LICENSE). This plugin derives from KOReader's bundled `opds.koplugin`, which is AGPL-3.0.

Each release's [notes](https://github.com/hugo1120/opdsforcomic.koplugin/releases) list what changed and what is known to be limited.
