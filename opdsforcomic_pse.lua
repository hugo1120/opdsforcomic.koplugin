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
--- Delay between successive fetches while filling the window. Much shorter
--- than PREFETCH_DELAY: that delay exists to let a page turn settle, and
--- paying it again between chain steps just means the window fills slower
--- than the link allows, so the reader outruns it.
local PREFETCH_CHAIN_DELAY = 0.05
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

local function cropTo(bb, box)
    local w, h = box[3] - box[1], box[4] - box[2]
    if w <= 0 or h <= 0 then return nil end
    local Blitbuffer = require("ffi/blitbuffer")
    local out = Blitbuffer.new(w, h, bb:getType())
    if not out then return nil end
    out:blitFrom(bb, 0, 0, box[1], box[2], w, h)
    return out
end

local function renderBounded(data, index, crop_cache)
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        log("page %d: decode failed (%d bytes)", index, #data)
        return nil
    end

    if G_reader_settings:isTrue(AUTOCROP_KEY) and crop_cache then
        -- Measured once per page and remembered; false means "measured, and
        -- there was nothing worth cutting".
        local box = crop_cache[index]
        if box == nil then
            box = measureCrop(bb) or false
            crop_cache[index] = box
            if box then
                log("page %d: crop %dx%d -> %d,%d..%d,%d",
                    index, bb:getWidth(), bb:getHeight(),
                    box[1], box[2], box[3], box[4])
            else
                log("page %d: nothing to trim", index)
            end
        end
        if box then
            local cropped = cropTo(bb, box)
            if cropped then
                bb:free()
                bb = cropped
            end
        end
    end

    if MAX_DECODE_SCALE <= 0 then
        return bb
    end
    local w, h = bb:getWidth(), bb:getHeight()
    local max_w = Screen:getWidth() * MAX_DECODE_SCALE
    local max_h = Screen:getHeight() * MAX_DECODE_SCALE
    if w <= max_w and h <= max_h then
        return bb
    end
    local ratio = math.min(max_w / w, max_h / h)
    local tw, th = math.floor(w * ratio), math.floor(h * ratio)
    -- free_orig_bb=false: keep the original if scaling fails, so we never
    -- hand back a buffer that was already freed. scaleBlitBuffer returns the
    -- input unchanged when the target size already matches, so only free the
    -- original when we actually got a distinct buffer back.
    local scaled = RenderImage:scaleBlitBuffer(bb, tw, th, false)
    if scaled and scaled ~= bb then
        bb:free()
        log("page %d: downscaled %dx%d -> %dx%d", index, w, h, tw, th)
        return scaled
    end
    log("page %d: downscale failed, using full size %dx%d", index, w, h)
    return bb
end

-- This function attempts to pull chapter progress from Kavita.
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
            sink        = ltn12.sink.table(auth_data),
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
                sink        = ltn12.sink.table(progress_data),
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
            -- if HTTP GET was successful, pull page number from response
            last_page = progress_data[1]:match("\"pageNum\":(.+),\"seriesId")
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

    log("opening stream: %d pages", count)

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
    local closed = false
    local retried = {}
    local last_failure_notice = 0

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
            -- viewer is still nil while ImageViewer's constructor loads the
            -- very first page; treat that as being on page 0.
            local current = (viewer and viewer._images_list_cur or 1) - 1
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
        page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
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
            sink        = ltn12.sink.table(page_data),
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
    setmetatable(page_table, {__index = function (_page_table, key)
        if type(key) ~= "number" then
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        local index = key - 1
        local started = now()
        local data, source = loadPage(index, false)
        if not data then
            log("page %d: no data, showing placeholder", index)
            -- Failures are deliberately not cached, so turning away and back
            -- retries instead of showing the placeholder forever. Tell the
            -- reader what happened, throttled so a run of failures is not a
            -- stream of popups.
            if os.time() - last_failure_notice > 20 then
                last_failure_notice = os.time()
                Notification:notify(
                    T(_("Page %1 failed to load. Turn the page and back to retry."), index + 1),
                    Notification.SOURCE_ALWAYS_SHOW)
            end
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        local bb = renderBounded(data, index, crop_cache)
        if not bb then
            cacheDrop(index)
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        log("page %d: ready in %d ms via %s", index, elapsedMs(started), source)
        return bb
    end})

    local ImageViewer = require("ui/widget/imageviewer")
    viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = count,
    }

    -- Re-render the current page from scratch. Used to recover from a failed
    -- load without making the reader navigate away and back by hand.
    local function reloadCurrentPage()
        local current = viewer._images_list_cur
        if not current then return end
        viewer._images_list_cur = nil -- defeat switchToImageNum's no-op check
        viewer:switchToImageNum(current)
    end

    -- Fill the look-ahead window one page per scheduled callback, so no single
    -- fetch blocks for long and the pending one stays cancellable. The chain
    -- stops on failure and re-arms on the next page turn, which keeps a dead
    -- server from being hammered.
    local schedulePrefetch
    local function prefetchNext()
        if closed then return end
        local current = viewer._images_list_cur
        if not current then return end
        local base = current - 1
        -- A page already on disk needs no prefetch: it will load quickly
        -- enough on demand, and re-downloading it would waste the network we
        -- are trying to spare.
        local function needed(index)
            return index >= 0 and index < count
                and cache[index] == nil
                and not diskCacheHas(pageKey(index))
        end
        local target
        for offset = 1, PREFETCH_AHEAD do
            if needed(base + offset) then
                target = base + offset
                break
            end
        end
        if target == nil then
            for offset = 1, PREFETCH_BEHIND do
                if needed(base - offset) then
                    target = base - offset
                    break
                end
            end
        end
        if target == nil then return end
        local data = fetchPageData(target, true)
        if data then
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
        local index = (image_num or 0) - 1
        if index >= 0 and cache[index] == nil and not retried[index] then
            retried[index] = true
            UIManager:scheduleIn(2.5, function()
                if closed or viewer._images_list_cur ~= image_num then return end
                if cache[index] ~= nil then return end
                log("page %d: retrying after failure", index)
                reloadCurrentPage()
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
        cache, cache_bytes = {}, 0
        crop_cache = {}
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
                    text = viewer._scale_to_fit and _("Original size") or _("Scale"),
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
                    text = viewer.rotated and _("No rotation") or _("Rotate"),
                    callback = function()
                        viewer.rotated = not viewer.rotated and true or false
                        viewer:update()
                    end,
                },
                {
                    id = "goto",
                    text = L("Go to", "跳转"),
                    callback = function() OPDSPSE:jumpToPage(viewer, count) end,
                },
                {
                    id = "crop",
                    text = L("Crop", "裁剪"),
                    -- Button appends a checkmark when this is true, evaluated
                    -- at paint time, so no manual label refresh is needed.
                    checked_func = function()
                        return G_reader_settings:isTrue(AUTOCROP_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrFalse(AUTOCROP_KEY)
                        crop_cache = {} -- the setting changed, so measure again
                        reloadCurrentPage()
                        viewer:update()
                    end,
                },
                {
                    id = "close",
                    text = _("Close"),
                    callback = function() viewer:onClose() end,
                },
            },
        },
        zero_sep = true,
        show_parent = viewer,
    }
    viewer.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = viewer.width,
            h = viewer.button_table:getSize().h,
        },
        viewer.button_table,
    }

    UIManager:show(viewer)
    if continue then
        self:jumpToPage(viewer, count)
    elseif last_page_read then
        viewer:switchToImageNum(last_page_read)
    else
        -- add 1 since Kavita's Page count is zero based
        -- and ImageViewer is not.
        viewer:switchToImageNum(last_page+1)
    end

    -- Trim the disk cache once the viewer is up, so opening a chapter never
    -- waits on a directory walk.
    UIManager:scheduleIn(5, function()
        if closed then return end
        diskCacheEvict()
    end)
end

-- Shows a page number dialog for page streaming.
function OPDSPSE:jumpToPage(viewer, count)
    -- Pre-filled with where the reader already is, so this both answers "what
    -- page am I on" and lets that be adjusted.
    local current = viewer and viewer._images_list_cur or 1
    local input_dialog
    input_dialog = InputDialog:new{
        title = T(L("Page %1 of %2", "第 %1 页，共 %2 页"), current, count),
        input = tostring(current),
        input_type = "number",
        input_hint = "(" .. "1 - " .. count .. ")",
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
                            viewer:switchToImageNum(math.min(math.max(1, page_num), count))
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
