# opdsforcomic.koplugin

KOReader 的 OPDS 客户端插件，为漫画目录加上页面预加载与两级缓存。
An OPDS client plugin for KOReader, adding page prefetching and two-level caching for comic catalogs.

**语言 / Language:** [中文](#中文) · [English](#english)

---

<a id="中文"></a>

## 中文

**目录**

- [这是什么](#这是什么)
- [为什么需要它](#为什么需要它)
- [工作原理](#工作原理)
- [安装](#安装)
- [使用](#使用)
- [缓存与可调参数](#缓存与可调参数)
- [日志](#日志)
- [已知限制](#已知限制)
- [许可](#许可)
- [English](#english)

### 这是什么

Fork 自 KOReader 内置的 `opds.koplugin`。独立安装、独立配置，与原插件互不干扰——两者可以同时启用，各有各的菜单入口和配置文件。

改动集中在逐页流式阅读（OPDS-PSE）的取图路径上。原始代码是：

```lua
local page_table = {image_disposable = true}
setmetatable(page_table, {__index = function (_, key)
    code, headers, status = socket.skip(1, http.request { ... })  -- 阻塞
    return RenderImage:renderImageData(data, #data, false)
end})
```

`ImageViewer` 请求第 N 页时才在 UI 线程上同步发 HTTP 请求并解码。每翻一页都等一次完整的网络往返加解码——局域网尚可，跨网络就很难受，高清扫描版尤其明显。

### 为什么需要它

在 Kobo / Kindle 这类设备上，瓶颈有两个：

1. **网络**。实测数据：同一台服务器，快的时候 1.4 MB 不到 1 秒，慢的时候 600 KB 要 3–4 秒。
2. **每页都要重新等一遍**。原版没有任何缓存，翻回去看过的页也要重新下载。

把等待藏到阅读过程中，翻页时只剩解码，这是本插件的全部目的。

### 工作原理

在你看当前页时，后台预取前后几页：

- **内存缓存**：6 页原始字节，先进先出淘汰，关闭阅读界面即清空
- **磁盘缓存**：64 MB 上限，跨重启保留，最久未修改优先淘汰
- **预取窗口**：当前页之后 2 页、之前 1 页，每次抓一页，翻页后延迟 0.35 秒开始

只缓存**原始字节**，不缓存解码后的 BlitBuffer。`ImageViewer` 会释放交给它的 BlitBuffer（`page_table.image_disposable = true` 那条路径），如果缓存里存的是同一个对象，翻页时被释放、再命中就是 use-after-free。字节缓存与它持有的对象之间没有别名，原有的释放模型完全不用改动。

预取使用**比翻页更短的超时**（4s/10s，翻页保持原版的 15s/60s）。预取是在你阅读过程中无预警插入的，沿用 60 秒超时会让界面冻结一分钟；超时后该页会在下次翻页时重新抓取。

### 安装

1. 下载本仓库（`Code` → `Download ZIP`）
2. 解压后得到名为 `opdsforcomic.koplugin-main` 的文件夹
3. **重命名为 `opdsforcomic.koplugin`**（KOReader 靠目录名识别插件，名字不对不会被加载）
4. 放进 KOReader 的 `plugins/` 目录：

   | 设备 | 路径 |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux 桌面 | `~/.config/koreader/plugins/` |

5. 完全退出 KOReader 再启动（插件只在启动时扫描）

**注意别多套一层**（`opdsforcomic.koplugin/opdsforcomic.koplugin/main.lua` 是错的）。

### 使用

在**文件管理器**里打开，阅读界面中不注册此菜单项：

```
文件管理器 → 顶部「扳手」图标 → 搜索标签 → OPDS catalog (Comic)
```

原版的 `OPDS catalog` 在同一个标签下，两个并存。

添加服务器时填入 OPDS 地址，以 Suwayomi-Server 为例：

```
http://你的服务器:4567/api/opds/v1.2
```

路径必须带全 `/api/opds/v1.2`；`/api/opds` 和 `/opds` 都会返回 404。认证通常留空即可，除非服务端显式开启了 `authMode`。

也可以绑到手势上：设置 → 手势 → 文件管理器 → 搜索 `OPDS Catalog (Comic)`。

### 缓存与可调参数

| | 位置 | 上限 | 生命周期 |
|---|---|---|---|
| 内存缓存 | RAM，原始字节 | 6 页 | 关闭阅读界面即清空 |
| 磁盘缓存 | `<数据目录>/cache/opdsforcomic_pse/` | 64 MB | 跨重启保留，30 天过期 |

读取顺序是**内存 → 磁盘 → 网络**。磁盘缓存的文件名是页面 URL 模板加页号的哈希，所以不同章节、不同服务器不会互相覆盖。淘汰检查在打开章节 5 秒后由后台任务执行，不阻塞打开。

参数都在 `opdsforcomic_pse.lua` 开头：

```lua
local PREFETCH_AHEAD = 2          -- 当前页之后预取几页
local PREFETCH_BEHIND = 1         -- 当前页之前预取几页（回翻用）
local PREFETCH_DELAY = 0.35       -- 翻页后延迟多久开始预取（秒）
local MEM_CACHE_LIMIT = 6         -- 内存缓存上限（页数）
local PREFETCH_BLOCK_TIMEOUT = 4  -- 预取的单次读取超时（秒）
local PREFETCH_TOTAL_TIMEOUT = 10 -- 预取的总超时（秒）

local DISK_CACHE_ENABLED = true   -- 关掉即退回纯内存缓存
local DISK_CACHE_MAX_BYTES = 64 * 1024 * 1024
local DISK_CACHE_MAX_AGE = 30 * 24 * 60 * 60  -- 秒

local MAX_DECODE_SCALE = 0        -- 0 = 关闭，见下
```

**内存占用** = `MEM_CACHE_LIMIT` × 单页大小。若页面很大（>2 MB），建议降到 3~4。

#### 关于 `MAX_DECODE_SCALE`

默认关闭，因为它通常得不偿失。`ImageViewer` 的初始 `scale_factor` 是 0（"scaled for best fit"，见 `imageviewer.lua`），也就是说 `ImageWidget` 本来就会把整张图缩到屏幕大小。把上限设成屏幕的 3 倍会导致**缩两次**，CPU 反而更亏。设成 1 倍能让第二次缩放变成空操作并大幅降低单页驻留内存，代价是双指放大失去意义。只有当日志显示瓶颈是内存时，才值得改。

### 日志

插件输出带 `opdsforcomic:` 前缀。**默认级别是 `info`，调试日志不输出**，需要手动打开：

```
文件管理器 → 顶部「扳手」图标 → 更多工具 → 开发者选项 → 启用调试日志
```

或直接改 `.adds/koreader/settings.reader.lua`，加 `["debug"] = true,`。**不需要重启。**

日志文件：`.adds/koreader/crash.log`（每次启动截断到最近 500 KB）。每页会记录一行摘要：

```
opdsforcomic: page 42: prefetch fetched 946605 bytes in 412 ms
opdsforcomic: page 43: ready in 187 ms via mem
opdsforcomic: page 44: ready in 530 ms via disk
opdsforcomic: page 45: ready in 2310 ms via net
```

`via` 后面的来源直接说明缓存有没有生效：`mem` / `disk` 是命中，`net` 是预取没赶上、只能现取。`net` 占比高说明网络仍是瓶颈。

### 已知限制

- **会推进服务端阅读进度。** Suwayomi 的 PSE 模板带 `updateProgress=true`，预取页也会计入。若不希望如此，可在 `fetchPageData` 中把预取请求的该参数改写为 `false`（未默认启用，因为 URL 改写不通用）。
- **预取是阻塞式的。** KOReader 没有线程池，预取在主线程执行，超时为 4s/10s，最坏情况卡顿上限 10 秒。彻底的解法是用 `socket.select` 做分片非阻塞下载，尚未实现。
- **不继承上游更新。** 这是完整 fork，KOReader 对 `opds.koplugin` 的修复不会自动流入，升级后需手动重新合并。
- **保留的原版行为**：Kavita 专用进度查询（`getLastPage`）对 Suwayomi 等非 Kavita 服务器会直接抛错并被 `pcall` 兜底为 0，因此始终从第 1 页开始。
- **未实现 HTTP 连接复用。** 目前每页新建一次 TCP 连接。`socketutil.lua` 的注释指出，用自定义 `create` 函数处理 HTTPS 连接复用很容易出问题，因此没有贸然改动。

### 许可

**AGPL-3.0**（GNU Affero General Public License v3.0），全文见 [LICENSE](LICENSE)。

这不是选择，是义务：本插件是 KOReader 内置 `opds.koplugin` 的派生作品，而 KOReader 以 AGPL-3.0 授权。派生作品必须沿用同一许可证。

AGPL 与 GPL 的关键差别在**第 13 条**：如果你把修改后的版本作为网络服务提供给他人使用，必须向这些用户提供对应的源代码。个人自用不受影响。

---

<a id="english"></a>

## English

**Table of Contents**

- [What This Is](#what-this-is)
- [Why It Exists](#why-it-exists)
- [How It Works](#how-it-works)
- [Installation](#installation)
- [Usage](#usage)
- [Caching and Tuning](#caching-and-tuning)
- [Logging](#logging)
- [Known Limitations](#known-limitations)
- [License](#license)
- [中文](#中文)

### What This Is

A fork of KOReader's bundled `opds.koplugin`. It installs alongside the original and keeps its own settings, so both can be enabled at once, each with its own menu entry and config file.

The changes are confined to the page-streaming (OPDS-PSE) fetch path. The original fetches lazily on the UI thread:

```lua
local page_table = {image_disposable = true}
setmetatable(page_table, {__index = function (_, key)
    code, headers, status = socket.skip(1, http.request { ... })  -- blocking
    return RenderImage:renderImageData(data, #data, false)
end})
```

Page N is only requested when the viewer asks for it, so every page turn waits on a full HTTP round trip plus a decode. Tolerable on a LAN, painful over the internet, and worse on high-resolution scans.

### Why It Exists

On devices like the Kobo and Kindle there are two bottlenecks:

1. **The network.** Measured on one server: 1.4 MB in under a second when it is fast, 600 KB in three to four seconds when it is not.
2. **Every page pays that cost again.** The stock plugin caches nothing, so even a page you just read is re-downloaded when you turn back.

Hiding that wait behind the reading itself, so a page turn only has to decode, is the whole point.

### How It Works

While you read the current page, neighbouring pages are fetched in the background:

- **Memory cache**: six pages of raw bytes, oldest evicted first, cleared when the viewer closes
- **Disk cache**: 64 MB cap, survives restarts, oldest files evicted first
- **Prefetch window**: two pages ahead, one behind, one page per fetch, starting 0.35 s after a page turn

Only **raw bytes** are cached, never decoded BlitBuffers. The `ImageViewer` frees whatever buffer it is handed (the `page_table.image_disposable = true` path), so caching those would mean handing it a buffer that had already been freed. Raw bytes are not aliased with anything the viewer owns, which leaves the existing disposal model untouched.

Prefetches use **shorter timeouts than page turns** (4 s / 10 s, against the stock 15 s / 60 s). A prefetch runs unannounced while you are reading, so the stock timeout would freeze the UI for a minute; a page that times out here is simply fetched again on the next page turn.

### Installation

1. Download this repository (`Code` → `Download ZIP`)
2. Unzip; you get a folder named `opdsforcomic.koplugin-main`
3. **Rename it to `opdsforcomic.koplugin`** — KOReader identifies plugins by directory name and will not load it otherwise
4. Move it into KOReader's `plugins/` directory:

   | Device | Path |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux desktop | `~/.config/koreader/plugins/` |

5. Quit and relaunch KOReader — plugins are only scanned at startup

**Do not nest it** (`opdsforcomic.koplugin/opdsforcomic.koplugin/main.lua` is wrong).

### Usage

Open it from the **file manager**; the entry is not registered in the reader:

```
File manager → wrench icon → Search tab → OPDS catalog (Comic)
```

The stock `OPDS catalog` sits in the same tab, and both coexist.

Enter your catalog's OPDS URL — for Suwayomi-Server, for example:

```
http://your-server:4567/api/opds/v1.2
```

The full `/api/opds/v1.2` path is required; `/api/opds` and `/opds` both return 404. Leave the credentials blank unless the server explicitly enables `authMode`.

You can also bind it to a gesture: Settings → Gestures → File manager → search for `OPDS Catalog (Comic)`.

### Caching and Tuning

| | Location | Cap | Lifetime |
|---|---|---|---|
| Memory cache | RAM, raw bytes | 6 pages | Cleared when the viewer closes |
| Disk cache | `<data dir>/cache/opdsforcomic_pse/` | 64 MB | Survives restarts, 30-day expiry |

Lookups go **memory → disk → network**. On-disk filenames are a hash of the page-URL template plus the page index, so different chapters and servers cannot collide. Eviction runs five seconds after a chapter opens, so opening never waits on a directory walk.

The knobs live at the top of `opdsforcomic_pse.lua`:

```lua
local PREFETCH_AHEAD = 2          -- pages to keep ready ahead of the current one
local PREFETCH_BEHIND = 1         -- pages to keep ready behind it, for turning back
local PREFETCH_DELAY = 0.35       -- seconds to wait after a page turn before fetching
local MEM_CACHE_LIMIT = 6         -- pages of raw bytes held in memory
local PREFETCH_BLOCK_TIMEOUT = 4  -- per-read timeout for a prefetch, in seconds
local PREFETCH_TOTAL_TIMEOUT = 10 -- total timeout for a prefetch, in seconds

local DISK_CACHE_ENABLED = true   -- disable to fall back to memory only
local DISK_CACHE_MAX_BYTES = 64 * 1024 * 1024
local DISK_CACHE_MAX_AGE = 30 * 24 * 60 * 60  -- seconds

local MAX_DECODE_SCALE = 0        -- 0 disables it; see below
```

**Memory held** is `MEM_CACHE_LIMIT` times the page size. For large pages (over 2 MB) consider dropping it to 3–4.

#### About `MAX_DECODE_SCALE`

Off by default, because it usually costs more than it saves. `ImageViewer` starts at `scale_factor` 0 ("scaled for best fit", see `imageviewer.lua`), so `ImageWidget` scales the image down to the screen regardless. Capping at three times the screen size would make it scale twice, which is a net loss on CPU. A cap of exactly one times the screen makes the second scale a no-op and cuts the memory a page retains, but makes zooming in pointless. Worth revisiting only if the logs show memory rather than network or decode is the bottleneck.

### Logging

Plugin output is prefixed with `opdsforcomic:`. **The default level is `info`, so debug output is suppressed** until you enable it:

```
File manager → wrench icon → More tools → Developer options → Enable debug logging
```

Or set `["debug"] = true,` in `.adds/koreader/settings.reader.lua`. **No restart required.**

Log file: `.adds/koreader/crash.log` (truncated to the last 500 KB on each launch). Each page logs one line:

```
opdsforcomic: page 42: prefetch fetched 946605 bytes in 412 ms
opdsforcomic: page 43: ready in 187 ms via mem
opdsforcomic: page 44: ready in 530 ms via disk
opdsforcomic: page 45: ready in 2310 ms via net
```

The `via` field tells you whether caching is working: `mem` and `disk` are hits, `net` means the prefetch did not get there in time. A high proportion of `net` means the network is still the bottleneck.

### Known Limitations

- **It advances server-side reading progress.** Suwayomi's PSE template carries `updateProgress=true`, and prefetched pages count. To avoid it, rewrite that parameter to `false` for prefetch requests in `fetchPageData` (not enabled by default, since rewriting URLs is not portable across servers).
- **Prefetching is blocking.** KOReader has no thread pool, so prefetches run on the main thread. Timeouts are 4 s / 10 s, bounding the worst-case stall at ten seconds. The thorough fix is chunked non-blocking downloads with `socket.select`, not implemented.
- **Upstream fixes do not flow in.** This is a full fork; KOReader's fixes to `opds.koplugin` will not arrive automatically and must be merged by hand.
- **Inherited behaviour**: the Kavita-specific progress lookup (`getLastPage`) throws on non-Kavita servers such as Suwayomi and is caught by `pcall`, so streaming always starts at page 1.
- **No HTTP connection reuse.** Each page opens a new TCP connection. The comment in `socketutil.lua` warns that connection reuse via a custom `create` function is error-prone under HTTPS, so it was left alone.

### License

**AGPL-3.0** (GNU Affero General Public License v3.0). Full text in [LICENSE](LICENSE).

This is an obligation rather than a choice: the plugin is a derivative work of KOReader's bundled `opds.koplugin`, and KOReader is licensed AGPL-3.0. Derivative works must carry the same license.

The practical difference from the GPL is **section 13**: if you run a modified version as a network service for others, you must offer those users the corresponding source. Personal use is unaffected.
