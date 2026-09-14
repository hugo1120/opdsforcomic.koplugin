# opdsforcomic.koplugin

KOReader 的 OPDS 客户端插件，为漫画目录加上**翻页预加载**。

Fork 自 KOReader 内置的 `opds.koplugin`。独立安装、独立配置，与原插件互不干扰。

---

## 为什么需要它

KOReader 内置 OPDS 插件的逐页流式阅读（OPDS-PSE）是**惰性取图**——`ImageViewer` 请求第 N 页时，才在主线程上同步发起 HTTP 请求并解码：

```lua
local page_table = {image_disposable = true}
setmetatable(page_table, {__index = function (_, key)
    ...
    code, headers, status = socket.skip(1, http.request { ... })  -- 阻塞
    return RenderImage:renderImageData(data, #data, false)
end})
```

每翻一页都要等一次完整的**网络往返 + JPEG 解码**。局域网尚可忍受，跨网络就很难受——尤其是高清扫描版，单页可达数 MB。

本插件在你阅读当前页时，**后台预取后面 2 页的原始字节**。翻页时命中缓存，只剩解码，没有网络等待。

## 工作原理

1. 翻页后延迟 0.35 秒，在后台逐页抓取当前页之后的 2 页，存入内存缓存
2. 缓存的是**原始 JPEG 字节**，不是解码后的 BlitBuffer
3. 翻页时若命中缓存，直接解码上屏

只缓存字节是个刻意的选择：`ImageViewer` 会释放交给它的 BlitBuffer（`page_table.image_disposable = true` 那条路径），如果缓存里存的是同一个对象，翻页时被释放、再命中就是 use-after-free。字节缓存与 `ImageViewer` 持有的对象之间没有别名，**原有的内存释放模型完全不用改动**。

预取使用**更短的超时**（8s/20s，翻页保持原版的 15s/60s）：预取在阅读过程中后台运行，若沿用 60 秒超时，服务器卡住会让界面无预警冻结一分钟。

## 安装

### 手动安装

1. 下载本仓库（`Code` → `Download ZIP`）
2. 解压后会得到名为 `opdsforcomic.koplugin-main` 的文件夹
3. **把它重命名为 `opdsforcomic.koplugin`**（KOReader 靠目录名识别插件，名字不对不会被加载）
4. 整个文件夹放进 KOReader 的 `plugins/` 目录：

   | 设备 | 路径 |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux 桌面 | `~/.config/koreader/plugins/` |

5. 完全退出 KOReader 再启动（插件只在启动时扫描）

最终结构应为：

```
plugins/opdsforcomic.koplugin/
├── main.lua
├── _meta.lua
├── opdsforcomic_browser.lua
├── opdsforcomic_parser.lua
└── opdsforcomic_pse.lua
```

**注意别多套一层**（`opdsforcomic.koplugin/opdsforcomic.koplugin/main.lua` 是错的）。

## 使用

在**文件管理器**里打开（阅读界面中不注册此菜单项）：

```
文件管理器 → 顶部菜单 → 搜索(Search) 标签 → OPDS catalog (Comic)
```

原版的 `OPDS catalog` 在同一个「搜索」标签下，两个并存。

### 添加服务器

```
OPDS catalog (Comic) → 添加目录 → 填入 URL
```

以 Suwayomi-Server 为例：

```
http://你的服务器:4567/api/opds/v1.2
```

路径必须带全 `/api/opds/v1.2`；`/api/opds` 和 `/opds` 都会返回 404。

**认证留空**即可，除非服务端显式开启了 `authMode`。注意服务端若为 `SIMPLE_LOGIN` 或 `UI_LOGIN`，多数 OPDS 客户端不支持这类基于 cookie/JWT 的认证方式，请改用 `BASIC_AUTH`。

### 绑手势

本插件注册了 dispatcher action，可绑到手势上，免去每次翻菜单：

```
设置 → 手势 → 文件管理器 → 搜索 "OPDS Catalog (Comic)"
```

## 可调参数

都在 `opdsforcomic_pse.lua` 开头：

```lua
local PREFETCH_AHEAD = 2         -- 预取后面几页
local PREFETCH_DELAY = 0.35      -- 翻页后延迟多久开始预取（秒）
local CACHE_LIMIT = 5            -- 内存缓存上限（页数）
local PREFETCH_BLOCK_TIMEOUT = 8 -- 预取的单次读取超时（秒）
local PREFETCH_TOTAL_TIMEOUT = 20-- 预取的总超时（秒）
```

**内存占用** = `CACHE_LIMIT` × 单页大小。实测参考：

| 服务器单页 | 5 页缓存 |
|---|---|
| 约 875 KB | 约 4.4 MB |
| 约 3 MB | 约 15 MB |

缓存只在内存中，不落盘，关闭阅读界面时清空，不会持续增长。若页面较大（>2 MB），建议把 `CACHE_LIMIT` 降到 3。

## 已知限制

- **会推进服务端阅读进度。** Suwayomi 的 PSE 模板带 `updateProgress=true`，预取页也会计入。若不希望如此，可在 `fetchPageData` 中把预取请求的该参数改写为 `false`（未默认启用，因为 URL 改写不通用）。
- **预取是阻塞式的。** KOReader 没有线程池，预取在主线程上执行。它被安排在翻页之后、你正在阅读当前页时进行，因此通常不可感知；但若你在预取进行中立即再次翻页，会有短暂停顿。
- **不继承上游更新。** 这是完整 fork，KOReader 对 `opds.koplugin` 的修复不会自动流入，升级后需手动重新合并。
- **顺带修的原版问题**：本 fork 保留了原版的 Kavita 专用进度查询逻辑（`getLastPage`），它对 Suwayomi 等非 Kavita 服务器会直接抛错并被 `pcall` 兜底为 0，因此始终从第 1 页开始。

## 许可

AGPL-3.0，与 KOReader 一致（本插件是 `opds.koplugin` 的派生作品）。详见 [LICENSE](LICENSE)。
