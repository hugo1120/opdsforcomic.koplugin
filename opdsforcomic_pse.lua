local DataStorage = require("datastorage")
local http = require("socket.http")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local ltn12 = require("ltn12")
local Notification = require("ui/widget/notification")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local url = require("socket.url")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template

local OPDSPSE = {}

--[[--
Page prefetching and caching.

The stock plugin fetches each page lazily on the UI thread: page N is
requested only when the viewer asks for it, blocking on a full HTTP round
trip followed by a JPEG decode. On a slow device over a slow link that makes
every page turn wait.

This fork keeps pages either side of the current one ready:

  * memory cache, raw image bytes, small and evicted oldest-first
  * disk cache, so a chapter that was read once does not need the network
    again after a restart or when navigating far back
  * the next pages are fetched in the background while the reader is still
    looking at the current page

Only raw bytes are cached, never decoded BlitBuffers. The ImageViewer owns
and frees whatever buffer it is handed (see the page_table.image_disposable
note in streamPages), so holding decoded buffers here would risk handing it
an already-freed one.
]]

--- Number of pages kept ready ahead of / behind the current page.
---
--- Depth ahead is nearly free in steady state: reading forwards consumes one
--- prefetched page per turn and fetches exactly one new one, so 2 and 3 cost
--- the same bandwidth and differ only in how much slack there is before the
--- reader outruns the link. Depth behind is insurance for jumping backwards
--- past what is still cached.
local PREFETCH_AHEAD = 3
local PREFETCH_BEHIND = 2
--- How long to wait after a page turn before fetching, in seconds. Lets the
--- e-ink refresh settle before the UI thread blocks on a fetch.
local PREFETCH_DELAY = 0.35
--- Delay between successive fetches while filling the window. Shorter than
--- PREFETCH_DELAY, which exists to let a page turn settle, but no longer
--- near-zero: each step is a *synchronous* fetch that owns the UI thread, so
--- back-to-back steps meant several hundred milliseconds of dead input right
--- after every page turn — the moment the reader is most likely to tap
--- something. The window fills at the speed of the link, not of the timer, so
--- a quarter second between steps costs almost nothing and leaves room for a
--- tap to be served in between.
local PREFETCH_CHAIN_DELAY = 0.25
--- When a dialog is on top of the viewer, a prefetch is postponed by this
--- much and retried, up to PREFETCH_DEFER_MAX times, instead of blocking the
--- UI thread behind an open dialog. Roughly ten seconds of patience in total.
local PREFETCH_DEFER_DELAY = 0.5
local PREFETCH_DEFER_MAX = 20
--- Memory cache bound, in bytes rather than pages, so a server with large
--- pages keeps fewer of them instead of quietly eating memory. MIN_PAGES is
--- the floor that keeps it usable even when a single page is huge.
local MEM_CACHE_MAX_BYTES = 16 * 1024 * 1024
local MEM_CACHE_MIN_PAGES = 4
--- Prefetch timeouts, in seconds. Shorter than the ones used for a
--- user-initiated page turn, because a prefetch blocks the UI unannounced
--- while the reader is looking at another page — but not so short that a
--- merely slow page gets killed and fetched twice.
local PREFETCH_BLOCK_TIMEOUT = 6
local PREFETCH_TOTAL_TIMEOUT = 15
--- Consecutive prefetch failures before the look-ahead chain is left down for
--- PREFETCH_COOLDOWN. Three rather than one: a single timeout usually means the
--- network had a moment, and the attempt after it tends to succeed.
local PREFETCH_FAIL_MAX = 3
--- How long the chain stays down once that happens, in seconds. Long enough for
--- a Wi-Fi reassociation to complete, short enough that the reader never has to
--- do anything to get prefetching back.
local PREFETCH_COOLDOWN = 45

--- The close-time progress report. How long to wait after the viewer closes
--- before sending it, and the timeouts for the request itself, in seconds.
---
--- Much tighter than a page turn's: nobody is waiting for an answer, but the
--- request is synchronous and owns the UI thread, so overshooting it is felt as
--- the file browser freezing. The delay exists so the browser has painted and
--- the hitch, if there is one, lands after the screen has settled.
local PROGRESS_REPORT_DELAY = 1
local PROGRESS_BLOCK_TIMEOUT = 4
local PROGRESS_TOTAL_TIMEOUT = 8

--- On-disk page cache. Off by default: writing a page to the SD card is
--- synchronous and sits on the page-turn path, which costs more than it
--- saves unless the reader actually revisits chapters. Measured logs showed
--- zero disk hits in a normal session. Turn it on if you re-read chapters
--- and would rather pay at fetch time than at open time.
local DISK_CACHE_ENABLED = false
local DISK_CACHE_SUBDIR = "opdsforcomic_pse"
local DISK_CACHE_MAX_BYTES = 64 * 1024 * 1024
--- Pages already on disk are trusted only for this long, in seconds.
local DISK_CACHE_MAX_AGE = 30 * 24 * 60 * 60

--- Downscale images to at most this multiple of the screen size before handing
--- them to the viewer. 0 disables it, and it is disabled by default.
---
--- This is off because it usually costs more than it saves: the ImageViewer
--- starts at scale_factor 0 ("scaled for best fit", see imageviewer.lua), so
--- ImageWidget scales the buffer down to the screen anyway. Capping at 3x the
--- screen would make it scale twice — once here, once there — for no CPU gain.
--- A cap of exactly 1x would make the second scale a no-op and cut the memory
--- a page retains (a full-resolution scan can be tens of MB), but it would also
--- make zooming in pointless. Worth revisiting only if the logs show memory
--- pressure rather than network or decode being the bottleneck.
local MAX_DECODE_SCALE = 0

--- How many finished spread halves the stash keeps, least recently used first
--- out.
---
--- Three, and the number is derived rather than tuned. The stash holds both
--- halves of a sheet now (see renderSlot), so the question is which three. Read
--- a spread left to right and the slots go h1 sN, h2 sN, h1 sN+1, h2 sN+1. A
--- slot is only ever reached without a decode if it is already resident, and
--- the slots that can be reached that way are the neighbours of where the
--- reader is: sitting on h1 sN that is {h2 sN ahead, h2 sN-1 behind}, and
--- sitting on h2 sN it is {h1 sN behind}. The largest set that covers every
--- position at once is {h1 sN, h2 sN, h2 sN-1} -- three. Depth two loses the
--- first member, which is why a back turn onto the *front* half of a sheet
--- re-decoded; depth four buys nothing at all.
---
--- Measured on this panel: a stashed half costs ~140 ms to hand over against
--- ~1180 ms to decode, cut and crop a fresh one, and a chapter's log showed
--- seven of twenty-seven screens rendered more than once, all of them front
--- halves -- 10.1 s of a 43-render session spent decoding pictures the reader
--- had already seen.
---
--- The bill is memory, and it is the reason this is a constant rather than a
--- hard-coded 3. Each entry is a full-resolution BBRGB24 half, 15-16 MB on this
--- panel, so depth three holds ~47 MB. Counting the short-lived sheet (35.9 MB)
--- and the two uncut halves (17.9 MB each) that exist at the same time, one
--- spread render peaks near 141 MB of decoded buffers; KOReader itself sits
--- somewhere between 30 MB and 140 MB depending on how long it has been reading
--- manga. On a 512 MB device that is fine -- the project's own guidance is that
--- 200-300 MB is still survivable -- but it is not free, MAX_DECODE_SCALE is
--- the lever if it ever stops fitting, and the sanity check is the "High memory
--- usage" alarm, which reads the process RSS out of /proc/self/statm and so
--- does see these buffers.
local STASH_DEPTH = 3

--- Auto page crop, trimming blank margins. Off by default: it costs a grid of
--- pixel reads per page and it can only ever guess.
---
--- The approach follows TinyPic / Kindle Comic Converter, which detect the
--- background colour from the corners, binarise, and take the bounding box of
--- what is left, with several chances to bail out and leave the page alone.
--- The one deliberate difference is sampling: those tools scan every pixel
--- through PIL, which is far too slow in Lua on this class of device. Page
--- margins are large relative to the page, so a coarse grid resolves them.
---
--- TinyPic also offers a page-number pass. It is not implemented here: it has
--- to tell a page number from a small panel sitting at the bottom centre, and
--- getting that wrong silently deletes artwork.
local AUTOCROP_KEY = "opdsforcomic_autocrop"
local AUTOCROP_SAMPLES = 96        -- grid points per axis
--- 0..3, mapped to a binarisation threshold of 240 - power*64, as TinyPic
--- does. Kept well below TinyPic's default of 1.0: cropping into a light
--- screentone is far worse than leaving a margin behind.
local AUTOCROP_POWER = 0.6
local AUTOCROP_EDGE_BAND = 2       -- outermost grid lines treated as border
local AUTOCROP_EDGE_NOISE_MAX = 0.02
local AUTOCROP_MIN_GAIN = 0.02     -- ignore trims smaller than this fraction
local AUTOCROP_MAX_TRIM = 0.35     -- never cut more than this off one side

--- The plugin cannot ship a translation catalogue of its own: KOReader's
--- gettext only ever reads l10n/<lang>/koreader.mo from the install root
--- (see gettext.lua), and no bundled plugin carries one. So the few labels
--- added here bring their own two languages.
local function L(en, zh)
    local lang = _.current_lang
    if lang and lang:sub(1, 2) == "zh" then return zh end
    return en
end

--- Showing two pages at once, laid out the way the KOReader comic plugin
--- (comicreader.koplugin) does it, which is also where the pairing rules and
--- the "first page is cover" idea come from.
---
--- Here it is a display-time composite rather than a reader-level one: the
--- page-stream path hands ImageViewer a single buffer, so two pages are
--- decoded and stitched into one wide image before display. Prefetching is
--- untouched by any of this, because it caches raw bytes per source page
--- regardless of how many of them end up side by side.
local DUAL_KEY = "opdsforcomic_dual_page"
local DUAL_RTL_KEY = "opdsforcomic_dual_rtl"
local DUAL_COVER_KEY = "opdsforcomic_dual_cover"
--- Remembers whether the current DUAL_KEY value came from the rotation or from
--- a by-hand toggle. Rotation and dual-page are tied together, but only
--- dual-page is persisted: without this flag a chapter opened right after a
--- rotated one would come up two-page while upright. Tracking the origin lets
--- an automatic value be dropped on entry while a by-hand choice carries over.
local DUAL_AUTO_KEY = "opdsforcomic_dual_auto"

--- Left-handed hold: the whole screen flipped upside down (180°).
---
--- The reader flips the *device*, not the page, and that is what makes this
--- free. KOReader's input layer answers a 180° screen rotation by swapping the
--- physical page-turn keys (input.lua: the DEVICE_ROTATED_UPSIDE_DOWN row of
--- rotation_map turns LPgFwd into LPgBack, RPgFwd into RPgBack, Up into Down),
--- so flipping the screen flips the buttons too -- exactly what a left-hand
--- grip needs, with nothing for this file to remap by hand. A by-hand toggle
--- while reading applies immediately; the setting is recalled when a chapter
--- opens, and the rotation is put back when the viewer closes, so the file
--- manager does not come up upside down.
local INVERT_KEY = "opdsforcomic_invert180"
local INVERT_180 = 2 -- rotation modes advance in 90° steps; +2 is upside down.

--- Cutting a two-page scan into the two pages it holds.
---
--- Some releases store a spread as one landscape image. Read as it comes it is
--- a page to squint at, and pairing it with its neighbour under dual-page
--- would put four pages on screen. So each sheet is measured, and when it
--- really does hold two pages the reader is shown one of them at a time.
---
--- The verdict rests on the sheet's aspect ratio, because that is the only
--- thing known about an image before it is decoded -- and the one property
--- that holds at any scan resolution. A manga page is portrait; two of them
--- side by side are landscape. 1.15 rather than 1.0 because a scan trimmed to
--- its artwork loses most of its margin and can come out barely wider than
--- tall, while a genuine pair sits nearer 1.4. The upper bound is there
--- because past roughly two pages' worth of width the sheet is a strip -- a
--- panorama panel, or the scanner's own mess -- and halving that would slice
--- artwork instead of separating pages.
---
--- What no ratio can catch is a scan stored rotated a quarter turn: a lone
--- page in that state is landscape and would be cut in half. Nothing local
--- tells that apart from a spread, so the cure is to turn the setting off.
local SPLIT_KEY = "opdsforcomic_split_spread"
local SPLIT_MIN_ASPECT = 1.15
local SPLIT_MAX_ASPECT = 2.1

local function splitOn()
    return G_reader_settings:isTrue(SPLIT_KEY)
end

--- Does this sheet hold two pages?
local function looksLikeSpread(w, h)
    if not w or not h or h <= 0 then return false end
    local aspect = w / h
    return aspect >= SPLIT_MIN_ASPECT and aspect <= SPLIT_MAX_ASPECT
end

local function dualPageOn()
    -- Never alongside the split: gluing two spreads together would put four
    -- pages on one screen. Deciding it in this one place rather than at each
    -- call site means the pairing, the page counts and the prefetch depth all
    -- follow without having to know the split exists.
    if splitOn() then return false end
    return G_reader_settings:isTrue(DUAL_KEY)
end

--- Right to left unless the reader says otherwise: this is a manga plugin.
--- One direction for the whole plugin: it decides which page of a pair goes on
--- the right when two are stitched together, and which half of a sheet is read
--- first when one is cut in two.
local function rtlReading()
    local v = G_reader_settings:readSetting(DUAL_RTL_KEY)
    return v == nil or v == true
end

local function dualCoverFirst()
    return G_reader_settings:isTrue(DUAL_COVER_KEY)
end

--- Source pages (1-based) making up a 1-based spread.
---
--- Without a cover the spreads are (1,2) (3,4) (5,6)…; with one, page 1
--- stands alone and the spreads become (2,3) (4,5) (6,7)… — that shift is
--- the whole point of the setting, since a scanned cover otherwise gets
--- paired with the first story page and every later pair is out by one.
local function spreadPages(spread, pages)
    if not dualPageOn() then return { spread } end
    local base
    if dualCoverFirst() then
        if spread <= 1 then return { 1 } end
        base = 2 * (spread - 1)
    else
        base = 2 * spread - 1
    end
    if base > pages then return {} end
    local out = { base }
    if base + 1 <= pages then out[#out + 1] = base + 1 end
    return out
end

local function spreadCountOf(pages)
    if not dualPageOn() then return pages end
    if pages < 1 then return 0 end
    if dualCoverFirst() then
        return 1 + math.floor((pages - 1) / 2)
    end
    return math.ceil(pages / 2)
end

--- Inverse of spreadPages: which spread holds a given 1-based source page.
local function spreadOfPage(page)
    if not dualPageOn() then return page end
    if dualCoverFirst() then
        if page <= 1 then return 1 end
        return math.floor(page / 2) + 1
    end
    return math.ceil(page / 2)
end

local LOG_PREFIX = "opdsforcomic: "
local function log(fmt, ...)
    if select("#", ...) > 0 then
        logger.dbg(LOG_PREFIX .. string.format(fmt, ...))
    else
        logger.dbg(LOG_PREFIX .. fmt)
    end
end

-- NOTE: ffi/util's getTimestamp() returns *seconds* (secs + usecs/1e6), not
-- milliseconds. Keep the timestamps in that unit and convert only the delta,
-- so the arithmetic stays in double precision.
local function now()
    return ffiUtil.getTimestamp()
end

local function elapsedMs(started)
    return math.floor((ffiUtil.getTimestamp() - started) * 1000)
end

--- djb2, kept in double range so it stays exact. Filenames only need to be
--- stable and collision-rare, not cryptographic.
local function hashKey(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x%x", h, #s)
end

local disk_cache_dir
local disk_cache_unavailable = false

local function getDiskCacheDir()
    if disk_cache_unavailable or not DISK_CACHE_ENABLED then return nil end
    if disk_cache_dir then return disk_cache_dir end
    local dir = DataStorage:getDataDir() .. "/cache/" .. DISK_CACHE_SUBDIR
    if not util.directoryExists(dir) then
        local ok = util.makePath(dir)
        if not ok or not util.directoryExists(dir) then
            log("disk cache unavailable, continuing memory-only")
            disk_cache_unavailable = true
            return nil
        end
    end
    disk_cache_dir = dir
    return dir
end

--- `key` identifies a page uniquely: the catalog's page-URL template plus the
--- page index. Hashing only the index would make different chapters and
--- different servers collide on the same cache file.
local function diskCachePath(key)
    local dir = getDiskCacheDir()
    if not dir then return nil end
    return dir .. "/" .. hashKey(key)
end

local function diskCacheGet(key)
    local path = diskCachePath(key)
    if not path then return nil end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    if attr.modification and os.time() - attr.modification > DISK_CACHE_MAX_AGE then
        os.remove(path)
        return nil
    end
    local data = util.readFromFile(path, "rb")
    if not data or #data == 0 then
        os.remove(path)
        return nil
    end
    return data
end

local function diskCachePut(key, data)
    local path = diskCachePath(key)
    if not path or not data then return end
    util.writeToFile(data, path, false, false, false)
end

--- Existence check without reading the file, so the prefetcher can skip a
--- page that is already on disk instead of downloading it again.
local function diskCacheHas(key)
    local path = diskCachePath(key)
    if not path then return false end
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

--- Trims the cache back under its size cap, oldest files first. Runs on a
--- scheduled callback rather than inline, so opening a chapter never waits
--- on a directory walk.
local function diskCacheEvict()
    local dir = getDiskCacheDir()
    if not dir then return end
    local files, total = {}, 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                local size = attr.size or 0
                total = total + size
                table.insert(files, {
                    path = path, size = size, mtime = attr.modification or 0,
                })
            end
        end
    end
    if total <= DISK_CACHE_MAX_BYTES then
        log("disk cache: %d files, %.1f MB", #files, total / 1048576)
        return
    end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    local removed, freed = 0, 0
    for _, f in ipairs(files) do
        if total <= DISK_CACHE_MAX_BYTES then break end
        if os.remove(f.path) then
            total = total - f.size
            freed = freed + f.size
            removed = removed + 1
        end
    end
    log("disk cache: evicted %d files (%.1f MB), %.1f MB left",
        removed, freed / 1048576, total / 1048576)
end

--- Renders image bytes, downscaling first if the image is much larger than
--- the screen. Returns nil if the bytes could not be decoded at all.
--- Reads the page on a coarse grid and reports which samples look like ink.
---
--- Everything downstream works off this grid rather than the pixels: a
--- full-resolution scan is tens of millions of pixels and Lua is in no
--- position to walk them on this hardware.
local function samplePage(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 16 or h < 16 then return nil end

    local cols = math.min(AUTOCROP_SAMPLES, w)
    local rows = math.min(AUTOCROP_SAMPLES, h)

    local lum = {}
    for r = 1, rows do
        local y = math.floor((r - 0.5) * h / rows)
        local row = {}
        for c = 1, cols do
            local x = math.floor((c - 0.5) * w / cols)
            local px = bb:getPixel(x, y)
            -- getColor8() reduces every buffer type to a 0..255 grey.
            row[c] = px and px:getColor8().a or 255
        end
        lum[r] = row
    end

    -- Background from the four corners. Manga has black pages as well as
    -- white ones, and assuming white on a black page would invert the whole
    -- decision — cropping the artwork away and keeping the margins.
    local corners = (lum[1][1] + lum[1][cols] + lum[rows][1] + lum[rows][cols]) / 4
    local invert = corners <= 128

    local threshold = 240 - AUTOCROP_POWER * 64
    local content, col_hits, row_hits = {}, {}, {}
    for c = 1, cols do col_hits[c] = 0 end
    for r = 1, rows do
        row_hits[r] = 0
        content[r] = {}
        for c = 1, cols do
            local v = lum[r][c]
            if invert then v = 255 - v end
            if v <= threshold then
                content[r][c] = true
                col_hits[c] = col_hits[c] + 1
                row_hits[r] = row_hits[r] + 1
            else
                content[r][c] = false
            end
        end
    end

    return {
        w = w, h = h, cols = cols, rows = rows,
        content = content, col_hits = col_hits, row_hits = row_hits,
    }
end

--- Clears content from the outermost grid lines when they hold only a trace
--- of it. A speck or two of scanner noise on the very edge would otherwise
--- pin the bounding box to the page border and defeat the crop entirely.
--- TinyPic's ignore_pixels_near_edge, run on the sampled grid.
local function clearEdgeNoise(a)
    local function clearLine(is_row, idx)
        local total = is_row and a.cols or a.rows
        local hits = is_row and a.row_hits[idx] or a.col_hits[idx]
        if hits == 0 or hits / total >= AUTOCROP_EDGE_NOISE_MAX then return end
        for i = 1, total do
            local r = is_row and idx or i
            local c = is_row and i or idx
            if a.content[r][c] then
                a.content[r][c] = false
                a.row_hits[r] = a.row_hits[r] - 1
                a.col_hits[c] = a.col_hits[c] - 1
            end
        end
    end
    for k = 1, AUTOCROP_EDGE_BAND do
        clearLine(true, k)
        clearLine(true, a.rows - k + 1)
        clearLine(false, k)
        clearLine(false, a.cols - k + 1)
    end
end

--- Grid cells back to page pixels, padded by one cell. A cell is about the
--- resolution of the measurement, so that slack is what keeps the crop from
--- shaving a sliver off the artwork.
local function gridBBox(a)
    local top, bottom, left, right
    for r = 1, a.rows do
        if a.row_hits[r] > 0 then
            top = top or r
            bottom = r
        end
    end
    for c = 1, a.cols do
        if a.col_hits[c] > 0 then
            left = left or c
            right = c
        end
    end
    if not top or not left then return nil end

    local pad_x = math.ceil(a.w / a.cols)
    local pad_y = math.ceil(a.h / a.rows)
    local x0 = math.max(0, math.floor((left - 1) * a.w / a.cols) - pad_x)
    local y0 = math.max(0, math.floor((top - 1) * a.h / a.rows) - pad_y)
    local x1 = math.min(a.w, math.floor(right * a.w / a.cols) + pad_x)
    local y1 = math.min(a.h, math.floor(bottom * a.h / a.rows) + pad_y)
    return x0, y0, x1, y1
end

--- Returns a crop box, or nil to leave the page alone.
local function measureCrop(bb)
    local a = samplePage(bb)
    if not a then return nil end
    clearEdgeNoise(a)

    local x0, y0, x1, y1 = gridBBox(a)
    if not x0 then return nil end

    -- Bail out unless the crop both gains something and stays sane. This is
    -- guesswork on a sampled grid: doing nothing is always an acceptable
    -- answer, cropping into the artwork is not.
    local w, h = a.w, a.h
    if x0 > w * AUTOCROP_MAX_TRIM or (w - x1) > w * AUTOCROP_MAX_TRIM then return nil end
    if y0 > h * AUTOCROP_MAX_TRIM or (h - y1) > h * AUTOCROP_MAX_TRIM then return nil end
    local gain_x = (x0 + (w - x1)) / w
    local gain_y = (y0 + (h - y1)) / h
    if gain_x < AUTOCROP_MIN_GAIN and gain_y < AUTOCROP_MIN_GAIN then return nil end
    if x1 - x0 < w * 0.2 or y1 - y0 < h * 0.2 then return nil end

    return { x0, y0, x1, y1 }
end

--- Tone: the "washed-out" / "too dark" cure, as one gamma slider.
---
--- Linear contrast (raise the numbers) needs a negative offset for the bright
--- side, and no BlitBuffer C primitive accepts one. A gamma curve,
--- out = 255*(in/255)^g does what the two complaints actually want: over 1
--- darkens the midtones, under 1 brightens them, black and white stay put.
--- fz_gamma_pixmap is that curve in C; KOReader's PDF reader exposes it as
--- its Contrast slider.
---
--- Verified on this device by a throwaway probe before writing any of this:
--- a plugin may ffi.loadlib("wrap-mupdf") and build its own fz_context (the
--- version string must match the library, so it is read out of ffi/mupdf.lua
--- rather than hardcoded); and one pass over a half-page (1994x3000) measured
--- ~54 ms. The probe only stood up the gray path (TYPE_BB8, JPEG pages via
--- TurboJPEG); PNG pages take MuPDF's renderImage, which hands back BBRGB24,
--- so that path is driven with fz_device_rgb on the same layout assumption
--- (stride walked as given) and is being validated on device now.
local DARKEN_KEY = "opdsforcomic_darken"
local DARKEN_DEFAULT = 1.0

--- The gammas the tone control walks through, brightest first.
---
--- One list rather than a range, because the two directions cannot share a
--- step. Brightening is steep -- 0.5 is already obvious on a scan -- so 0.1 is
--- the useful resolution and the whole bright side is five rungs. Darkening is
--- flat near white: a pow curve with g > 1 mostly eats midtones, so a white 240
--- only falls to 226 at g=2 and 200 at g=4, which means the number has to look
--- absurd before e-ink shows anything -- and walking up there at 0.1 would cost
--- about ninety taps to cross. Hence the coarse 1.0 ladder above 1.0.
---
--- Handed to the SpinWidget as a value_table of *strings*: the widget prints a
--- table entry exactly as it stands, so "1.0" survives as "1.0" rather than the
--- "1" Lua's tostring would make of it.
local TONE_LEVELS = {
    "0.5", "0.6", "0.7", "0.8", "0.9", -- brightening: steep, so fine steps
    "1.0",                             -- untouched
    "2", "3", "4", "5", "6", "7", "8", "9", "10", -- darkening: flat, so coarse
}
--- Where "1.0" sits in the list above, and where a fresh reader starts.
local TONE_DEFAULT_INDEX = 6

--- Where `gamma` sits on that ladder.
---
--- A value off the ladder -- saved by a build whose control was a plain range,
--- or typed into settings.reader.lua by hand -- lands on the nearest rung
--- instead of falling off it, so the dialog always opens on something it can
--- offer. Ties go to the lower rung, which is the one that darkens less.
local function toneIndex(gamma)
    local best, best_gap = TONE_DEFAULT_INDEX, math.huge
    for i = 1, #TONE_LEVELS do
        local gap = math.abs(tonumber(TONE_LEVELS[i]) - gamma)
        if gap < best_gap then
            best, best_gap = i, gap
        end
    end
    return best
end

--- The reader's gamma. 1.0 is "leave it alone". The type check covers both the
--- first shipped build, which stored a boolean here, and a hand-edited
--- settings.reader.lua holding a string: neither is a gamma, and either one
--- would otherwise reach the curve -- or the ladder, which subtracts it.
local function gammaValue()
    local v = G_reader_settings:readSetting(DARKEN_KEY, DARKEN_DEFAULT)
    if type(v) ~= "number" then return DARKEN_DEFAULT end
    return v
end

--- Assigned the real FFI implementation below -- after renderSlot on purpose,
--- so the render path stays testable without a device; a test injects a mock.
local darkenBuffer = nil

--- Applies the curve to a freshly decoded sheet, in place. Returns the sheet
--- unchanged (nil for "nothing happened" so the caller can tell) when the
--- backer cannot run. Never fails the page.
local function applyDarken(bb, gamma_value)
    if not darkenBuffer then return nil end
    return darkenBuffer(bb, gamma_value)
end

local function cropTo(bb, box)
    local w, h = box[3] - box[1], box[4] - box[2]
    if w <= 0 or h <= 0 then return nil end
    local Blitbuffer = require("ffi/blitbuffer")
    local out = Blitbuffer.new(w, h, bb:getType())
    if not out then return nil end
    out:blitFrom(bb, 0, 0, box[1], box[2], w, h)
    return out
end

--- Where half number `side` (1 or 2) sits on a two-page sheet, as a box in the
--- sheet's own coordinates.
---
--- Side 1 is the first page of the pair, and in a right-to-left manga that is
--- the half on the right. The cut is the geometric middle: a scan's gutter can
--- be a black band, a hairline rule or a crease, and every one of those reads
--- as content or as noise depending on the paper, so a search for it would
--- sometimes land inside a panel. The middle is never wrong by much, and the
--- auto crop trims what is left of the gutter when it is switched on.
---
--- Returned as a box rather than as a cut-out buffer because the box is what
--- both callers actually want: one cuts the half as it came off the sheet, the
--- other cuts it with its crop box already applied. Keeping the arithmetic in
--- one place is what stops those two from drifting apart.
local function halfRect(sheet_w, sheet_h, side, rtl)
    local left_w = math.floor(sheet_w / 2)
    if left_w < 1 or sheet_w - left_w < 1 then return nil end
    -- `side == 1` means "the first page of the pair"; rtl puts that page on the
    -- right, so the two only disagree when the reader asked for the other
    -- reading direction.
    if (side == 1) == rtl then
        return { left_w, 0, sheet_w, sheet_h }
    end
    return { 0, 0, left_w, sheet_h }
end

--- Cuts half `rect` out of `sheet` in one pass, applying `box` -- a crop box
--- measured on that half -- at the same time. `box` is a table, or false for a
--- half that was measured and had nothing to trim; the caller only gets here
--- once the box is known either way.
---
--- The offsets add because each box is stated in its own frame: `rect` is in
--- the sheet's coordinates and `box` is in the half's, so the trim is just
--- shifted by where the half sits.
---
--- One pass instead of two is the entire point. Cutting a half out and then
--- trimming it moves the same pixels twice; on this panel the pair measured
--- 293 ms (cut) + 259 ms (crop) of a 1180 ms half render, against ~250 ms for
--- the fused form. It matters most on re-renders, which are what a chapter
--- actually spends its time on: the first render of a half has to cut before
--- there is anything to measure (see renderSlot).
local function cutHalf(sheet, rect, box)
    if box then
        return cropTo(sheet, { rect[1] + box[1], rect[2] + box[2],
                               rect[1] + box[3], rect[2] + box[4] })
    end
    return cropTo(sheet, rect)
end

--- A private copy of a BlitBuffer.
---
--- Needed wherever one buffer has to be kept while the caller carries on using
--- -- and eventually frees -- the original. The page table is marked
--- image_disposable, so the viewer frees whatever the page table hands it;
--- anything the plugin wants to hold past that hand-over has to be a copy.
local function copyBlitbuffer(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local Blitbuffer = require("ffi/blitbuffer")
    local copy = Blitbuffer.new(w, h, bb:getType())
    if not copy then return nil end
    copy:blitFrom(bb, 0, 0, 0, 0, w, h)
    return copy
end

--- Auto crops `bb`, measuring at most once per image. `key` names the image in
--- `cache`: the halves of a sheet are different pictures from the sheet, so
--- they are measured apart, in a table of their own, and named apart in the log
--- so a measured half is not read as a measurement of the whole page.
local function autoCrop(bb, key, cache, label)
    if not G_reader_settings:isTrue(AUTOCROP_KEY) then return bb end
    local box = cache[key]
    if box == nil then
        box = measureCrop(bb) or false
        cache[key] = box
        if box then
            log("%s: crop %dx%d -> %d,%d..%d,%d", label,
                bb:getWidth(), bb:getHeight(), box[1], box[2], box[3], box[4])
        else
            log("%s: nothing to trim", label)
        end
    end
    if box then
        local cropped = cropTo(bb, box)
        if cropped then
            bb:free()
            bb = cropped
        end
    end
    return bb
end

--- Caps a decoded buffer at the decode budget (see MAX_DECODE_SCALE). Frees the
--- input whenever it hands back a different buffer, so callers can just take
--- whatever they are given.
local function fitToDecodeBudget(bb, label)
    if MAX_DECODE_SCALE <= 0 then return bb end
    local w, h = bb:getWidth(), bb:getHeight()
    local max_w = Screen:getWidth() * MAX_DECODE_SCALE
    local max_h = Screen:getHeight() * MAX_DECODE_SCALE
    if w <= max_w and h <= max_h then return bb end
    local ratio = math.min(max_w / w, max_h / h)
    local tw, th = math.floor(w * ratio), math.floor(h * ratio)
    -- free_orig_bb=false: keep the original if scaling fails, so we never
    -- hand back a buffer that was already freed. scaleBlitBuffer returns the
    -- input unchanged when the target size already matches, so only free the
    -- original when we actually got a distinct buffer back.
    local scaled = RenderImage:scaleBlitBuffer(bb, tw, th, false)
    if scaled and scaled ~= bb then
        bb:free()
        log("%s: downscaled %dx%d -> %dx%d", label, w, h, tw, th)
        return scaled
    end
    log("%s: downscale failed, using full size %dx%d", label, w, h)
    return bb
end

--- Decodes one page and returns what one display slot shows of it: the whole
--- page, or the half of it the slot asks for when the sheet turns out to hold
--- two pages. Also reports the verdict, so the caller can remember it.
---
--- Both halves are cut while the sheet is still decoded. The one that is not
--- this slot goes to `stash`; nothing about this page turn needs it, but the
--- screen after this one does, and cutting it there would mean decoding the
--- whole sheet all over again -- by a wide margin the most expensive thing this
--- plugin does. A 12.6 Mpx spread costs ~950 ms that way and ~35 ms this way.
local function renderSlot(data, index, half, rotated, crop_cache, half_crop_cache, stash)
    -- Where a slow page turn actually goes. Everything here but the decode is
    -- this plugin's own work, and on a measured turn that was 551 ms of
    -- 1180 ms -- nearly half, and the reason the work moved off the decoder.
    -- Split into decode / cut / crop / keep so the next round aims at whichever
    -- figure is big rather than at whichever looks big. Each figure is stated on
    -- the measured form: cut and crop are separate only while a half's box is
    -- unknown, and on the fused form the one clip is reported as cut with crop
    -- at zero. The log says which form it was.
    local started = now()
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        log("page %d: decode failed (%d bytes)", index, #data)
        return nil, false
    end
    local decode_ms = elapsedMs(started)
    local gamma_ms, darken_ok = 0, false
    local cut_ms, crop_ms, keep_ms = 0, 0, 0
    local gamma_value = gammaValue()

    --- Curves one finished buffer, timing it. A missing or failing backend
    --- leaves the page as it is, never fails it.
    ---
    --- Applied on the way out, never to the sheet on the way in. The crop has to
    --- measure the pixels the scan actually has: autoCrop calls a sample "ink"
    --- below a fixed threshold (240 - 0.6*64 = 201.6), and a sheet curved first
    --- moves its own background under that line -- white sits at 226 at gamma 2,
    --- 213 at 3 and 200 at 4 -- so from 4 upwards every margin sample counts as
    --- content, the box becomes the whole page, the gain check fails and the
    --- crop quietly stops doing anything. Which is precisely the range this
    --- control exists for. Curving afterwards is cheaper too: the halves it runs
    --- on are already cut and capped.
    ---
    --- Every buffer that leaves here carries the curve, the stashed one
    --- included, or the next page turn would show the same sheet both ways.
    local function tone(buffer)
        if not buffer or gamma_value == DARKEN_DEFAULT then return buffer end
        local gm_started = now()
        local darkened = applyDarken(buffer, gamma_value)
        gamma_ms = gamma_ms + elapsedMs(gm_started)
        if darkened then
            darken_ok = true
            return darkened
        end
        return buffer
    end

    -- Measured on the sheet, before anything is trimmed off it: the ratio is
    -- what the verdict rests on, and a crop would move it. Rotation turns the
    -- whole idea off -- a sideways view is a request to see the spread, not to
    -- be handed half of it.
    local spread = false
    if splitOn() and not rotated and half then
        spread = looksLikeSpread(bb:getWidth(), bb:getHeight())
    end

    if spread then
        local cut_started = now()
        local rtl = rtlReading()
        local mine_rect = halfRect(bb:getWidth(), bb:getHeight(), half, rtl)
        if mine_rect then
            local other_half = half == 1 and 2 or 1
            local other_rect = halfRect(bb:getWidth(), bb:getHeight(), other_half, rtl)
            local mine_key, other_key = index * 2 + half, index * 2 + other_half
            local label = string.format("page %d half %d", index, half)
            local other_label = string.format("page %d half %d", index, other_half)
            local mine, other, fused

            -- Two passes over each half, or four over the pair. A crop box is
            -- measured on the half itself, so the first render of a half has to
            -- cut it out before there is anything to measure -- four passes,
            -- exactly as it always was. The answer is then kept in
            -- half_crop_cache, and from that half's second render onwards the
            -- box is known and the sheet can be clipped straight to the trimmed
            -- half. A chapter spends most of its renders on repeats, so the
            -- expensive form is now the rare one.
            if half_crop_cache[mine_key] ~= nil and half_crop_cache[other_key] ~= nil then
                mine = cutHalf(bb, mine_rect, half_crop_cache[mine_key])
                other = other_rect and cutHalf(bb, other_rect, half_crop_cache[other_key]) or nil
                fused = true
                cut_ms = elapsedMs(cut_started)
            else
                mine = cropTo(bb, mine_rect)
                other = other_rect and cropTo(bb, other_rect) or nil
                cut_ms = elapsedMs(cut_started)
                local crop_started = now()
                -- Each half is measured on its own rather than inheriting the
                -- sheet's box: it carries one outer margin and one gutter, and
                -- both are the crop's business. Measured separately from this
                -- half for the same reason, which is also why the two live in
                -- half_crop_cache and not in crop_cache.
                if mine then mine = autoCrop(mine, mine_key, half_crop_cache, label) end
                if other then other = autoCrop(other, other_key, half_crop_cache, other_label) end
                crop_ms = elapsedMs(crop_started)
            end

            if mine then
                bb:free()
                bb = mine
                -- The cap sits outside the timed windows: it belongs to the
                -- buffer either way, and at MAX_DECODE_SCALE 0 it is a no-op.
                bb = fitToDecodeBudget(bb, label)
                bb = tone(bb)
                if other then
                    other = fitToDecodeBudget(other, other_label)
                    other = tone(other)
                    -- The eviction this may cause is logged by stashHalf itself,
                    -- so a back turn that still decodes can be read from the log.
                    if stash then
                        stash(other_key, other)
                    else
                        other:free()
                    end
                end
                -- Keep the half being handed over too. renderSlot is the only
                -- place that ever holds both halves of a sheet, and without this
                -- the half it returns can never be served from the stash -- which
                -- is why a back turn onto the front half of a sheet, and every
                -- settings change that re-renders the screen under the reader,
                -- paid for the whole decode again. The copy is the price of it:
                -- the viewer frees whatever the page table gives it.
                if stash then
                    local keep_started = now()
                    local kept = copyBlitbuffer(bb)
                    keep_ms = elapsedMs(keep_started)
                    if kept then stash(mine_key, kept) end
                end
                if darken_ok then
                    log("%s: darken %d ms, gamma %.1f", label, gamma_ms, gamma_value)
                end
                log("%s: decode %d ms, cut %d ms, crop %d ms, keep %d ms%s", label,
                    decode_ms, cut_ms, crop_ms, keep_ms, fused and " (fused clip)" or "")
                return bb, true
            elseif other then
                -- The half asked for could not be cut but the other one could.
                -- Nothing to show this turn, and nothing worth keeping it for.
                other:free()
            end
        end
        spread = false
    end

    -- skip_crop while rotated: turning the page sideways is usually about
    -- seeing the whole spread, so trimming it there works against the reader.
    local label = string.format("page %d", index)
    if not rotated then
        local crop_started = now()
        bb = autoCrop(bb, index, crop_cache, label)
        crop_ms = elapsedMs(crop_started)
    end
    bb = fitToDecodeBudget(bb, label)
    bb = tone(bb)
    if darken_ok then
        log("%s: darken %d ms, gamma %.1f", label, gamma_ms, gamma_value)
    end
    log("%s: decode %d ms, cut %d ms, crop %d ms, keep %d ms%s", label,
        decode_ms, cut_ms, crop_ms, keep_ms,
        rotated and " (rotated, crop skipped)" or "")
    return bb, false
end

-- This function attempts to pull chapter progress from Kavita.

--- The real darkenBuffer: an in-place gamma pass through MuPDF.
---
--- Every step that can fail returns nil and leaves the page un-darkened,
--- with a log line naming what was missing; the failure modes that exist on
--- devices are a missing wrap-mupdf or an fz_context the library refuses.
--- Shown pages are never the thing that breaks.
local pse_ffi = require("ffi")
local pse_blitbuffer = require("ffi/blitbuffer")
local pse_cdef_ok, pse_lib, pse_ctx, pse_gray, pse_rgb

local function pseFindModule(name)
    local rel = name:gsub("%.", "/")
    for pattern in package.path:gmatch("[^;]+") do
        local path = pattern:gsub("%?", function() return rel end)
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
end

local function pseFzVersion()
    local f = io.open(pseFindModule("ffi.mupdf"), "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return src and src:match('FZ_VERSION%s*=%s*"([^"]+)"') or nil
end

local function pseGammaContext()
    if pse_ctx then return pse_ctx end
    if not pse_cdef_ok then
        pse_cdef_ok = pcall(pse_ffi.cdef, [[
            fz_context *fz_new_context_imp(const fz_alloc_context *, const fz_locks_context *, size_t, const char *);
            void fz_drop_context(fz_context *);
            fz_colorspace *fz_device_gray(fz_context *);
            fz_colorspace *fz_device_rgb(fz_context *);
            fz_pixmap *mupdf_new_pixmap_with_data(fz_context *, fz_colorspace *, int, int, fz_separations *, int, int, unsigned char *);
            void fz_gamma_pixmap(fz_context *, fz_pixmap *, float);
            void fz_drop_pixmap(fz_context *, fz_pixmap *);
        ]])
        if not pse_cdef_ok then return nil end
    end
    local ok, lib = pcall(pse_ffi.loadlib, "wrap-mupdf")
    if not ok or not lib then
        logger.dbg(string.format("opdsforcomic: tone unavailable: wrap-mupdf (%s)", tostring(lib)))
        return nil
    end
    local version = pseFzVersion()
    local ctx = version and lib.fz_new_context_imp(nil, nil, 32 * 1024 * 1024, version) or nil
    if ctx == nil or ctx == pse_ffi.NULL then
        logger.dbg("opdsforcomic: tone unavailable: no fz_context (version mismatch?)")
        return nil
    end
    pse_lib, pse_ctx = lib, ctx
    pse_gray = lib.fz_device_gray(ctx)
    pse_rgb = lib.fz_device_rgb(ctx)
    return pse_ctx
end

--- The colorspace/alpha pair must match the buffer's own channels or every
--- pixel after the first row lands on the wrong bytes. The gray pair was stood
--- up on device by the probe; the RGB pairs follow the same layout rule
--- (stride walked as given) and are being confirmed on device with this build.
darkenBuffer = function(bb, gamma_value)
    if not bb then return nil end
    local t = bb:getType()
    local colorspace, alpha
    if t == pse_blitbuffer.TYPE_BB8 then
        colorspace, alpha = pse_gray, 0
    elseif t == pse_blitbuffer.TYPE_BB8A then
        colorspace, alpha = pse_gray, 1
    elseif t == pse_blitbuffer.TYPE_BBRGB24 then
        colorspace, alpha = pse_rgb, 0
    elseif t == pse_blitbuffer.TYPE_BBRGB32 then
        colorspace, alpha = pse_rgb, 1
    else
        logger.dbg(string.format("opdsforcomic: tone skipped, unhandled buffer type %s",
            tostring(t)))
        return nil
    end
    local ctx = pseGammaContext()
    if not ctx then return nil end
    local pix = pse_lib.mupdf_new_pixmap_with_data(ctx, colorspace,
        bb:getWidth(), bb:getHeight(), nil, alpha, bb.stride,
        pse_ffi.cast("unsigned char*", bb.data))
    if pix == nil then
        logger.dbg("opdsforcomic: tone skipped: no pixmap (memory?)")
        return nil
    end
    local ok = pcall(function()
        pse_lib.fz_gamma_pixmap(ctx, pix, gamma_value)
    end)
    pcall(function()
        pse_lib.fz_drop_pixmap(ctx, pix)
    end)
    if not ok then
        logger.dbg("opdsforcomic: tone skipped: fz_gamma_pixmap failed")
        return nil
    end
    logger.dbg(string.format("opdsforcomic: tone applied, type %s, gamma %.1f, %dx%d",
        tostring(t), gamma_value,
        bb:getWidth(), bb:getHeight()))
    return bb
end

--- Page turns that come from outside the viewer.
---
--- Nothing is more central to a reader than "turn the page", and for the
--- wrong reasons it is the first thing to break here. KOReader drives remote
--- controls and a reader's physical keys with the same GotoViewRel event
--- (readerpaging.lua:111 maps page-forward to onGotoViewRel(1)), delivered
--- through UIManager:sendEvent to the topmost widget. The ImageViewer this
--- plugin shows has no onGotoViewRel, so a remote /koreader/event/GotoViewRel/1
--- fell through to nothing and never turned the page.
---
--- The event's unit is "one view", which here is one display slot: what
--- switchToImageNum counts. Under the split that is a half, under dual-page a
--- spread -- the same thing a touch tap flips to, so the arithmetic is just
--- cur + diff, clamped to the list.
local function bindExternalPageTurns(viewer)
    viewer.onGotoViewRel = function(self, diff)
        local cur = self._images_list_cur or 1
        local nb = self._images_list_nb or 1
        local target = math.max(1, math.min(nb, cur + (diff or 0)))
        -- switchToImageNum's first line is a no-op guard against the *same*
        -- number, so a target that actually moved needs no help; a target that
        -- did not move is exactly the case the guard exists for.
        if target ~= cur then
            self:switchToImageNum(target)
        end
    end
    -- The absolute form, used by some remote controls. Also in slots, for the
    -- same reason as above.
    viewer.onGotoView = function(self, view)
        local nb = self._images_list_nb or 1
        local target = math.max(1, math.min(nb, view or 1))
        self:switchToImageNum(target)
    end

    -- Physical keys. ImageViewer binds PgFwd/PgBack itself, but only when
    -- Device:hasKeys() and only when self.image is a table, and a device's key
    -- map can name the groups differently -- on this device the two turn out
    -- to be RPgBack/RPgFwd (kobo device.lua:833). Binding here makes the
    -- mapping unconditional and explicit; the events land on ImageViewer's own
    -- onShowNextImage/onShowPrevImage, so the handlers need no code of ours.
    -- Merged, never replacing: Close must survive, and a binding the widget
    -- already made is not worth the churn of remaking.
    local groups = require("device").input.group
    viewer.key_events = viewer.key_events or {}
    if not viewer.key_events.ShowNextImage then
        viewer.key_events.ShowNextImage = { { groups.PgFwd } }
    end
    if not viewer.key_events.ShowPrevImage then
        viewer.key_events.ShowPrevImage = { { groups.PgBack } }
    end
end

function OPDSPSE:getLastPage(remote_url, username, password)
    local last_page = 0

    -- create URL's and reference vars
    local chapter = string.match(remote_url, "chapterId=(%w+)")
    local api_key = string.match(remote_url, "opds/(.+)/image")
    local progress_url = string.match(remote_url, "(.+)/api").."/api/Reader/get-progress?chapterId="..chapter
    local auth_url = string.match(remote_url, "(.+)/api").."/api/Plugin/authenticate?apiKey="..api_key.."&pluginName=KOReader-OPDS"

    -- Do an HTTP POST to get the Bearer Token for authentication of the /api/Reader/get-progress endpoint
    local auth_parsed = url.parse(auth_url)
    local auth_data = {}
    local auth_code, auth_headers, auth_status
    if auth_parsed.scheme == "http" or auth_parsed.scheme == "https" then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        auth_code, auth_headers, auth_status = socket.skip(1, http.request {
            method = "POST",
            url         = auth_url,
            headers     = {
                ["Accept-Encoding"] = "identity",
                ["Authentication"] = api_key,
            },
            -- Same reason as every other request in this file: only the custom
            -- sink honours the total timeout (see socketutil.lua:39-51).
            sink        = socketutil.table_sink(auth_data),
            user        = username,
            password    = password,
        })
        socketutil:reset_timeout()
    else
        UIManager:show(InfoMessage:new {
            text = T(_("Invalid protocol:\n%1"), auth_parsed.scheme),
        })
    end

    if auth_code == 200 then
        -- if http request for bearer token was successful, pull bearer token from response and
        -- attempt to pull progress for chapterId in remote_url
        local bearer_token = auth_data[1]:match("\"token\":\"(.+)\",\"refresh")

        -- Do HTTP GET request for chapter progress
        local progress_parsed = url.parse(progress_url)
        local progress_data = {}
        local progress_code, progress_headers, progress_status
        if progress_parsed.scheme == "http" or progress_parsed.scheme == "https" then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            progress_code, progress_headers, progress_status = socket.skip(1, http.request {
                url         = progress_url,
                headers     = {
                    ["Accept-Encoding"] = "identity",
                    ["Authorization"] = "Bearer "..bearer_token,
                },
                sink        = socketutil.table_sink(progress_data),
                user        = username,
                password    = password,
            })
            socketutil:reset_timeout()
        else
            UIManager:show(InfoMessage:new {
                text = T(_("Invalid protocol:\n%1"), progress_parsed.scheme),
            })
        end

        if progress_code == 200 then
            -- if HTTP GET was successful, pull page number from response.
            -- tonumber, and a digits-only capture: the old .+ could run well
            -- past the field, and a 200 whose body does not carry it at all
            -- left last_page at nil -- which the caller then adds 1 to, an
            -- arithmetic error that would take the whole chapter down over a
            -- progress lookup that is only a convenience.
            local body = progress_data[1]
            local captured = body and body:match("\"pageNum\":(%-?%d+),\"seriesId")
            last_page = tonumber(captured) or 0
        else
            logger.dbg("OPDSPSE:getLastPage: Progress Request failed:", progress_status or progress_code)
            logger.dbg("OPDSPSE:getLastPage: Progress Response headers:", progress_headers)
        end
    else
        logger.dbg("OPDSPSE:getLastPage: Authentication Request failed:", auth_status or auth_code)
        logger.dbg("OPDSPSE:getLastPage: Authentication Response headers:", auth_headers)
    end

    -- returns page number. If the HTTP Requests were unsuccessful, defaults to 0.
    return last_page;
end

function OPDSPSE:streamPages(remote_url, count, continue, username, password, last_page_read)
    -- attempt to pull chapter progress from Kavita if user pressed
    -- "Page Stream" button.
    -- We have to pull the progress here, otherwise the creation of the page_table
    -- will overwrite the book progress before we pull it, making it always 0.
    local ok, last_page = pcall(function() return self:getLastPage(remote_url, username, password) end)
    if not ok then
        log("no progress available (not a Kavita server?), starting at page 1")
        last_page = 0
    end

    -- Build tag. Temporary, and the only reason it exists: this plugin logs no
    -- version of its own, so a device test cannot be told apart from testing
    -- the previous build unless the log says which one ran. Remove together
    -- with the "not a JPEG" diagnostic in renderSlot.
    log("opening stream: %d pages [perf-fixes 2026-09-16c]", count)

    -- Raw image bytes, keyed by 0-based page index (ImageViewer page numbers
    -- are 1-based, so index == key - 1, as elsewhere in this file).
    -- Declared here, assigned after ImageViewer:new below, because the cache
    -- helpers need to know the current page and are defined before it. Without
    -- this forward declaration they would read a *global* named viewer, which
    -- is always nil — Lua locals only come into scope at their declaration.
    local viewer

    local cache = {}
    local cache_bytes = 0
    -- page index -> crop box, or false once measured with nothing to trim
    local crop_cache = {}
    -- The same, for the halves of a split sheet, keyed by index * 2 + half.
    -- Kept apart from crop_cache on purpose: a half is a different picture from
    -- the sheet it came out of, and one key space shared between them would let
    -- a box measured on a whole page be applied to a half of one.
    local half_crop_cache = {}
    -- The other halves of the spreads being read, already cut, trimmed and
    -- capped: the screens a page turn away. Least recently used first, never
    -- more than STASH_DEPTH of them. A hit is served a private copy -- see
    -- takeStashedHalf.
    --
    -- The reading direction the half was cut in travels with it, per entry
    -- rather than per stash: the cut depends on it, so the same key stands for
    -- the opposite half once the setting is flipped, and a cut buffer cannot be
    -- re-cut, only re-decoded. Keeping it beside the buffer is what lets an
    -- entry survive a direction that changed and changed back.
    local stash_entries = {}
    -- Source page -> how many display slots it holds, 1 or 2. Filled in as
    -- pages are decoded, because looking at one is the only way to know, and
    -- measuring the whole chapter up front would mean downloading it before
    -- showing any of it.
    local slots = {}
    local closed = false
    local retried = {}
    -- How many times the prefetch chain has deferred because a dialog was on
    -- top of the viewer. Bounded, so a widget that never goes away cannot park
    -- the chain forever — the next page turn re-arms it anyway.
    local prefetch_deferrals = 0
    local last_failure_notice = 0
    -- Consecutive prefetch failures, and the time the chain may run again. The
    -- chain already stops on the first failure, but every page turn re-arms it,
    -- so a reader flipping through a chapter on a dead link launches a fresh
    -- synchronous fetch on every turn -- each one owning the UI thread for as
    -- long as the block timeout allows (19 s and 31.5 s were both measured in
    -- one session). A short circuit break turns those into one: after
    -- PREFETCH_FAIL_MAX in a row the chain stays down until the cooldown has
    -- passed, and a page turn goes back to being a page turn.
    local prefetch_fails = 0
    local prefetch_gate_until = 0
    -- Whether the updateProgress rewrite in fetchPageData has been reported.
    -- Once per chapter, not once per fetch: the rewrite is a property of the
    -- catalog's template, so repeating it every prefetch would be noise.
    local progress_flag_logged = false
    -- Where the chapter opened, and whether the close-time report has been
    -- sent. Both belong to the chapter, not to a page: the report tells the
    -- catalog where the reader stopped, and it is only worth sending if that is
    -- further along than where they started (see reportProgress).
    local initial_source = nil
    local reported_progress = false

    --- Lets the whole stash go. Called where every entry stops being valid at
    --- once -- a change of auto-crop rebuilds every half differently -- and on
    --- the way out, so it does not outlive the chapter. A change of reading
    --- direction is handled per entry instead, in takeStashedHalf: it
    --- invalidates the cut, not the buffers.
    local function dropStash()
        for i = 1, #stash_entries do stash_entries[i].bb:free() end
        stash_entries = {}
    end

    --- Keeps one half of a spread for the page turns around this one. The buffer
    --- is owned here from now on: the caller hands it over and must not free it
    --- or touch it again.
    local function stashHalf(key, bb)
        -- A key can arrive twice only if a slot is rendered, turned away from
        -- and rendered again inside one step. Then the buffer already held is
        -- the same half, and the incoming one is the fresher: drop the old,
        -- rather than carrying the same picture twice and evicting a different
        -- half for the privilege.
        for i = #stash_entries, 1, -1 do
            local entry = stash_entries[i]
            if entry.key == key then
                entry.bb:free()
                table.remove(stash_entries, i)
            end
        end
        -- The direction the cut was made in is part of what is being kept.
        -- halfRect puts side 1 on the right in a right-to-left book, so the same
        -- key stands for the opposite half once the reader flips the setting --
        -- and a cut buffer cannot be re-cut, only re-decoded.
        table.insert(stash_entries, 1, { key = key, bb = bb, rtl = rtlReading() })
        while #stash_entries > STASH_DEPTH do
            local evicted = table.remove(stash_entries)
            log("stash: evict key %d, %d kept", evicted.key, #stash_entries)
            evicted.bb:free()
        end
    end

    --- A private copy of the stashed half, or nil. The copy is not decoration:
    --- the viewer frees whatever the page table hands it (the page table is
    --- marked image_disposable), so lending a stashed buffer out would free it
    --- out from under the turn after this one -- and coming back would pay for
    --- the whole decode again.
    local function takeStashedHalf(key)
        for i = 1, #stash_entries do
            local entry = stash_entries[i]
            if entry.key == key then
                -- Cut for the other reading direction, so it holds the wrong
                -- half of the sheet: worth one re-decode to avoid handing the
                -- reader that. Dropped rather than kept, so the next turn
                -- re-cuts and re-stashes it the right way round instead of
                -- finding this one again.
                if entry.rtl ~= rtlReading() then
                    entry.bb:free()
                    table.remove(stash_entries, i)
                    return nil
                end
                -- Asked for, so keep it: move it to the front, where the entry
                -- the reader is actually bouncing between outlives the one a
                -- single turn past put here. Only the ordering changes -- the
                -- entry stays in the stash, and the caller gets a copy.
                table.remove(stash_entries, i)
                table.insert(stash_entries, 1, entry)
                return copyBlitbuffer(entry.bb)
            end
        end
        return nil
    end

    --- Whether the view is sideways right now. The viewer is still nil while
    --- ImageViewer's constructor loads page one; treat that as upright.
    local function isRotated()
        return viewer and viewer.rotated or false
    end

    --- Whether a sheet is being cut in two at this moment. Rotation switches
    --- the split off rather than re-pairing anything: a sideways view is a
    --- request to see the whole spread, which is also what the reader gets
    --- when they turn it back (see toggleRotation).
    local function splitActive()
        return splitOn() and not isRotated()
    end

    --- Display slots a source page occupies. A page nobody has decoded yet is
    --- taken to hold two: the setting is an assertion the reader makes about
    --- the whole chapter ("this release stores spreads"), and the first page
    --- that proves otherwise is what corrects it.
    local function slotsOfSource(page)
        if not splitActive() then return 1 end
        local n = slots[page]
        if n then return n end
        return 2
    end

    --- Display slots in the chapter, which is what the viewer counts.
    local function slotCount()
        if not splitActive() then
            -- Dual page, or plain single page: the existing pairing already
            -- answers this, and dualPageOn() is false whenever the split is on.
            return spreadCountOf(count)
        end
        local n = 0
        for i = 1, count do n = n + slotsOfSource(i) end
        return n
    end

    --- The source page a display slot shows, and which half of it that slot
    --- asks for (nil for a whole page). The walk is linear in the number of
    --- pages and the count is in the low hundreds, so there is nothing worth
    --- caching here.
    local function sourceOfSlot(slot)
        if not splitActive() then return spreadPages(slot, count)[1], nil end
        local n = 0
        for i = 1, count do
            local k = slotsOfSource(i)
            if slot <= n + k then
                return i, k == 2 and (slot - n) or nil
            end
            n = n + k
        end
        return nil, nil
    end

    --- The first display slot of a source page. Learning what a page holds
    --- never moves this number -- it counts only the pages *before* it -- and
    --- that is what makes it safe to fill `slots` in while a page is on screen,
    --- mid-read, with no re-anchoring.
    local function firstSlotOfSource(page)
        if not splitActive() then return spreadOfPage(page) end
        local n = 1
        for i = 1, page - 1 do n = n + slotsOfSource(i) end
        return n
    end

    --- Records what a decoded sheet turned out to hold. Called only while that
    --- sheet's *first* slot is being drawn, the one position where its own slot
    --- index cannot move under the reader (see firstSlotOfSource). Every slot
    --- after it shifts, so the page counter has to be refreshed -- but the
    --- reader does not, since they are already looking at the right page.
    local function learnSlots(page, n)
        if slots[page] == n then return end
        slots[page] = n
        log("page %d: %s", page,
            n == 2 and "two pages on the sheet, splitting" or "one page on the sheet")
        if viewer then viewer._images_list_nb = slotCount() end
    end

    local function cacheCount()
        local n = 0
        for _ in pairs(cache) do n = n + 1 end
        return n
    end

    --- Evicts whatever is furthest from the page being read.
    ---
    --- Distance, not insertion order: the prefetcher fills forwards first and
    --- backwards second, so evicting oldest-first would drop exactly the pages
    --- the reader is about to need and keep the ones already behind them.
    --- MIN_PAGES keeps the cache usable even if one page exceeds the byte cap.
    local function cacheEvict()
        while cache_bytes > MEM_CACHE_MAX_BYTES and cacheCount() > MEM_CACHE_MIN_PAGES do
            -- Distances are measured in 0-based source pages, because that is
            -- what the keys are. The viewer, however, counts display slots --
            -- spreads under dual-page, halves of a sheet under the split -- so
            -- its page number is only the source index in the plain single-page
            -- case. Feeding it straight in would measure every distance from a
            -- point behind the reader and so evict exactly the pages ahead of
            -- them, which is the opposite of the intent above.
            local current = 0
            if viewer then
                current = (sourceOfSlot(viewer._images_list_cur or 1) or 1) - 1
            end
            local worst, worst_dist
            for index, data in pairs(cache) do
                local dist = math.abs(index - current)
                if worst == nil or dist > worst_dist then
                    worst, worst_dist = index, dist
                end
            end
            if worst == nil then return end
            cache_bytes = cache_bytes - #cache[worst]
            cache[worst] = nil
        end
    end

    local function cacheStore(index, data)
        local previous = cache[index]
        if previous then
            cache_bytes = cache_bytes - #previous
        end
        cache[index] = data
        cache_bytes = cache_bytes + #data
        cacheEvict()
    end

    local function cacheDrop(index)
        local data = cache[index]
        if data then
            cache_bytes = cache_bytes - #data
            cache[index] = nil
        end
    end

    -- Blocking fetch. Returns the image bytes, or nil plus a reason.
    local function fetchPageData(index, is_prefetch)
        local page_url = remote_url:gsub("{pageNumber}", tostring(index))
        -- Kept for the sake of catalogs that do offer a width placeholder, but
        -- it does nothing on Suwayomi: the page endpoint takes only
        -- updateProgress / format / opds, and the image is written out at its
        -- stored resolution (Page.getPageImageServe -> ImageIO, no resize
        -- anywhere). So the oversampling of large pages has no server-side fix
        -- and the only lever left is decoding less of the JPEG.
        page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
        -- A prefetch must not report progress. The catalog serves us the whole
        -- page URL -- everything but the page number already filled in -- so
        -- whatever it put in the query is passed through untouched. That is
        -- right for a page the reader actually turned to, and wrong for a
        -- prefetch, which serves pages they have not reached yet: on Suwayomi
        -- updateProgress=true makes the server record the page just served as
        -- the reading position and push it to KOReader sync, so a look-ahead of
        -- a few pages parks the progress ahead of the reader, and a prefetch
        -- that reaches the last page marks the whole chapter read.
        --
        -- The pattern keeps the query delimiter in a capture rather than
        -- matching the parameter name bare, so a longer name that merely ends
        -- in "updateProgress" cannot be hit, and whatever separator the
        -- catalog used survives the rewrite.
        if is_prefetch then
            local before = page_url
            page_url = page_url:gsub("([?&])updateProgress=[^&]*", "%1updateProgress=false")
            if page_url ~= before and not progress_flag_logged then
                progress_flag_logged = true
                log("prefetch: updateProgress forced to false, page turns stay authoritative")
            end
        end
        local parsed = url.parse(page_url)
        if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
            -- A prefetch failing this way is not worth interrupting the reader
            -- over: the page will be fetched again, loudly, on a real turn.
            if not is_prefetch then
                UIManager:show(InfoMessage:new {
                    text = T(_("Invalid protocol:\n%1"), parsed.scheme),
                })
            end
            return nil, "invalid protocol"
        end

        local started = now()
        local page_data = {}
        if is_prefetch then
            socketutil:set_timeout(PREFETCH_BLOCK_TIMEOUT, PREFETCH_TOTAL_TIMEOUT)
        else
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        end
        local code, headers, status = socket.skip(1, http.request {
            url         = page_url,
            headers     = {
                ["Accept-Encoding"] = "identity",
            },
            -- table_sink, not ltn12.sink.table, for the reason spelled out at
            -- reportProgress below: a bare sink leaves the total timeout
            -- unserved and keeps only the per-read block timeout, which
            -- restarts on every chunk. This is the one request on the page-turn
            -- path, so it is the one place where a server that dribbles an
            -- image out holds the UI thread for as long as it likes -- measured
            -- at 19 s and 31 s against a nominal limit of 15 s.
            sink        = socketutil.table_sink(page_data),
            user        = username,
            password    = password,
        })
        socketutil:reset_timeout()
        local elapsed = elapsedMs(started)

        if code == 200 then
            local data = table.concat(page_data)
            log("page %d: %s fetched %d bytes in %d ms",
                index, is_prefetch and "prefetch" or "fetch", #data, elapsed)
            return data
        end
        log("page %d: %s FAILED after %d ms: %s",
            index, is_prefetch and "prefetch" or "fetch", elapsed, tostring(status or code))
        logger.dbg("OPDSPSE:streamPages: Response headers:", headers)
        return nil, status or code
    end

    --- Tells the catalog which page the reader stopped on. Takes a source page,
    --- the same numbering the catalog and the jump dialog use.
    ---
    --- This is a whole page request, not a metadata write, because the
    --- page-streaming protocol has no metadata write: the only hook it offers a
    --- client for reporting progress is asking for a page with
    --- `updateProgress=true`, which makes the server record the page it just
    --- served. Hence once per chapter rather than once per turn -- it costs one
    --- page image, roughly 0.8 MB on this library, which is about 1% of what
    --- reading the chapter costs in the first place.
    ---
    --- It is needed at all because of prefetching. A warm cache answers almost
    --- every page turn out of memory (91 of 100 in the last measured session),
    --- so the requests that carry the progress flag are only the few that
    --- missed, and the server's idea of the position stays wherever the last
    --- miss happened to fall -- never the page the reader closed on.
    local function reportProgress(page)
        if reported_progress then return end
        -- Forward only. Closing behind where the chapter opened means the
        -- reader went back over something, and that is no reason to move the
        -- catalog's idea of their position backwards -- nor to make the server
        -- forget that a chapter it had finished is finished.
        if not page or not initial_source or page <= initial_source then
            log("progress: not reporting page %s, no further than page %s",
                tostring(page), tostring(initial_source))
            return
        end
        -- Attempted counts as done. A failed report is not worth retrying
        -- within the same chapter: the next close carries a better position.
        reported_progress = true

        -- Acting only where the catalog asked for it: a template without the
        -- parameter belongs to a server that records progress some other way or
        -- not at all, and the request would be a page image downloaded for
        -- nothing.
        if not remote_url:match("[?&]updateProgress=true") then
            log("progress: page %d not reported, catalog does not ask for it", page)
            return
        end
        -- {pageNumber} is zero-based; the source page handed in is not.
        local page_url = remote_url:gsub("{pageNumber}", tostring(page - 1))
        local parsed = url.parse(page_url)
        if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
            log("progress: page %d not reported, invalid protocol %s",
                page, tostring(parsed.scheme))
            return
        end

        -- Name resolution sits outside every socket timeout in this file and
        -- has been measured at 20 s on this device, which the reader would feel
        -- as a frozen file browser. isConnected() is a sysfs read plus
        -- getifaddrs and costs nothing, so checking it is free insurance.
        -- Deliberately not isOnline(), which would be a DNS query of its own.
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isConnected() then
            log("progress: page %d not reported, no link", page)
            return
        end

        -- The body is discarded: what is wanted is the side effect on the
        -- server, and there is no way to ask for that on its own.
        local body = {}
        socketutil:set_timeout(PROGRESS_BLOCK_TIMEOUT, PROGRESS_TOTAL_TIMEOUT)
        local started = now()
        -- Not `local _, ...` for the headers: in this file `_` is gettext, and
        -- shadowing it inside a function is the trap documented at page_table.
        local code, headers, status = socket.skip(1, http.request {
            url         = page_url,
            headers     = {
                ["Accept-Encoding"] = "identity",
            },
            -- table_sink rather than ltn12.sink.table, which ignores the total
            -- timeout: with a bare sink only the per-read block timeout applies
            -- and it restarts on every chunk, so a server dribbling the image
            -- slowly would hold the UI thread for as long as it liked.
            sink        = socketutil.table_sink(body),
            user        = username,
            password    = password,
        })
        socketutil:reset_timeout()
        if code == 200 then
            log("progress: reported page %d in %d ms", page, elapsedMs(started))
        else
            -- Not worth a notification: the reader has left the chapter and
            -- cannot act on it, and the next close carries a better position.
            log("progress: page %d NOT reported after %d ms: %s",
                page, elapsedMs(started), tostring(status or code))
            logger.dbg("OPDSPSE:reportProgress: Response headers:", headers)
        end
    end

    -- Identifies a page across chapters and servers, for both cache layers.
    local function pageKey(index)
        return remote_url .. "#" .. index
    end

    -- Memory first, then disk, then network. Returns data plus where it came
    -- from, so the log shows whether prefetching is actually paying off.
    local function loadPage(index, is_prefetch)
        local data = cache[index]
        if data then return data, "mem" end
        data = diskCacheGet(pageKey(index))
        if data then
            cacheStore(index, data)
            return data, "disk"
        end
        data = fetchPageData(index, is_prefetch)
        if data then
            cacheStore(index, data)
            diskCachePut(pageKey(index), data)
        end
        return data, data and "net" or nil
    end

    local page_table = {image_disposable = true}
    -- NOTE: the first parameter must not be named `_`. In this file `_` is
    -- gettext, and a parameter of that name shadows it, so the error paths
    -- below would call a table instead of translating a string and crash
    -- KOReader. Upstream has the same trap at opdspse.lua:106; it is only
    -- reachable there on an invalid protocol, which is why it went unnoticed.
    -- Renders one display slot. In dual-page mode that is a spread: both
    -- source pages get decoded and stitched into a single wide buffer. In
    -- split mode it is one half of a single sheet, cut off after decoding.
    -- The caches and the prefetcher stay keyed by source page either way, so
    -- nothing about them has to know how many pages are shown at once -- or
    -- how many screens one page is shown across.
    setmetatable(page_table, {__index = function (_page_table, key)
        if type(key) ~= "number" then
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        local started = now()
        local rotated = isRotated()
        local src, half = sourceOfSlot(key)
        -- Dual mode shows two source pages at once, so a slot is both of them;
        -- split mode shows one half of one page, so a slot is the page alone
        -- with `half` naming the piece. Never both: dualPageOn() reports false
        -- whenever the split is switched on.
        local wanted = dualPageOn() and spreadPages(key, count) or { src }

        local function placeholder(label)
            -- Failures are deliberately not cached, so turning away and back
            -- retries instead of showing the placeholder forever. Tell the
            -- reader what happened, throttled so a run of failures is not a
            -- stream of popups.
            log("%s: no data, showing placeholder", label)
            if os.time() - last_failure_notice > 20 then
                last_failure_notice = os.time()
                Notification:notify(
                    T(_("Page %1 failed to load. Turn the page and back to retry."), key),
                    Notification.SOURCE_ALWAYS_SHOW)
            end
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end

        if not src or #wanted == 0 then
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end

        local bbs, source, spread = {}, nil, false
        for _, page in ipairs(wanted) do
            local index = page - 1 -- caches are keyed by 0-based source page
            local bb, is_spread

            -- The stashed half answers this slot without touching the compressed
            -- bytes at all: it is this very sheet, cut and trimmed one page turn
            -- ago. Tested before the load, so a hit costs neither a cache lookup
            -- nor a decode.
            if splitOn() and not rotated and half then
                bb = takeStashedHalf(index * 2 + half)
                if bb then
                    source = source or "stash"
                    is_spread = true
                end
            end

            if not bb then
                local data, from = loadPage(index, false)
                if not data then
                    for _, done in ipairs(bbs) do done:free() end
                    return placeholder("page " .. page)
                end
                source = source or from
                bb, is_spread = renderSlot(data, index, half, rotated,
                    crop_cache, half_crop_cache, stashHalf)
                if not bb then
                    cacheDrop(index)
                    for _, done in ipairs(bbs) do done:free() end
                    return placeholder("page " .. page)
                end
            end
            spread = is_spread
            bbs[#bbs + 1] = bb
        end

        -- Remember what the sheet held, but only where the bookkeeping cannot
        -- move under the reader: while its first slot is on screen (see
        -- firstSlotOfSource). Skipped while rotated, where the split is off by
        -- definition and every sheet would be recorded as holding one page.
        if splitOn() and not rotated and key == firstSlotOfSource(src) then
            learnSlots(src, spread and 2 or 1)
        end

        if #bbs == 1 then
            log("page %d: ready in %d ms via %s as %dx%d%s", key,
                elapsedMs(started), source, bbs[1]:getWidth(), bbs[1]:getHeight(),
                spread and string.format(" (half %d of sheet %d)", half, src) or "")
            return bbs[1]
        end

        -- Stitch. Right to left puts the first page on the right, which is
        -- the whole difference between the two reading directions.
        local w1, h1 = bbs[1]:getWidth(), bbs[1]:getHeight()
        local w2, h2 = bbs[2]:getWidth(), bbs[2]:getHeight()
        local Blitbuffer = require("ffi/blitbuffer")
        local composite = Blitbuffer.new(w1 + w2, math.max(h1, h2), bbs[1]:getType())
        if composite then
            if rtlReading() then
                composite:blitFrom(bbs[2], 0, 0, 0, 0, w2, h2)
                composite:blitFrom(bbs[1], w2, 0, 0, 0, w1, h1)
            else
                composite:blitFrom(bbs[1], 0, 0, 0, 0, w1, h1)
                composite:blitFrom(bbs[2], w1, 0, 0, 0, w2, h2)
            end
        end
        -- The source buffers are dead weight once stitched. Freeing them here
        -- keeps the peak at three buffers instead of holding all of them.
        for _, done in ipairs(bbs) do done:free() end
        if not composite then
            return placeholder("spread " .. key)
        end

        log("spread %d (%s): ready in %d ms via %s as %dx%d", key,
            table.concat(wanted, ","), elapsedMs(started), source,
            composite:getWidth(), composite:getHeight())
        return composite
    end})

    -- Rotation and dual-page travel together (see toggleRotation), but only one
    -- of the two survives a chapter change: rotation is per-viewer state, so a
    -- freshly opened chapter is always upright, while dual-page is persisted.
    -- A chapter opened right after a rotated one would therefore come up
    -- two-page with the view upright -- exactly the pairing the dual-page rule
    -- exists to avoid. Drop the setting only when the rotation put it there;
    -- a value the reader chose by hand is theirs to keep.
    --
    -- Split mode gets the same treatment: rotation carries a dual-page value
    -- with it, so one made that way must not come back as a hand-made one on
    -- top of a split chapter.
    if G_reader_settings:isTrue(DUAL_AUTO_KEY) and (dualPageOn() or splitOn()) then
        G_reader_settings:saveSetting(DUAL_KEY, false)
    end

    local ImageViewer = require("ui/widget/imageviewer")
    viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = slotCount(),
    }

    -- Left-handed hold, applied here and not in the constructor: the flip is a
    -- screen-global rotation, so it must be taken down with the viewer, and
    -- the original mode is the only thing that can restore it exactly.
    -- Remembered before applyDisplayModeChange may re-pair slots below.
    viewer.orig_rotation_mode = Screen:getRotationMode()
    if G_reader_settings:isTrue(INVERT_KEY) then
        Screen:setRotationMode((viewer.orig_rotation_mode + INVERT_180) % 4)
    end

    -- The constructor renders page one and *then* writes the count it was
    -- given, which was counted before that page had been seen. So a split
    -- chapter whose first sheet holds a single page is one out from the start.
    -- Restate it now that page one has been measured; learnSlots keeps it
    -- current from here on, and it only ever learns at a sheet's first slot.
    viewer._images_list_nb = slotCount()

    -- Remote page-turners and physical page-turn keys talk to readers in
    -- GotoViewRel events. ImageViewer has no such handler, so this viewer was
    -- deaf to all of them; see bindExternalPageTurns. Bound before the widget
    -- is shown, so no event can slip through the window in between.
    bindExternalPageTurns(viewer)

    -- Page turns repaint through ImageViewer's own wfm_mode, which is "ui" on
    -- every panel that is not Kaleido (imageviewer.lua:377). On this device
    -- waveform_ui and waveform_partial are the same waveform mode (AUTO, 257),
    -- so the two differ in exactly one thing: UIManager promotes only
    -- `mode == "partial"` to a flashing refresh (uimanager.lua:1163). "ui"
    -- never flashes, so ghosting accumulates for as long as the chapter stays
    -- open, and the reader's only way to clear it is a long press, which
    -- nothing tells them about.
    --
    -- Answering "partial" instead costs nothing here and restores the ordinary
    -- clear every FULL_REFRESH_COUNT turns. It is done by answering
    -- hasKaleidoWfm affirmatively for the duration of one update() call, not by
    -- copying ImageViewer:update into this file: wfm_mode is a local, so the
    -- only thing an outside caller can influence is that predicate, and
    -- narrowing the override to the call keeps it off everything else. (The
    -- predicate's other readers are a CFA waveform boost in framebuffer_mxcfb
    -- that is already guarded on Kaleido, and two widget colour checks -- none
    -- of them runs inside update().)
    --
    -- Worth knowing: hasKaleidoWfm is a *function* on the device, not a flag.
    -- generic/device.lua declares `local function yes() return true end` and
    -- then writes `hasKaleidoWfm = no`, which is how a `Device:hasX()` call
    -- manages to read what looks like a boolean field.
    --
    -- The reader keeps the last word: "avoid_flashing_ui" downgrades a regional
    -- partial back to "ui" (uimanager.lua:1148), so anyone who would rather
    -- keep the present never-flash behaviour gets it by switching that on under
    -- E-ink settings.
    local Device = require("device")
    local orig_update = viewer.update
    local orig_has_kaleido_wfm = Device.hasKaleidoWfm
    viewer.update = function(this, ...)
        Device.hasKaleidoWfm = function() return true end
        -- Restore before re-raising: the override must not outlive the call
        -- that needs it, whether that call succeeds or throws.
        local ok, err = pcall(orig_update, this, ...)
        Device.hasKaleidoWfm = orig_has_kaleido_wfm
        if not ok then error(err, 0) end
    end

    -- Swipe-to-close is off: closing is the Close button's job.
    --
    -- A one-finger flick while the page is scaled to fit closes the whole
    -- chapter and drops the reader back in the catalog (ImageViewer:onSwipe,
    -- the "south" branch) — with no confirmation and nothing on screen to
    -- explain it. On e-ink, where a tap that drifts a few millimetres is
    -- indistinguishable from a short flick, that is a booby trap, and the
    -- reader was not aiming at anything.
    --
    -- Note what is *not* done here: onSwipe itself is left alone, because
    -- whether a given flick closes depends on the zoom level and on where the
    -- finger started, and panning/zooming on the sides run through the same
    -- handler. Re-deriving those conditions to carve out the one that closes
    -- would mean duplicating frontend logic that can silently drift. Instead
    -- the close is refused from the inside: anything reached *through* a swipe
    -- cannot end the chapter, whatever the policy above it becomes.
    --
    -- Every other way out still works — the Close button, the Back key, a
    -- multiswipe — so this cannot strand the reader.
    local in_swipe = false
    local orig_on_swipe = viewer.onSwipe
    viewer.onSwipe = function(this, ...)
        in_swipe = true
        -- The flag has to come back down even when the handler throws. Left
        -- up it refuses every later onClose, and nothing else ever clears it:
        -- the chapter could not be closed at all, by any route, and only a
        -- restart would get the reader out. The error is re-raised once the
        -- flag is reset, so the failure still surfaces -- only the stuck state
        -- is prevented. (error(..., 0) keeps the original message intact
        -- instead of prefixing it with this wrapper's line number.)
        local ok, handled = pcall(orig_on_swipe, this, ...)
        in_swipe = false
        if not ok then error(handled, 0) end
        return handled
    end
    local orig_on_close = viewer.onClose
    viewer.onClose = function(this, ...)
        if in_swipe then
            log("swipe-to-close suppressed")
            return true
        end
        return orig_on_close(this, ...)
    end

    -- Re-render the current page from scratch. Used to recover from a failed
    -- load without making the reader navigate away and back by hand, and by
    -- every setting that changes what a viewer slot means.
    --
    -- `why` names whoever asked, and only the log reads it. It is not
    -- decoration: this call puts the screen under the reader through the whole
    -- render path again, which on a spread is a 1.2 s decode, and a chapter's
    -- log showed ten seconds of that with no way to tell what had asked for it
    -- -- the settings that call this one log nothing of their own. One field
    -- here is the difference between attributing that time and guessing at it.
    local function reloadCurrentPage(why)
        log("reload: %s", why or "unspecified")
        local current = viewer._images_list_cur
        if not current then return end
        viewer._images_list_cur = nil -- defeat switchToImageNum's no-op check
        viewer:switchToImageNum(current)
    end

    --- The source page the reader is looking at right now, under whatever
    --- settings are in force at this moment. Call this *before* flipping a
    --- setting that changes what a viewer slot means.
    local function currentSourcePage()
        local cur = viewer._images_list_cur or 1
        return sourceOfSlot(cur) or 1
    end

    --- Applies a change that alters what a viewer slot means. Dual-page, the
    --- cover offset and the split all renumber the slots, so the position and
    --- the total have to be remapped across the change; the source page under
    --- the reader is the thing that stays fixed.
    local function applyDisplayModeChange(source_page, why)
        viewer._images_list_nb = slotCount()
        viewer._images_list_cur = firstSlotOfSource(source_page)
        reloadCurrentPage(why)
    end

    --- Flips the rotation and puts the result on screen.
    ---
    --- Rotation carries dual-page with it, in both directions: a sideways view
    --- is a two-page spread, which is the only reason to turn the page at all,
    --- and an upright view is not. The two-page row in the display dialog still
    --- works on its own -- turning it on by hand while upright is respected --
    --- the next rotation change just re-syncs it.
    ---
    --- The split needs no setting written: rotation *is* its mode switch. A
    --- sideways view shows the whole sheet and an upright one shows its two
    --- halves, which renumbers the slots on its own. Dual-page never applies
    --- while the split is on -- gluing two spreads together would put four
    --- pages on one screen -- so the branch below is skipped there.
    ---
    --- Defined after currentSourcePage/applyDisplayModeChange on purpose: a
    --- local declared further down is not yet in scope here, and the calls
    --- would quietly go to nil globals.
    local function toggleRotation()
        -- Read the position first: the source page is the only thing that
        -- survives the flip, since everything else about a slot's meaning
        -- depends on the rotation being flipped.
        local src = currentSourcePage()
        local split_before = splitActive()
        local dual_before = dualPageOn()

        viewer.rotated = not viewer.rotated and true or false

        if not splitOn() and dual_before ~= viewer.rotated then
            G_reader_settings:saveSetting(DUAL_KEY, viewer.rotated)
            G_reader_settings:saveSetting(DUAL_AUTO_KEY, true)
        end

        local renumbered = split_before ~= splitActive() or dual_before ~= dualPageOn()
        log("rotate -> %s, dual-page -> %s, split -> %s%s", tostring(viewer.rotated),
            tostring(dualPageOn()), tostring(splitActive()),
            renumbered and " (re-pairing)" or "")
        if renumbered then
            viewer._images_list_nb = slotCount()
            viewer._images_list_cur = firstSlotOfSource(src)
            reloadCurrentPage("rotation (re-pairing)")
        elseif G_reader_settings:isTrue(AUTOCROP_KEY) then
            -- Cropping is skipped while the view is rotated (see renderSlot),
            -- so with it on the page really does have to be rendered again.
            reloadCurrentPage("rotation (crop re-measure)")
        else
            -- Nothing that changes which buffer this page is: the re-render
            -- would decode a byte-for-byte identical one. update() re-uses the
            -- buffer already on hand, re-applies the rotation angle and
            -- refreshes the button label.
            viewer:update()
        end
    end

    --- Opened by a long press on Rotate. Tap stays a plain toggle because
    --- rotating is the frequent action; the rest is set once and forgotten.
    local function showDisplayDialog()
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = L("Display", "显示方式"),
            title_align = "center",
            buttons = {
                {
                    {
                        text = L("Rotate 90°", "旋转 90°"),
                        callback = function()
                            UIManager:close(dialog)
                            toggleRotation()
                        end,
                    },
                },
                {
                    {
                        text = L("Two pages", "双页显示"),
                        checked_func = dualPageOn,
                        callback = function()
                            local src = currentSourcePage()
                            -- The two rows below gate on dualPageOn() through
                            -- enabled_func, which Button evaluates at paint time
                            -- only for the rows it repaints -- and a tap
                            -- repaints just its own row. Without this, opening
                            -- dual mode leaves them greyed out until something
                            -- else forces a full refresh.
                            local want = not dualPageOn()
                            if want then
                                -- Two modes answering the same question: the
                                -- tap has to turn the other one off, or it would
                                -- do nothing at all behind dualPageOn()'s mask.
                                G_reader_settings:saveSetting(SPLIT_KEY, false)
                            end
                            G_reader_settings:saveSetting(DUAL_KEY, want)
                            -- Chosen by hand, so it outlives this chapter: the
                            -- entry sync only drops rotation-made values.
                            G_reader_settings:saveSetting(DUAL_AUTO_KEY, false)
                            applyDisplayModeChange(src, "two-pages")
                            UIManager:setDirty(dialog, "ui")
                        end,
                    },
                },
                {
                    {
                        text = L("Split two-page scans", "拆开双页扫描"),
                        checked_func = splitOn,
                        callback = function()
                            local src = currentSourcePage()
                            local want = not splitOn()
                            if want then
                                -- Exclusive the other way round: dual-page
                                -- would show four pages of a split chapter.
                                G_reader_settings:saveSetting(DUAL_KEY, false)
                                G_reader_settings:saveSetting(DUAL_AUTO_KEY, false)
                            end
                            G_reader_settings:saveSetting(SPLIT_KEY, want)
                            applyDisplayModeChange(src, "split")
                            -- Same repaint note as the row above: this changes
                            -- whether the dual-page and direction rows are
                            -- live, and a tap only repaints its own.
                            UIManager:setDirty(dialog, "ui")
                        end,
                    },
                },
                {
                    {
                        text = L("Right to left", "从右到左"),
                        checked_func = rtlReading,
                        enabled_func = function()
                            return dualPageOn() or splitOn()
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(DUAL_RTL_KEY, not rtlReading())
                            -- The halves are named by position in the pair, not
                            -- by where they sit on the sheet, so flipping the
                            -- direction swaps which physical half each key
                            -- stands for -- while half_crop_cache holds a box
                            -- measured on the other one. Left in place it would
                            -- trim this half by the other half's margins. Dropped
                            -- rather than re-keyed: the next render measures it
                            -- again, once. crop_cache is deliberately untouched,
                            -- because a whole sheet does not move.
                            half_crop_cache = {}
                            reloadCurrentPage("right-to-left")
                        end,
                    },
                },
                {
                    {
                        text = L("First page is cover", "首页单独显示"),
                        checked_func = dualCoverFirst,
                        -- No row of its own for the split: there the sheet is
                        -- measured, so a cover that holds one page is simply
                        -- left whole and needs no telling.
                        enabled_func = dualPageOn,
                        callback = function()
                            local src = currentSourcePage()
                            G_reader_settings:flipNilOrFalse(DUAL_COVER_KEY)
                            applyDisplayModeChange(src, "cover-first")
                        end,
                    },
                },
                {
                    {
                        text = L("Upside down (left hand)", "倒置 180°（左手）"),
                        -- The check is the setting; the rotation follows it.
                        checked_func = function()
                            return G_reader_settings:isTrue(INVERT_KEY)
                        end,
                        callback = function()
                            -- Flipping the screen swaps the physical page-turn
                            -- keys on its own (input.lua's rotation_map), so a
                            -- left-hand grip gets one action, not two. The
                            -- current page needs no re-render: the rotation is
                            -- screen-level and the page buffer is untouched.
                            -- A 180° turn keeps the same portrait/landscape
                            -- class (mode bit 0 unchanged), so it is just
                            -- rotate-and-repaint without a layout pass, exactly
                            -- as ReaderView:rotate treats its own 180° (it
                            -- compares bit.band(mode, 1) and takes the no-
                            -- layout branch, flushing the screen with nil).
                            G_reader_settings:flipNilOrFalse(INVERT_KEY)
                            Screen:setRotationMode(
                                (Screen:getRotationMode() + INVERT_180) % 4)
                            UIManager:setDirty(nil, "full")
                            UIManager:setDirty(dialog, "ui")
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
    end

    -- Fill the look-ahead window one page per scheduled callback, so no single
    -- fetch blocks for long and the pending one stays cancellable. The chain
    -- stops on failure and re-arms on the next page turn, which keeps a dead
    -- server from being hammered.
    local schedulePrefetch
    local function prefetchNext()
        if closed then return end
        -- Cheap link check before anything else. DNS resolution sits outside
        -- every socket timeout in this file and measured 20 s on this device,
        -- so a fetch launched with no link is not a failed request but a frozen
        -- UI thread. isConnected() is a sysfs read plus an getifaddrs walk and
        -- costs nothing to ask. Deliberately not isOnline(), which is a DNS
        -- query of its own -- the very cost being avoided (see reportProgress).
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isConnected() then
            log("prefetch: no link, staying idle")
            return
        end
        -- Circuit break in effect: leave the chain down for PREFETCH_COOLDOWN
        -- after PREFETCH_FAIL_MAX failures in a row. Retrying on every page
        -- turn against a link already known to be bad is what turned four slow
        -- requests into 91 seconds of unresponsive UI in one measured session.
        if now() < prefetch_gate_until then
            return
        end
        -- The fetch below is a synchronous HTTP request: it owns the UI thread
        -- for its whole duration, so anything the reader touches meanwhile just
        -- queues up. That is exactly the wrong time to hold the thread when a
        -- dialog is open — the reader is looking at a button, not at the page.
        -- Stand aside until the viewer is on top again.
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        if viewer and top and top.widget ~= viewer then
            if prefetch_deferrals < PREFETCH_DEFER_MAX then
                prefetch_deferrals = prefetch_deferrals + 1
                schedulePrefetch(PREFETCH_DEFER_DELAY)
            end
            return
        end
        prefetch_deferrals = 0
        local current = viewer._images_list_cur
        if not current then return end
        -- The window is counted in source pages, because that is the unit the
        -- cache and the fetcher work in; one screen is not. Working back from
        -- the screens the constants name: a spread is two source pages wide, so
        -- dual-page doubles the depth, while a split sheet is two screens tall,
        -- so the split halves it. Same number of screens ready either way.
        local first_page = sourceOfSlot(current) or current
        local base = first_page - 1
        local ahead, behind = PREFETCH_AHEAD, PREFETCH_BEHIND
        if dualPageOn() then
            ahead, behind = ahead * 2, behind * 2
        elseif splitActive() then
            ahead = math.max(1, math.ceil(ahead / 2))
            behind = math.max(1, math.ceil(behind / 2))
        end
        -- A page already on disk needs no prefetch: it will load quickly
        -- enough on demand, and re-downloading it would waste the network we
        -- are trying to spare.
        local function needed(index)
            return index >= 0 and index < count
                and cache[index] == nil
                and not diskCacheHas(pageKey(index))
        end
        local target
        for offset = 1, ahead do
            if needed(base + offset) then
                target = base + offset
                break
            end
        end
        if target == nil then
            for offset = 1, behind do
                if needed(base - offset) then
                    target = base - offset
                    break
                end
            end
        end
        if target == nil then return end
        local data = fetchPageData(target, true)
        if data then
            prefetch_fails = 0
            cacheStore(target, data)
            diskCachePut(pageKey(target), data)
            if cache[target] == nil then
                -- Stored and evicted in the same breath: the look-ahead window
                -- does not fit in the memory cache. Carrying on would refetch
                -- the same pages forever, so stop and let page turns re-arm.
                log("prefetch window exceeds memory cache (%d bytes), stopping chain",
                    cache_bytes)
                return
            end
            schedulePrefetch(PREFETCH_CHAIN_DELAY)
        else
            -- Counted towards the circuit break above. A lone failure costs
            -- nothing extra: the gate only refuses future launches, and a
            -- successful fetch resets the count.
            prefetch_fails = prefetch_fails + 1
            if prefetch_fails >= PREFETCH_FAIL_MAX then
                prefetch_gate_until = now() + PREFETCH_COOLDOWN
                log("prefetch: %d failures in a row, standing down for %d s",
                    prefetch_fails, PREFETCH_COOLDOWN)
            end
        end
    end
    --- Called with no argument after a page turn (settle first), and with
    --- PREFETCH_CHAIN_DELAY from the chain itself (keep filling).
    schedulePrefetch = function(delay)
        UIManager:unschedule(prefetchNext)
        UIManager:scheduleIn(delay or PREFETCH_DELAY, prefetchNext)
    end

    -- Re-arm the look-ahead on every page turn, including the initial one.
    local orig_switch_to_image_num = viewer.switchToImageNum
    viewer.switchToImageNum = function(this, image_num)
        orig_switch_to_image_num(this, image_num)
        -- A load that had to hit the network was a prefetch miss; retry it
        -- once shortly after, in case the failure was a transient timeout.
        -- image_num is a display slot -- a spread under dual-page, half a sheet
        -- under the split -- and the caches are keyed by source page, so map
        -- across before looking anything up.
        local src = sourceOfSlot(image_num or 1)
        local index = src and (src - 1) or -1
        if index >= 0 and cache[index] == nil and not retried[index] then
            retried[index] = true
            UIManager:scheduleIn(2.5, function()
                if closed or viewer._images_list_cur ~= image_num then return end
                if cache[index] ~= nil then return end
                log("page %d: retrying after failure", index)
                reloadCurrentPage("retry after failure")
            end)
        end
        schedulePrefetch()
    end

    -- The memory cache holds plain strings, so there is nothing to free, but a
    -- queued prefetch must not outlive the viewer and touch it after it is gone.
    local orig_on_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(this, ...)
        closed = true
        UIManager:unschedule(prefetchNext)
        -- Left-handed hold flips the whole screen; the file manager does not
        -- want to inherit that, so the rotation the chapter was opened in is
        -- restored when the viewer goes down. Only if it actually changed: on
        -- a fresh KOReader the screen is already upright, and setting the
        -- same mode back is harmless, but skipping the call keeps the log's
        -- setRotationMode noise out.
        if Screen:getRotationMode() ~= viewer.orig_rotation_mode then
            Screen:setRotationMode(viewer.orig_rotation_mode)
        end
        -- Read before anything is torn down: the slot-to-page mapping goes away
        -- with the viewer, and the number the catalog understands is the source
        -- page, not the slot.
        local last_source = currentSourcePage()
        cache, cache_bytes = {}, 0
        crop_cache, half_crop_cache = {}, {}
        -- The stash holds a buffer, not a box, so it has to be let go by hand
        -- rather than dropped with the two tables above.
        dropStash()
        -- Deferred: onCloseWidget runs inside the close, and the report is a
        -- synchronous request that owns the UI thread for as long as it takes.
        -- A beat later the browser is already on screen and a hitch is just a
        -- hitch. Explicitly not guarded on `closed`, which is true by now.
        UIManager:scheduleIn(PROGRESS_REPORT_DELAY, function()
            reportProgress(last_source)
        end)
        return orig_on_close_widget(this, ...)
    end

    -- The stock bar offers scale / rotate / close. Add a page jump and an
    -- auto-crop toggle.
    --
    -- The "scale" and "rotate" ids have to survive: ImageViewer:update() looks
    -- them up by id and calls setText() on the result, so dropping either
    -- would crash on the very next repaint.
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")

    viewer.button_table = ButtonTable:new{
        width = viewer.width - 2 * viewer.button_padding,
        buttons = {
            {
                {
                    -- id "scale" is required by ImageViewer:update()
                    id = "scale",
                    icon = "appbar.pagefit",
                    callback = function()
                        viewer.scale_factor = viewer._scale_to_fit and 1 or 0
                        viewer._scale_to_fit = not viewer._scale_to_fit
                        viewer._center_x_ratio = 0.5
                        viewer._center_y_ratio = 0.5
                        viewer:update()
                    end,
                },
                {
                    -- id "rotate" is required by ImageViewer:update()
                    id = "rotate",
                    icon = "appbar.rotation",
                    -- toggleRotation also turns dual-page on and off with the
                    -- rotation, so it may have to re-pair the pages and redraw.
                    -- When neither the pairing nor the crop changed, it only
                    -- re-applies the rotation to the buffer already decoded.
                    callback = toggleRotation,
                    hold_callback = showDisplayDialog,
                },
                {
                    id = "goto",
                    icon = "appbar.search",
                    -- Both numbers are read at tap time: the split learns what
                    -- each sheet holds as it reads, so where the reader is moves
                    -- during a chapter even though the total does not.
                    callback = function()
                        OPDSPSE:jumpToPage(viewer, count, currentSourcePage(), firstSlotOfSource)
                    end,
                },
                {
                    id = "crop",
                    icon = "appbar.crop",
                    -- The checkmark is gone along with the text. Button paints
                    -- a ✓ by appending to its text and refreshing the label
                    -- with setText(), and an icon button's label is an
                    -- IconWidget, which has no setText -- keeping the
                    -- checked_func would crash on the very tap that toggles it.
                    callback = function()
                        G_reader_settings:flipNilOrFalse(AUTOCROP_KEY)
                        -- the setting changed, so measure again
                        crop_cache, half_crop_cache = {}, {}
                        -- Same reason, and one stronger: the stash is not a box
                        -- but a finished picture cut to the old box. Keeping it
                        -- would show the reader the crop they just turned off.
                        dropStash()
                        -- reloadCurrentPage goes through switchToImageNum, which
                        -- ends in update(); a second update() here would free
                        -- the widget it just built and resample the same buffer
                        -- again, plus one more full-screen refresh. The tick in
                        -- this button's own checkbox is repainted by the tap.
                        reloadCurrentPage("auto-crop")
                    end,
                },
                {
                    id = "darken",
                    icon = "appbar.contrast",
                    callback = function()
                        -- Re-renders the current page on close only, not per
                        -- tick: a tick is a ~1.3 s decode-and-crop, far too slow
                        -- to sit inside the widget's feedback loop. The number
                        -- in the middle is the feedback.
                        local SpinWidget = require("ui/widget/spinwidget")
                        -- What the page underneath was drawn with. Closing
                        -- without moving the control is a common way out of this
                        -- dialog, and it used to buy a full decode to redraw a
                        -- page that was already right -- three times in one
                        -- measured session. Compared against the saved setting
                        -- rather than the widget's own number, because the
                        -- setting is what reaches the renderer.
                        local before = gammaValue()
                        UIManager:show(SpinWidget:new{
                            title_text = L("Tone", "明暗"),
                            info_text = L("1.0 is untouched: above darkens, below brightens. The steps above 1.0 are coarse because a small gamma is invisible on e-ink.",
                                          "1.0 为原样：大于 1 加深，小于 1 提亮。1.0 以上的档位跨度大，因为小幅调整在墨水屏上看不出来。"),
                            -- A value_table, not a range: the ladder carries two
                            -- resolutions and one value_step cannot express both.
                            -- The entries are what gets printed, which is also
                            -- why they are strings -- "1.0" has to stay "1.0".
                            value_table = TONE_LEVELS,
                            value_index = toneIndex(gammaValue()),
                            value_hold_step = 4, -- one hold crosses the bright side
                            -- Deliberately not SpinWidget's own default_value
                            -- button: with a value_table that button sets only
                            -- value_index, while the picker prints and reports
                            -- self.value -- so it would save the old gamma from
                            -- under a label reading "Default value: 1.0". This
                            -- one writes the setting itself; the close callback
                            -- below is what re-renders.
                            extra_text = L("Back to 1.0", "恢复原样 1.0"),
                            extra_callback = function()
                                G_reader_settings:saveSetting(DARKEN_KEY, DARKEN_DEFAULT)
                            end,
                            callback = function(spin)
                                G_reader_settings:saveSetting(DARKEN_KEY, tonumber(spin.value))
                            end,
                            close_callback = function()
                                -- The gamma actually in force, stated here rather
                                -- than only inside the render pass: at 1.0 that
                                -- pass is skipped and logs nothing at all, so a
                                -- log without this line cannot tell "the control
                                -- was left alone" from "the new value never
                                -- reached the renderer".
                                local after = gammaValue()
                                log("tone: %.1f", after)
                                if after == before then return end
                                -- Finished pictures carry the old curve. The crop
                                -- boxes do not: they are measured on untoned
                                -- pixels now, so re-measuring them here would
                                -- only spend that time a second time.
                                dropStash()
                                reloadCurrentPage("darken")
                            end,
                        })
                    end,
                },
                {
                    id = "close",
                    icon = "close",
                    callback = function() viewer:onClose() end,
                },
            },
        },
        zero_sep = true,
        show_parent = viewer,
    }

    -- ImageViewer:update() relabels the scale/rotate buttons via setText(),
    -- which on these icon-carrying buttons would rebuild them as text buttons
    -- (setText calls init() and swaps the label widget). The relabel exists to
    -- flip a textual label the icons have replaced, so it is swallowed; the ids
    -- themselves are still required by update(), and the wrapper keeps them.
    for _, btn_id in ipairs({ "scale", "rotate" }) do
        local btn = viewer.button_table:getButtonById(btn_id)
        function btn:setText() end
    end
    viewer.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = viewer.width,
            h = viewer.button_table:getSize().h,
        },
        viewer.button_table,
    }

    UIManager:show(viewer)
    if continue then
        self:jumpToPage(viewer, count, currentSourcePage(), firstSlotOfSource)
    elseif last_page_read then
        -- last_page_read is a source page from the catalog; the viewer counts
        -- display slots, which are spreads under dual-page and halves of a
        -- sheet under the split.
        viewer:switchToImageNum(firstSlotOfSource(last_page_read))
    else
        -- add 1 since Kavita's Page count is zero based
        -- and ImageViewer is not.
        viewer:switchToImageNum(last_page+1)
    end

    -- Where the reader landed. Recorded after the jump above, so the close-time
    -- report can tell a chapter that was read from one that was merely opened
    -- and closed -- and never moves the catalog's position backwards because of
    -- the latter. See reportProgress.
    initial_source = currentSourcePage()

    -- Trim the disk cache once the viewer is up, so opening a chapter never
    -- waits on a directory walk.
    UIManager:scheduleIn(5, function()
        if closed then return end
        diskCacheEvict()
    end)
end

--- Shows a page number dialog for page streaming.
---
--- The numbers are source pages, the ones the catalog shows, whatever the
--- display mode happens to be. Counting screens instead would have the reader
--- converting in their head to answer "which page am I on": a spread would be
--- two of them under dual-page and one sheet would be two more under the split,
--- so the same book would report three different totals. `to_slot` maps the
--- answer onto whatever the viewer is counting; it is handed in rather than
--- recomputed here because the mapping lives in streamPages.
function OPDSPSE:jumpToPage(viewer, count, current_source, to_slot)
    local total = count
    local current = current_source or 1
    local input_dialog
    input_dialog = InputDialog:new{
        title = T(L("Page %1 of %2", "第 %1 页，共 %2 页"), current, total),
        input = tostring(current),
        input_type = "number",
        input_hint = "(" .. "1 - " .. total .. ")",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Stream"),
                    is_enter_default = true,
                    callback = function()
                        local page_num = input_dialog:getInputValue()
                        if page_num then
                            UIManager:close(input_dialog)
                            -- floor before the clamp: input_type="number" hands
                            -- back tonumber(text), so a reader who types "12.5"
                            -- gets a fractional page. firstSlotOfSource() counts
                            -- with an integer loop, and a fraction steps through
                            -- it zero times -- the jump would land somewhere
                            -- else entirely, without a word about it.
                            local target = math.floor(math.min(math.max(1, page_num), total))
                            viewer:switchToImageNum(to_slot and to_slot(target) or target)
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return OPDSPSE
