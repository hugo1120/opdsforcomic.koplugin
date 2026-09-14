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
local PREFETCH_AHEAD = 2
local PREFETCH_BEHIND = 1
--- How long to wait after a page turn before fetching, in seconds.
local PREFETCH_DELAY = 0.35
--- Pages of raw bytes held in memory at once.
local MEM_CACHE_LIMIT = 6
--- Prefetch timeouts, in seconds. Much shorter than the ones used for a
--- user-initiated page turn: a prefetch runs while the reader is looking at
--- another page, so a stalled request must not freeze the UI for long. A
--- page that times out here is simply fetched again on a real page turn.
local PREFETCH_BLOCK_TIMEOUT = 4
local PREFETCH_TOTAL_TIMEOUT = 10

--- On-disk page cache. Survives restarts; harmless to disable.
local DISK_CACHE_ENABLED = true
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
local function renderBounded(data, index)
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        log("page %d: decode failed (%d bytes)", index, #data)
        return nil
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
    local cache, cache_order = {}, {}
    local closed = false
    local retried = {}
    local last_failure_notice = 0

    local function cacheStore(index, data)
        if cache[index] == nil then
            table.insert(cache_order, index)
        end
        cache[index] = data
        while #cache_order > MEM_CACHE_LIMIT do
            cache[table.remove(cache_order, 1)] = nil
        end
    end

    local function cacheDrop(index)
        if cache[index] ~= nil then
            cache[index] = nil
            for i, v in ipairs(cache_order) do
                if v == index then
                    table.remove(cache_order, i)
                    break
                end
            end
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
    setmetatable(page_table, {__index = function (_, key)
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
        local bb = renderBounded(data, index)
        if not bb then
            cacheDrop(index)
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        log("page %d: ready in %d ms via %s", index, elapsedMs(started), source)
        return bb
    end})

    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
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
            schedulePrefetch()
        end
    end
    schedulePrefetch = function()
        UIManager:unschedule(prefetchNext)
        UIManager:scheduleIn(PREFETCH_DELAY, prefetchNext)
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
        cache, cache_order = {}, {}
        return orig_on_close_widget(this, ...)
    end

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
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter page number"),
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
