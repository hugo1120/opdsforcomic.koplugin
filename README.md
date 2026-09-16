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
- [更新日志](#更新日志)
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

- **内存缓存**：16 MB 原始字节，按「离当前页的距离」淘汰，关闭阅读界面即清空
- **磁盘缓存**：64 MB 上限，跨重启保留，最久未修改优先淘汰
- **预取窗口**：当前页之后 3 页、之前 2 页，每次抓一页，翻页后延迟 0.35 秒开始
- **让路给弹窗**：设置面板或输入框打开时暂停抓取，每 0.5 秒重试一次，最多 20 次——抓取是同步阻塞的，正在找按钮的时候不该冻住界面

只缓存**原始字节**，不缓存解码后的 BlitBuffer。`ImageViewer` 会释放交给它的 BlitBuffer（`page_table.image_disposable = true` 那条路径），如果缓存里存的是同一个对象，翻页时被释放、再命中就是 use-after-free。字节缓存与它持有的对象之间没有别名，原有的释放模型完全不用改动。

预取使用**比翻页更短的超时**（6s/15s，翻页保持原版的 15s/60s）。预取是在你阅读过程中无预警插入的，沿用 60 秒超时会让界面冻结一分钟；超时后该页会在下次翻页时重新抓取。

### 安装

**方式一：下载 Release（推荐，解压即用）**

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

**方式二：从源码仓库下载**

1. 下载本仓库（`Code` → `Download ZIP`）
2. 解压后得到名为 `opdsforcomic.koplugin-main` 的文件夹
3. **重命名为 `opdsforcomic.koplugin`**（KOReader 靠目录名识别插件，名字不对不会被加载）
4. 放进 `plugins/` 目录，重启

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

#### 阅读界面的按钮

点击屏幕中间三分之一唤出底部按钮栏：

| 按钮 | 作用 |
|---|---|
| `Scale` / `Original size` | 适屏与原尺寸之间切换 |
| `Rotate` / `No rotation` | 旋转 90°，**并自动切换双页跨页**；长按打开显示方式面板 |
| `Go to` | 打开页码输入框，**已预填当前页**；标题显示「第 N 页，共 M 页」 |
| `Crop` | 自动裁剪白边的开关，开启后按钮带 ✓ |
| `Close` | 关闭 |

**自动裁剪默认关闭。** 开启后每页会用一个 96×96 的采样网格估算内容边界，把四周空白切掉；判定不确信时**原样返回，不裁**。思路取自 TinyPic / Kindle Comic Converter：先从四角检测背景色、二值化、再取内容包围盒，并在多处设置保守的退出条件。

其中**四角检测背景色**是必要的：漫画有黑底页，假设白底会把画面当成空白裁掉、反而留下黑边。

裁剪只在内存里改变显示范围，不改动缓存的原始字节，也不影响预取。开启后日志每页会记一行 `crop 2480x3508 -> 120,180..2360,3320`，`nothing to trim` 表示判定不确信、保持了原样。

> 未实现 TinyPic 的页码裁剪。它必须把页码和「底部居中的小分格」区分开，判错就是静默删掉画面，代价太高。

##### 显示方式（长按 `Rotate`）

长按 `Rotate` 打开设置面板：

| 项 | 作用 |
|---|---|
| `Rotate 90°` / 旋转 90° | 同点按；旋转后自动关闭面板 |
| `Two pages` / 双页显示 | 左右两页并排显示 |
| `Split two-page scans` / 拆开双页扫描 | 把一张图里的两页切开，一屏只显示一页 |
| `Right to left` / 从右到左 | 双页时第 1 页排在右边；拆页时先读右边那半（日式漫画的读法，默认开） |
| `First page is cover` / 首页单独显示 | 第 1 页单独一屏，之后按 (2,3) (4,5)… 配对 |

**共三种显示模式：单页 / 双页（拼页）/ 拆页（切半）。** 三者互斥，面板里开一个会自动关掉另一个——双页配拆页会把四页塞进一屏。互斥只在 `dualPageOn()` 一处判定，所以配对、页数、预取深度这些调用方都不必知道拆页存在。

**旋转与双页是绑在一起的**：转到横屏自动打开双页，转回竖屏自动恢复单页——横屏只看一页漫画没有意义。面板里的「双页显示」仍可手动开启，手动开的值会**跨章节保留**；由旋转带出来的则不会，下次打开章节回到单页。

**「从右到左」在双页或拆页任一开启时可用，「首页单独显示」只在双页下可用**（拆页不需要它：跨页图是要量出来的，封面只占一页就原样显示）。**「从右到左」默认开启**，因为这是漫画插件；左开本的书要在这里关掉。

双页是**显示时合成**的：一次解码两个源页、拼成一张宽图再交给 `ImageViewer`，缓存与预取仍然按源页工作，完全不知道双页的存在。配对规则与 KOReader 内置的漫画插件（`comicreader.koplugin`）一致。

##### 拆页：把跨页扫描拆成单页

有些资源把跨页存成**一张横图**。直接看是一页要缩着脖子读的图，开双页又会变成四页一屏。打开「拆开双页扫描」后，每张图在**解码之后、裁剪之前**量一次宽高比：

- `w/h` 落在 **1.15 ~ 2.1** 之间 → 认定这张是两页，**按几何中点切半**，一屏显示一半。
- 低于 1.15 → 竖图，原样整页显示；高于 2.1 → 太宽了，更像一条长条（跨页大格、或扫描本身的毛病），切开会切进画面，也原样显示。

**判据只有宽高比**，是因为解码头之后、画面出来之前，这是唯一能知道的东西，也是唯一与扫描分辨率无关的性质：漫画单页是竖的，两张并排是横的。取 1.15 而不是 1.0，是因为裁过边的扫描可能只是「略宽于高」，而真正的跨页在 1.4 附近。

切分取几何中点，**不做脊线检测**：扫描的装订线可能是一道黑带、一条细线或一道折痕，每一种都既像内容又像噪声，去找它总会有落在分格里的风险。中点的误差从来不大，剩下的那点装订线交给自动裁剪。

> **已知短板：扫描时就转了 90° 的单页也是横的，会被切开。** 本地没有任何信息能把它和跨页区分开，解法只能是把这个开关关掉。

开拆页后**编号分两层**：*源页* 是服务器章节里的第几张图，*显示槽位* 是读者按一次翻页键走过的一屏。一张跨页占两个槽位，所以 `Go to` 和进度仍按源页号走——读者不必自己换算。一页占 1 还是 2 个槽位要解码后才知道，所以是**边读边学**：未解码的页按 2 个槽位算（这是读者对整章的断言，不是猜测），解码后当场纠正。判定只写在该源页的**第一个**槽位上，而它只累加这个源页**之前**的页，所以学到答案不会让映射自己漂移，屏幕上的页也不会跳。整章都是单页时会自然收敛成 1 槽/页，首页封面不需要任何设置。

**旋转是拆页的临时开关**：转到横屏显示整张跨页原图（横屏本来就是要看跨页的姿势），转回竖屏恢复切半。它不写任何持久设置。

半页是**切出来就留着**的：渲染第一半时顺手把另一半也切好缓存起来（只多一次 `blitFrom`），下一屏直接用，省掉一次整张重解码——实测半页的 948 ms 里有 685 ms 就是解码那张 12.6 Mpx 的跨页。日志里这半页显示为 `via stash`，往回翻也照样命中。只存「读者旁边那一张」，因为一张半页的缓冲区约 15 MB。

**关闭只能靠按钮。** 原版的单指滑动关闭已禁用——在「适应屏幕」缩放下，一次漂移几毫米的点按和短促滑动在电子墨水屏上无法区分，误触会直接退出整章且屏幕上没有任何提示。多指滑动、Back 键（有实体键的机型）和 `Close` 按钮仍然可用。

### 缓存与可调参数

| | 位置 | 上限 | 生命周期 |
|---|---|---|---|
| 内存缓存 | RAM，原始字节 | 16 MB（约 18 页） | 关闭阅读界面即清空 |
| 磁盘缓存 | `<数据目录>/cache/opdsforcomic_pse/` | 64 MB | 默认**关闭** |

读取顺序是**内存 → 磁盘 → 网络**。

**磁盘缓存默认关闭。** 写一页到 SD 卡是同步操作，且位于翻页路径上——而实测日志里它的命中率是 0。除非你经常退出重进同一章，否则它是纯成本。要开启就把 `DISK_CACHE_ENABLED` 改成 `true`；文件名是页面 URL 模板加页号的哈希，不同章节、不同服务器不会互相覆盖，淘汰检查在打开章节 5 秒后由后台任务执行，不阻塞打开。

参数都在 `opdsforcomic_pse.lua` 开头：

```lua
local PREFETCH_AHEAD = 3          -- 当前页之后预取几页
local PREFETCH_BEHIND = 2         -- 当前页之前预取几页（回翻用）
local PREFETCH_DELAY = 0.35       -- 翻页后延迟多久开始预取（秒）
local PREFETCH_CHAIN_DELAY = 0.25 -- 预取链上连续抓取的间隔（秒）
local PREFETCH_DEFER_DELAY = 0.5  -- 弹窗挡住阅读界面时，隔多久重试（秒）
local PREFETCH_DEFER_MAX = 20     -- 最多重试几次，之后放弃并等下一次翻页

local MEM_CACHE_MAX_BYTES = 16 * 1024 * 1024  -- 内存缓存上限（字节）
local MEM_CACHE_MIN_PAGES = 4                 -- 无论如何至少保留几页

local PREFETCH_BLOCK_TIMEOUT = 6  -- 预取的单次读取超时（秒）
local PREFETCH_TOTAL_TIMEOUT = 15 -- 预取的总超时（秒）

local DISK_CACHE_ENABLED = false  -- 默认关闭，见下
local DISK_CACHE_MAX_BYTES = 64 * 1024 * 1024
local DISK_CACHE_MAX_AGE = 30 * 24 * 60 * 60  -- 秒

local MAX_DECODE_SCALE = 0        -- 0 = 关闭，见下

-- 自动裁剪（Crop 按钮）
local AUTOCROP_SAMPLES = 96       -- 采样网格密度（每轴）
local AUTOCROP_POWER = 0.6        -- 0~3，越大裁得越激进
local AUTOCROP_EDGE_BAND = 2      -- 边缘多少格算边框
local AUTOCROP_EDGE_NOISE_MAX = 0.02
local AUTOCROP_MIN_GAIN = 0.02    -- 省得比这还少就不裁
local AUTOCROP_MAX_TRIM = 0.35    -- 单边最多裁掉这个比例

-- 离章补记阅读进度（见更新日志 0.0.6）
local PROGRESS_REPORT_DELAY = 1   -- 关闭阅读界面后延迟多久再发（秒）
local PROGRESS_BLOCK_TIMEOUT = 4  -- 单次读取超时（秒）
local PROGRESS_TOTAL_TIMEOUT = 8  -- 总超时（秒），比翻页的紧：没人等这个答案
```

`AUTOCROP_POWER` 映射到二值化阈值 `240 - power*64`，沿用 TinyPic 的公式但**默认取 0.6 而非 1.0**——裁进网点比留条白边糟得多。

**`PREFETCH_CHAIN_DELAY` 从 0.05 提到 0.25。** 链上每一步都是一次同步抓取、独占 UI 线程，几毫秒的间隔等于翻页后连续几百毫秒的输入无响应——而那正是读者最可能去点东西的时刻。填窗速度取决于网络而不是这个定时器，所以多这 0.2 秒几乎不影响填窗，却给点击留出了缝。

**双页时预取窗口按源页翻倍。** 一个跨页覆盖两个源页，深度加倍才能保持同样多的跨页就绪。

**为什么向前是 3、向后是 2：** 顺序阅读时每次翻页恒定只需要新抓 1 页——窗口里其余都在缓存里。所以 `PREFETCH_AHEAD` 设 2 还是 3，**稳态网络负载完全一样**，差别只是缓冲深度：网络抖动时你有多大余量不被追上。向后则是跳着回看的保险。

**内存按字节封顶而非按页数**，所以大页的服务器自动少存几页，不会悄悄吃内存。实测页大小约 875 KB 时，16 MB 能放约 18 页；页约 3 MB 时约 5 页，会贴近 `MEM_CACHE_MIN_PAGES` 下限。

**淘汰按「离当前页的距离」而非插入顺序。** 预取是先抓前、后抓后，若按插入顺序淘汰，内存紧张时会先把最该留的前向页挤掉。

**内存占用** = 页数 × 单页大小，页数由 `MEM_CACHE_MAX_BYTES`（16 MB）反过来决定。所以大页服务器自动少存几页，`MEM_CACHE_MIN_PAGES`（4 页）是下限。

#### 关于 `MAX_DECODE_SCALE`

默认关闭，因为它通常得不偿失。`ImageViewer` 的初始 `scale_factor` 是 0（"scaled for best fit"，见 `imageviewer.lua`），也就是说 `ImageWidget` 本来就会把整张图缩到屏幕大小。把上限设成屏幕的 3 倍会导致**缩两次**，CPU 反而更亏。设成 1 倍能让第二次缩放变成空操作并大幅降低单页驻留内存，代价是双指放大失去意义。只有当日志显示瓶颈是内存时，才值得改。

**也别指望让服务器发小图。** Suwayomi 的页面端点只接受 `updateProgress` / `format` / `opds` 三个参数，图片按存储分辨率原样输出、没有任何缩放路径（`Page.getPageImageServe` 走 `ImageIO`）。所以大页超采样 3~4 倍是**没有服务端解法**的，代码里那行 `{maxWidth}` 替换只对少数别的目录有效。

#### 关于离章补记进度

opds-pse 协议里**没有独立的记账端点**：服务端唯一的按页记账钩子就是「带着 `updateProgress=true` 取一张图」。而缓存命中率实测 90%，也就是说**一百次翻页只有九次真的发请求**，服务端记下的位置其实是"最后一次缓存未命中"，通常远落后于你关章时的位置。

所以关掉阅读界面时会**补记一次**：只发一个请求，页号改成你离开的那一页。四条闸门：目录模板里本来就有 `updateProgress=true`（不把 `false` 改写成 `true`，那是目录方的明确意愿）、你确实比开章时读得更靠后、链路是通的、以及**每章只发一次**（发过就不再重试）。按实测页均 0.83 MB 算，约每章多 1% 流量。

**它仍然跑在 UI 线程上**（LuaSocket 没有异步），延后 1 秒只是让文件浏览器先画出来、把可能的卡顿放到画面稳定之后，并不是消除卡顿。所以超时取 4s/8s，比翻页的 6s/15s 紧得多——没人等这个答案，超时就放弃。

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
opdsforcomic: page 46: ready in 34 ms via stash as 1800x2790 (half 2 of sheet 23)
opdsforcomic: page 4: two pages on the sheet, splitting
opdsforcomic: progress: reported page 87 in 412 ms
opdsforcomic: prefetch: updateProgress forced to false, page turns stay authoritative
```

`via` 后面的来源直接说明缓存有没有生效：`mem` / `disk` / `stash` 是命中，`net` 是预取没赶上、只能现取。`net` 占比高说明网络仍是瓶颈。`via stash` 指拆页模式下这一半是上一屏顺手切好留下的（见上）。

`two pages on the sheet, splitting` / `one page on the sheet` 是拆页模式的判定结果，逐页出现；括号里的 `(half N of sheet M)` 说明这是源页 M 的第 N 半。

`prefetch:` 那行每章出现一次，出现在预取请求里的 `updateProgress` 参数被改写时（见更新日志 0.0.5）。`progress:` 那行同样每章最多一次，是关章时的补记（见上）；`NOT reported` 表示发了但失败了，`not reporting` 是位置没前移、按设计跳过。

### 已知限制

- **预取是阻塞式的。** KOReader 没有线程池，预取在主线程执行，超时为 6s/15s，最坏情况卡顿上限 15 秒。打开对话框时预取会主动让路（见上），但翻页路径本身仍然是同步的。彻底的解法是用 `socket.select` 做分片非阻塞下载，尚未实现。
- **不继承上游更新。** 这是完整 fork，KOReader 对 `opds.koplugin` 的修复不会自动流入，升级后需手动重新合并。
- **保留的原版行为**：Kavita 专用进度查询（`getLastPage`）对 Suwayomi 等非 Kavita 服务器会直接抛错并被 `pcall` 兜底为 0，因此始终从第 1 页开始。
- **拆页模式下最贵的是第一次打开一张跨页。** 要整张解码才能知道它是不是跨页、才能切半（12.6 Mpx 实测 948 ms）；另一半由缓存接下（`via stash`，约 34 ms）。整章都是单页时没有这笔开销。
- **未实现 HTTP 连接复用。** 目前每页新建一次 TCP 连接。`socketutil.lua` 的注释指出，用自定义 `create` 函数处理 HTTPS 连接复用很容易出问题，因此没有贸然改动。

### 更新日志

**0.0.6**

- 新增**拆页显示模式**（长按 `Rotate` 的面板里「拆开双页扫描」）。有些资源把跨页存成一张横图：直接看太小，开双页又变四页一屏。打开后每张图在解码头、裁剪前量一次宽高比，落在 1.15~2.1 之间就按两页处理，**按几何中点切半**，`从右到左` 决定先读哪半。判据只看宽高比 ⇒ 与扫描分辨率无关。**已知短板：扫描时就转了 90° 的单页也是横的，会被切开**，本地没有信息能区分它和跨页。
- **三种显示模式互斥**：单页 / 双页（拼页）/ 拆页（切半）。互斥只在 `dualPageOn()` 一处判定，配对、页数、预取深度都不必知道拆页存在；面板里开一个会自动关掉另一个。预取窗口在拆页时**减半**（一张跨页要两屏才能看完，所以同样的屏数只需要一半的页深）。
- **编号分两层：源页 vs 显示槽位。** 一张跨页占两个槽位，`Go to` 与页码仍按**源页**（服务器章节里的第几张图），读者不用自己换算。一页占几槽要解码后才知道，于是**边读边学**：未解码的按 2 槽算，学到答案只写在该源页的第一个槽位 ⇒ 映射不自我漂移、屏幕上的页不跳；整章单页时自然收敛成 1 槽/页，封面不需要设置。
- **旋转是拆页的临时开关**：转到横屏显示整张跨页原图，转回竖屏恢复切半，不写任何持久设置。
- **跨页的另一半会缓存下来**（日志里的 `via stash`）。渲染这一半时顺手把另一半也切好留着，下一屏直接用——实测半页 948 ms 里 685 ms 是解码那张 12.6 Mpx 的跨页，这次切分只多一次 `blitFrom`。只留「读者旁边那一张」，一张半页缓冲区约 15 MB。
- **半页与整页的裁剪框分开存**，否则整页量出来的框会套到半页上。
- **离章补记一次阅读进度。** 服务端只认「带着 `updateProgress=true` 取一张图」，而缓存命中率 90% ⇒ 真实请求很少，进度会停在原地。现在关闭阅读界面时补发一次，页号改成离开时那一页（每章约 +1% 流量）。位置没前移、目录没要求、链路不通都不发；每章最多一次，失败不重试。

**0.0.5**

- **修掉预取把服务端阅读进度推到读者前面。** Suwayomi 的页流模板把 `updateProgress=true` 硬编码在 URL 里（`.../page/{pageNumber}?updateProgress=true&opds=true`），插件原本原样透传。这本是**真实翻页**该做的，但对**预取**是错的——预取抓的是你还没翻到的页。后果有两层：服务端把往前几页记成你的阅读位置，于是**进度恒在你实际读到的位置之前**；预取一旦读到本章最后一页，**这一章会被标成已读**。另外每次预取都会触发一次 KOReader 同步推送。现在只要请求来自预取，该参数就改写为 `false`；真实翻页不受影响，进度照常上报。

**0.0.4**

- 新增**双页跨页显示**：左右两页并排，可切「从右到左」（默认开，这是漫画）与「首页单独显示」。配对规则取自内置的 `comicreader.koplugin`。双页只在**显示时合成**——一次解码两个源页、拼成一张宽图，缓存与预取仍按源页工作。
- 新增**长按 `Rotate` 的显示方式面板**：旋转、双页、阅读方向、首页是否单独显示。后两项在双页关闭时置灰。
- **旋转与双页绑定**：转横屏自动开双页，转竖屏自动恢复单页。手动开的双页跨章节保留，由旋转带出来的不保留——否则下次打开章节会「没旋转却双页」。
- **关掉单指滑动关闭。** 在「适应屏幕」缩放下，几毫米的滑动与点按在电子墨水屏上无法区分，误触会静默退出整章。`Close` 按钮、Back 键、多指滑动仍然可用。
- **修掉旋转时的一次多余重解码。** 裁剪关闭（默认）时旋转不再重渲染整页，直接复用已解码的缓冲，只重算旋转角；裁剪开启时才需要重渲染，因为旋转态会跳过裁剪。裁剪开关本身也不再渲染两遍。
- **修掉内存淘汰的方向错误。** 淘汰想丢掉离读者最远的页，却拿跨页号当源页号算距离；双页时这个偏差把基准挪到了读者身后，于是优先丢掉的是**前方还没读**的页。表现是往前翻反而要重新下载。
- **预取给对话框让路。** 抓取是同步阻塞的，面板或输入框开着时此前会连界面一起冻住。现在暂停抓取、每 0.5 秒重试，最多约 10 秒；翻页会重新起链。
- 预取链的间隔 0.05 → 0.25 秒，让出 UI 线程；填窗速度取决于网络，几乎不受影响。

**0.0.3**

- 新增 **Go to** 按钮：页码输入框**预填当前页**，标题显示「第 N 页，共 M 页」。
- 新增 **Crop** 自动裁剪白边开关（默认关闭）。思路取自 TinyPic / Kindle Comic Converter：先从四角检测背景色（**漫画有黑底页，假设白底会把画面裁掉、留下黑边**）、二值化、取内容包围盒，并在多处设置保守的退出条件。用 96×96 采样网格代替逐像素扫描——全分辨率扫描图的像素量 Lua 走不动。
- 新按钮标签自带中英两种文字。KOReader 的 gettext 只读安装根目录的 `l10n/<lang>/koreader.mo`，**插件无法注册自己的翻译目录**（核心代码与所有内置插件都没有 l10n）。
- 未实现页码裁剪：收益小，而判错就是**静默删掉画面**。

**0.0.2**

- **修复一个会让 KOReader 崩溃的 bug。** `__index` 元方法的第一个参数名叫 `_`，遮蔽了本文件里的 gettext 函数，于是任何一页加载失败时都会走进 `_("...")` 而崩溃（`attempt to call local '_' (a table value)`）。上游 `opdspse.lua:106` 有同样的坑，但只在「协议非法」这种罕见分支可达；本插件在失败路径上加了提示，才把它变成常见路径。
- **流畅度大幅提升。** 预取超时从 4s/10s 放宽到 6s/15s。之前慢页会被超时误杀、2.5 秒后再重试一次，等于抓两遍。设备实测：单次抓取最慢耗时从 3–4 秒降到 **785 ms**，波动收窄一个量级。
- **内存缓存改为按字节封顶**（16 MB），大页服务器自动少存几页，不再按固定页数。
- **淘汰策略改为按「离当前页的距离」**，而非插入顺序——后者在内存紧张时会先挤掉最该保留的前向页。
- 向前预取 2 → 3 页，向后 1 → 2 页。
- 预取链上连续抓取不再重复等待 0.35 秒（新增 `PREFETCH_CHAIN_DELAY`），窗口填满更快。
- **磁盘缓存默认关闭。** 写一页到 SD 卡是同步操作且位于翻页路径上，而实测命中率为 0，是纯成本。
- 新增保护：预取窗口装不下内存缓存时停止链条，避免无限重复抓取。
- Release 压缩包现在自带 `opdsforcomic.koplugin` 文件夹，解压即用，**不需要重命名**。

**0.0.1**

- 初始测试版本。

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
- [Changelog](#changelog)
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

- **Memory cache**: 16 MB of raw bytes, evicted by distance from the current page, cleared when the viewer closes
- **Disk cache**: 64 MB cap, survives restarts, oldest files evicted first
- **Prefetch window**: three pages ahead, two behind, one page per fetch, starting 0.35 s after a page turn
- **Yields to dialogs**: fetching pauses while a panel or input box is open and retries every 0.5 s, up to 20 times — the fetch is synchronous, and the moment you are reaching for a button is the wrong moment to freeze the UI

Only **raw bytes** are cached, never decoded BlitBuffers. The `ImageViewer` frees whatever buffer it is handed (the `page_table.image_disposable = true` path), so caching those would mean handing it a buffer that had already been freed. Raw bytes are not aliased with anything the viewer owns, which leaves the existing disposal model untouched.

Prefetches use **shorter timeouts than page turns** (6 s / 15 s, against the stock 15 s / 60 s). A prefetch runs unannounced while you are reading, so the stock timeout would freeze the UI for a minute; a page that times out here is simply fetched again on the next page turn.

### Installation

**Option 1: the release archive (recommended — unzip and drop in)**

1. Grab the latest `opdsforcomic.koplugin.zip` from [Releases](https://github.com/hugo1120/opdsforcomic.koplugin/releases)
2. Unzip; you get an `opdsforcomic.koplugin` folder — **already named correctly, nothing to rename**
3. Move that folder into KOReader's `plugins/` directory:

   | Device | Path |
   |---|---|
   | Kobo | `.adds/koreader/plugins/` |
   | Kindle | `koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Linux desktop | `~/.config/koreader/plugins/` |

4. Quit and relaunch KOReader — plugins are only scanned at startup

**Option 2: the source repository**

1. Download this repository (`Code` → `Download ZIP`)
2. Unzip; you get a folder named `opdsforcomic.koplugin-main`
3. **Rename it to `opdsforcomic.koplugin`** — KOReader identifies plugins by directory name and will not load it otherwise
4. Move it into `plugins/` and relaunch

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

#### Reading-view buttons

Tap the middle third of the screen to bring up the bottom button bar:

| Button | What it does |
|---|---|
| `Scale` / `Original size` | Toggle between fit-to-screen and native size |
| `Rotate` / `No rotation` | Rotate by 90°, **and switch dual-page spreads with it**; long-press opens the display panel |
| `Go to` | Opens a page-number dialog, **pre-filled with the current page**, titled "Page N of M" |
| `Crop` | Toggles automatic margin trimming; shows a ✓ when on |
| `Close` | Close the viewer |

**Auto crop is off by default.** When on, each page gets a 96×96 sample grid to estimate where the content ends, and the blank margins are trimmed away. When the estimate is not convincing the page is left **exactly as it was**.

The approach is taken from TinyPic / Kindle Comic Converter: detect the background colour from the corners, binarise, take the bounding box of what remains, and bail out at several points if the result looks wrong. The **corner check matters**: manga has black pages, and assuming white would classify the artwork as blank and keep the margins instead.

Cropping only changes what region is displayed in memory. It does not touch the cached bytes and does not affect prefetching. With it on, the log gains a line per page — `crop 2480x3508 -> 120,180..2360,3320`, or `nothing to trim` when the estimate was not convincing.

> TinyPic's page-number pass is not implemented. Telling a page number apart from a small panel at the bottom centre is exactly the kind of guess that silently deletes artwork.

##### Display options (long-press `Rotate`)

| Item | What it does |
|---|---|
| `Rotate 90°` | Same as a tap; closes the panel afterwards |
| `Two pages` | Show two pages side by side |
| `Split two-page scans` | Cut the two pages held in one landscape sheet apart, one to a screen |
| `Right to left` | Puts the first page on the right in two-page mode, and reads the right half first when splitting (the manga convention, on by default) |
| `First page is cover` | Page 1 gets a screen to itself; later spreads are (2,3) (4,5)… |

**There are three display modes — single page, two pages (stitching), split (cutting).** They are exclusive, and turning one on from the panel turns the other off; two-page plus split would put four pages on one screen. The exclusivity is decided in the single place `dualPageOn()` looks at, so the pairing, the page counts and the prefetch depth never have to know the split exists.

**Rotation and dual-page are tied together**: going landscape turns two-page mode on, returning to portrait turns it off — a single page sideways is pointless. The panel's `Two pages` row still works by hand, and a by-hand choice **carries over between chapters**; a rotation-made one does not, so the next chapter opens single-page.

**`Right to left` is live whenever two-page or split is on; `First page is cover` only under two-page** (the split does not need it: a cover holding one page is simply measured and left whole). **`Right to left` is on by default** because this is a manga plugin; turn it off for left-bound books.

Two-page mode is **composited at display time**: two source pages are decoded and stitched into one wide buffer before the viewer sees it, so the cache and the prefetcher keep working in source pages and never learn that two of them are on screen. The pairing rules come from KOReader's bundled comic plugin, `comicreader.koplugin`.

##### Splitting: cutting two-page scans back into single pages

Some releases store a spread as **one landscape image**. Read as it comes it is a page you squint at, and pairing it with its neighbour under two-page mode puts four pages on screen. Switch on `Split two-page scans` and each sheet is measured once, **after decoding and before cropping**:

- `w/h` between **1.15 and 2.1** → the sheet is taken to hold two pages and is **cut at the geometric middle**, one half to a screen.
- Below 1.15 → portrait, shown whole. Above 2.1 → far too wide, more like a strip (a panorama panel, or the scanner's own mess); halving that would slice artwork, so it is shown whole too.

**The verdict rests on the aspect ratio alone** because, between decoding the header and having a picture, that is the only thing known — and the one property that holds at any scan resolution: a manga page is portrait, two of them side by side are landscape. It is 1.15 rather than 1.0 because a scan trimmed to its artwork can come out barely wider than tall, while a genuine pair sits nearer 1.4.

The cut is the geometric middle, with **no gutter detection**: a scan's binding can be a black band, a hairline rule or a crease, and every one of those reads as content or as noise depending on the paper, so a search for it would sometimes land inside a panel. The middle is never wrong by much, and the auto crop trims what is left of the gutter.

> **Known gap: a single page stored rotated a quarter turn is landscape and will be cut in half.** Nothing local tells that apart from a spread, so the cure is to switch the setting off.

With the split on, **numbering gains a second layer**: the *source page* is the nth image in the server's chapter, the *display slot* is one screen of one press of the page key. A spread occupies two slots, so `Go to` and the page counter still work in source pages and the reader never has to convert. Whether a page holds one slot or two is only knowable after decoding, so it is **learned as it is read**: an undecoded page is taken to hold two (the setting is an assertion the reader makes about the chapter, not a guess) and corrected on the spot. The verdict is only ever written on that source page's *first* slot, which counts only the pages before it — so learning the answer cannot make the mapping drift under the reader, and the page on screen does not jump. A chapter of single pages converges to one slot each by itself, and the cover page needs no setting.

**Rotation is the split's temporary switch**: going landscape shows the whole spread uncut (sideways is the pose for looking at a spread anyway) and returning to portrait splits it again. It writes no persistent setting.

Halves are **cut and kept**: rendering one half also cuts the other and caches it (one extra `blitFrom`), so the next screen uses it directly and skips a full re-decode — of the 948 ms a half costs on device, 685 ms is decoding that 12.6 Mpx sheet. The log calls this `via stash`, and turning back hits it too. Only the half next to the reader is kept, since one half is about a 15 MB buffer.

**Closing is the button's job.** The stock one-finger swipe-to-close is disabled: at "scaled for best fit" a tap that drifts a few millimetres is indistinguishable from a short flick on e-ink, and a misread silently drops the whole chapter with nothing on screen to explain it. A multiswipe, the Back key (on devices that have one) and `Close` all still work.

### Caching and Tuning

| | Location | Cap | Lifetime |
|---|---|---|---|
| Memory cache | RAM, raw bytes | 16 MB (about 18 pages) | Cleared when the viewer closes |
| Disk cache | `<data dir>/cache/opdsforcomic_pse/` | 64 MB | **Off** by default |

Lookups go **memory → disk → network**.

**The disk cache is off by default.** Writing a page to the SD card is synchronous and sits on the page-turn path, while device logs showed a zero hit rate. It is pure cost unless you routinely quit and re-open the same chapter. To enable it, set `DISK_CACHE_ENABLED = true`; on-disk filenames are a hash of the page-URL template plus the page index, so different chapters and servers cannot collide, and eviction runs five seconds after a chapter opens so opening never waits on a directory walk.

The knobs live at the top of `opdsforcomic_pse.lua`:

```lua
local PREFETCH_AHEAD = 3          -- pages to keep ready ahead of the current one
local PREFETCH_BEHIND = 2         -- pages to keep ready behind it, for turning back
local PREFETCH_DELAY = 0.35       -- seconds to wait after a page turn before fetching
local PREFETCH_CHAIN_DELAY = 0.25 -- seconds between successive fetches while filling
local PREFETCH_DEFER_DELAY = 0.5  -- seconds to wait before retrying while a dialog is up
local PREFETCH_DEFER_MAX = 20     -- give up after this many retries; the next turn re-arms it

local MEM_CACHE_MAX_BYTES = 16 * 1024 * 1024  -- memory cache cap, in bytes
local MEM_CACHE_MIN_PAGES = 4                 -- pages kept regardless of the cap

local PREFETCH_BLOCK_TIMEOUT = 6  -- per-read timeout for a prefetch, in seconds
local PREFETCH_TOTAL_TIMEOUT = 15 -- total timeout for a prefetch, in seconds

local DISK_CACHE_ENABLED = false  -- see above
local DISK_CACHE_MAX_BYTES = 64 * 1024 * 1024
local DISK_CACHE_MAX_AGE = 30 * 24 * 60 * 60  -- seconds

local MAX_DECODE_SCALE = 0        -- 0 disables it; see below

-- auto crop (the Crop button)
local AUTOCROP_SAMPLES = 96       -- sample grid density, per axis
local AUTOCROP_POWER = 0.6        -- 0..3, higher trims more aggressively
local AUTOCROP_EDGE_BAND = 2      -- grid lines at each edge treated as border
local AUTOCROP_EDGE_NOISE_MAX = 0.02
local AUTOCROP_MIN_GAIN = 0.02    -- do not bother for less than this
local AUTOCROP_MAX_TRIM = 0.35    -- never cut more than this off one side

-- the close-time progress report (see the 0.0.6 changelog entry)
local PROGRESS_REPORT_DELAY = 1   -- seconds to wait after the viewer closes
local PROGRESS_BLOCK_TIMEOUT = 4  -- per-read timeout, in seconds
local PROGRESS_TOTAL_TIMEOUT = 8  -- total timeout, in seconds; tighter than a page turn's
```

`AUTOCROP_POWER` maps to a binarisation threshold of `240 - power*64`, TinyPic's formula, but defaulted to **0.6 rather than their 1.0**: cropping into a screentone is far worse than leaving a margin behind.

**`PREFETCH_CHAIN_DELAY` went from 0.05 to 0.25.** Every step of the chain is a synchronous fetch that owns the UI thread, so a few milliseconds between steps meant several hundred milliseconds of dead input right after each page turn — the moment the reader is most likely to tap something. The window fills at the speed of the link, not of this timer, so the extra quarter second costs almost nothing and leaves a gap for a tap to be served in.

**In two-page mode the window doubles, counted in source pages.** One spread covers two of them, so the depth doubles to keep the same number of spreads ready.

**Why 3 ahead and 2 behind.** Reading forwards consumes one prefetched page per turn and fetches exactly one new one, so in steady state `PREFETCH_AHEAD = 2` and `3` cost the same bandwidth — the difference is only how much slack there is before the reader outruns the link. Depth behind is insurance for jumping backwards past what is still cached.

**The cap is in bytes, not pages**, so a server with large pages simply keeps fewer of them instead of quietly eating memory. At the ~875 KB pages seen in testing, 16 MB holds about 18 pages; at ~3 MB pages it holds about 5 and sits near the `MEM_CACHE_MIN_PAGES` floor.

**Eviction is by distance from the current page, not insertion order.** The prefetcher fills forwards first and backwards second, so evicting oldest-first would drop exactly the pages the reader is about to need.

#### About `MAX_DECODE_SCALE`

Off by default, because it usually costs more than it saves. `ImageViewer` starts at `scale_factor` 0 ("scaled for best fit", see `imageviewer.lua`), so `ImageWidget` scales the image down to the screen regardless. Capping at three times the screen size would make it scale twice, which is a net loss on CPU. A cap of exactly one times the screen makes the second scale a no-op and cuts the memory a page retains, but makes zooming in pointless. Worth revisiting only if the logs show memory rather than network or decode is the bottleneck.

**Nor is there a way to ask the server for a smaller image.** Suwayomi's page endpoint takes only `updateProgress`, `format` and `opds`, and serves the image at its stored resolution with no resizing anywhere (`Page.getPageImageServe` goes through `ImageIO`). The 3–4x oversampling of large pages therefore has **no server-side fix**; the `{maxWidth}` substitution in the code only helps against the few catalogs that offer a width placeholder.

#### About the close-time progress report

The opds-pse protocol has **no endpoint that only records progress**: the server's one per-page hook is "fetch an image with `updateProgress=true`". And the measured cache hit rate is 90%, so **only nine page turns in a hundred actually make a request** — what the server has recorded is really "the last cache miss", usually far behind the page you closed the chapter on.

So closing the viewer **reports once**: one request, with the page number rewritten to the one you left on. Four gates: the catalog's template already carries `updateProgress=true` (a `false` is never rewritten to `true` — that is the catalog's own explicit choice), you really did get further than where the chapter opened, the link is up, and **it happens once per chapter** (having tried, it does not retry). At the ~0.83 MB pages measured, that is about 1% extra traffic per chapter.

**It still runs on the UI thread** (LuaSocket has no async); the one-second delay only lets the file browser paint first, so a hitch lands after the screen has settled rather than removing it. Hence the 4 s / 8 s timeouts, much tighter than a page turn's 6 s / 15 s — nobody is waiting for the answer, so overshooting it is simply given up on.

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
opdsforcomic: page 46: ready in 34 ms via stash as 1800x2790 (half 2 of sheet 23)
opdsforcomic: page 4: two pages on the sheet, splitting
opdsforcomic: progress: reported page 87 in 412 ms
opdsforcomic: prefetch: updateProgress forced to false, page turns stay authoritative
```

The `via` field tells you whether caching is working: `mem`, `disk` and `stash` are hits, `net` means the prefetch did not get there in time. A high proportion of `net` means the network is still the bottleneck. `via stash` marks a half the previous screen cut and kept (see above).

`two pages on the sheet, splitting` / `one page on the sheet` are the split mode's verdicts, one per page; the `(half N of sheet M)` suffix says this is half N of source page M.

The `prefetch:` line appears once per chapter, when the `updateProgress` parameter of a prefetch request has been rewritten (see the 0.0.5 changelog entry). `progress:` appears at most once per chapter too, and is the close-time report (see above); `NOT reported` means it was sent and failed, `not reporting` means the reader had not moved forward and it was skipped by design.

### Known Limitations

- **Prefetching is blocking.** KOReader has no thread pool, so prefetches run on the main thread. Timeouts are 6 s / 15 s, bounding the worst-case stall at fifteen seconds. A prefetch now stands aside while a dialog is open (see above), but the page-turn path itself is still synchronous. The thorough fix is chunked non-blocking downloads with `socket.select`, not implemented.
- **Upstream fixes do not flow in.** This is a full fork; KOReader's fixes to `opds.koplugin` will not arrive automatically and must be merged by hand.
- **Inherited behaviour**: the Kavita-specific progress lookup (`getLastPage`) throws on non-Kavita servers such as Suwayomi and is caught by `pcall`, so streaming always starts at page 1.
- **Under the split, the expensive screen is the first look at a spread.** The whole sheet has to be decoded before it can be measured and halved (948 ms measured on 12.6 Mpx); the other half is then served from the cache (`via stash`, about 34 ms). A chapter of single pages pays none of this.
- **No HTTP connection reuse.** Each page opens a new TCP connection. The comment in `socketutil.lua` warns that connection reuse via a custom `create` function is error-prone under HTTPS, so it was left alone.

### Changelog

**0.0.6**

- Added a **split display mode** (`Split two-page scans` in the panel on a long press of `Rotate`). Some releases store a spread as one landscape image: read as it comes it is too small, and two-page mode would put four pages on screen. Switch it on and each sheet is measured once after decoding and before cropping — `w/h` between 1.15 and 2.1 means two pages, so the sheet is **cut at the geometric middle** and `Right to left` decides which half is read first. The verdict rests on the aspect ratio alone, so it holds at any scan resolution. **Known gap: a single page stored rotated a quarter turn is landscape and will be cut in half** — nothing local can tell it from a spread.
- **Three display modes are now exclusive**: single page, two pages (stitching), split (cutting). The exclusivity is decided in the one place `dualPageOn()` looks at, so the pairing, the page counts and the prefetch depth never have to know the split exists; turning one on from the panel turns the other off. The prefetch window is **halved** under the split, since one spread takes two screens to read.
- **Numbering gained a second layer: source page versus display slot.** A spread occupies two slots, while `Go to` and the page counter stay in **source pages** (the nth image in the server's chapter), so the reader never converts anything. How many slots a page holds is only knowable after decoding, so it is **learned as it is read**: undecoded pages count as two, and the verdict is written only on that source page's first slot — so the mapping cannot drift and the page on screen does not jump. A chapter of single pages converges to one slot each, and the cover needs no setting.
- **Rotation is the split's temporary switch**: landscape shows the whole spread uncut, portrait splits it again, and no persistent setting is written.
- **The other half of a spread is kept** (`via stash` in the log). Rendering one half also cuts the other and holds it for the next screen — of the 948 ms a half costs, 685 ms is decoding that 12.6 Mpx sheet, and this adds one `blitFrom`. Only the half next to the reader is kept; one half is about a 15 MB buffer.
- **Halves and whole pages keep their crop boxes apart**, so a box measured on the whole page cannot be applied to a half of it.
- **One progress report at chapter close.** The server's only per-page hook is "fetch an image with `updateProgress=true`", and a 90% cache hit rate means very few real requests — so recorded progress sat still. Closing the viewer now sends one request with the page number rewritten to the page left on (about 1% extra traffic per chapter). It is skipped when the reader has not moved forward, when the catalog does not ask for it, and when the link is down; once per chapter, and no retry after a failure.

**0.0.5**

- **Fixed prefetching pushing the server's reading position ahead of the reader.** Suwayomi's page template hard-codes `updateProgress=true` into the URL (`.../page/{pageNumber}?updateProgress=true&opds=true`) and the plugin passed it through untouched. That is right for a page the reader actually turned to, and wrong for a prefetch, which serves pages they have not reached yet. Two consequences: the pages fetched ahead are what the server records as the reading position, so **progress sits ahead of where the reader actually is**, and a prefetch that reaches the last page **marks the whole chapter read**. Each prefetch also triggered a KOReader sync push. A request that comes from the prefetcher now rewrites that parameter to `false`; real page turns are untouched and still report progress.

**0.0.4**

- Added **dual-page spreads**: two pages side by side, with `Right to left` (on by default — this is manga) and `First page is cover`. The pairing rules come from the bundled `comicreader.koplugin`. Two-page mode is **composited at display time** — two source pages are decoded and stitched into one wide buffer — so the cache and the prefetcher keep working in source pages.
- Added a **display panel on a long press of `Rotate`**: rotation, two-page mode, reading direction, and whether the first page stands alone. The last two rows are greyed out while two-page mode is off.
- **Rotation and dual-page are tied together**: landscape turns two-page mode on, portrait turns it off. A by-hand choice carries over between chapters; a rotation-made one does not — otherwise the next chapter would open two-page while upright.
- **Disabled one-finger swipe-to-close.** At "scaled for best fit" a tap that drifts a few millimetres is indistinguishable from a short flick on e-ink, and a misread silently drops the whole chapter. `Close`, the Back key and a multiswipe all still work.
- **Removed a wasted re-decode on rotate.** With cropping off (the default) rotating no longer re-renders the page — the decoded buffer is reused and only the angle is recomputed. With cropping on it still has to, because a rotated view skips the crop. The Crop toggle no longer renders the page twice either.
- **Fixed the direction of memory eviction.** Eviction meant to drop the pages furthest from the reader but measured distance with a spread number where a source-page number belongs; in two-page mode that put the origin behind the reader, so it preferentially dropped the pages **ahead** of them. The symptom was re-downloading when turning forwards.
- **Prefetching yields to dialogs.** The fetch is synchronous, so an open panel or input box used to freeze the UI along with it. It now pauses and retries every 0.5 s, up to about ten seconds; a page turn re-arms the chain.
- The prefetch chain's step delay went from 0.05 s to 0.25 s, giving the UI thread room to breathe. The window fills at the speed of the link, so this costs almost nothing.

**0.0.3**

- Added a **Go to** button: the page-number dialog is **pre-filled with the current page** and titled "Page N of M".
- Added a **Crop** toggle for trimming blank margins (off by default). The approach is from TinyPic / Kindle Comic Converter: detect the background colour from the corners — **manga has black pages, and assuming white crops the artwork and keeps the margins** — binarise, take the bounding box, and bail out conservatively at several points. Sampling is a 96×96 grid rather than a per-pixel scan, because Lua cannot walk a full-resolution scan on this hardware.
- The new button labels carry their own Chinese and English text: KOReader's gettext only reads `l10n/<lang>/koreader.mo` from the install root, and **a plugin cannot register a catalogue of its own** (neither the core nor any bundled plugin does).
- TinyPic's page-number pass is not implemented: small payoff, and getting it wrong **silently deletes artwork**.

**0.0.2**

- **Fixed a crash that took KOReader down.** The `__index` metamethod's first parameter was named `_`, shadowing the gettext function in the same file, so any page that failed to load reached `_("...")` and died with `attempt to call local '_' (a table value)`. Upstream has the same trap at `opdspse.lua:106`, but only on the rare invalid-protocol branch; adding a failure notice here turned it into a common path.
- **Much smoother page turns.** Prefetch timeouts went from 4s/10s to 6s/15s. The shorter ones were killing merely-slow pages, which were then retried 2.5 s later — fetching them twice. On device, the slowest single fetch fell from 3–4 s to **785 ms**, an order of magnitude less variance.
- **The memory cache is capped in bytes** (16 MB) rather than pages, so a server with large pages keeps fewer of them instead of quietly eating memory.
- **Eviction is by distance from the current page**, not insertion order — the latter dropped exactly the pages the reader was about to need whenever memory ran short.
- Look-ahead widened from 2 to 3 pages, look-behind from 1 to 2.
- The prefetch chain no longer re-waits 0.35 s between steps (`PREFETCH_CHAIN_DELAY`), so the window fills sooner.
- **The disk cache is now off by default.** Writing a page to the SD card is synchronous and sits on the page-turn path, and device logs showed a zero hit rate.
- Added a guard that stops the prefetch chain when the window does not fit in the memory cache, rather than refetching the same pages forever.
- The release archive now contains an `opdsforcomic.koplugin` folder, so it is unzip-and-drop with **no renaming**.

**0.0.1**

- Initial test release.

### License

**AGPL-3.0** (GNU Affero General Public License v3.0). Full text in [LICENSE](LICENSE).

This is an obligation rather than a choice: the plugin is a derivative work of KOReader's bundled `opds.koplugin`, and KOReader is licensed AGPL-3.0. Derivative works must carry the same license.

The practical difference from the GPL is **section 13**: if you run a modified version as a network service for others, you must offer those users the corresponding source. Personal use is unaffected.
