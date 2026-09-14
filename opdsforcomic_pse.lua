local http = require("socket.http")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local ltn12 = require("ltn12")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local url = require("socket.url")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSPSE = {}

-- Page prefetching.
--
-- Without it, every page turn blocks the UI thread on a synchronous HTTP
-- fetch followed by a JPEG decode: page N is only requested when the viewer
-- asks for it. We keep the raw bytes of the next few pages in memory,
-- fetched while the reader is still looking at the current page, so a page
-- turn only has to decode.
--
-- Only raw bytes are cached, never the decoded BlitBuffer. The ImageViewer
-- owns and frees whatever BlitBuffer it is handed (see the
-- page_table.image_disposable note in streamPages), so holding decoded
-- buffers here would risk handing it a buffer we had already freed. Bytes
-- are cheap to hold, and leaving the disposal model alone keeps this safe.
local PREFETCH_AHEAD = 2    -- pages past the current one to keep ready
local PREFETCH_DELAY = 0.35 -- seconds to wait after a page turn before fetching
local CACHE_LIMIT = 5       -- max pages of raw bytes held at once

-- A prefetch runs while the reader is looking at another page, so a stalled
-- request must not freeze the UI for the full minute that the regular
-- FILE_TOTAL_TIMEOUT allows. A user-initiated page turn keeps the original,
-- more generous timeouts: there the wait is expected.
local PREFETCH_BLOCK_TIMEOUT = 8
local PREFETCH_TOTAL_TIMEOUT = 20

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
        logger.dbg("Couldn't pull progress, defaulting to Page 0.")
        last_page = 0
    end

    -- Raw image bytes, keyed by 0-based page index (ImageViewer page numbers
    -- are 1-based, so index == key - 1, as elsewhere in this file).
    local cache = {}
    local cache_order = {}
    local closed = false

    local function cacheStore(index, data)
        if cache[index] == nil then
            table.insert(cache_order, index)
        end
        cache[index] = data
        while #cache_order > CACHE_LIMIT do
            cache[table.remove(cache_order, 1)] = nil
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

        logger.dbg("Streaming page from", page_url)
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

        if code == 200 then
            return table.concat(page_data)
        end
        logger.dbg("OPDSPSE:streamPages: Request failed:", status or code)
        logger.dbg("OPDSPSE:streamPages: Response headers:", headers)
        return nil, status or code
    end

    local page_table = {image_disposable = true}
    setmetatable(page_table, {__index = function (_, key)
        if type(key) ~= "number" then
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        local index = key - 1
        local data = cache[index]
        if data == nil then
            data = fetchPageData(index)
            if data then cacheStore(index, data) end
        end
        if data then
            return RenderImage:renderImageData(data, #data, false)
                or RenderImage:renderImageFile("resources/koreader.png", false)
        end
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end})

    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = count,
    }

    -- Fill the look-ahead window one page per scheduled callback, so no single
    -- fetch blocks for long and the pending one stays cancellable. The chain
    -- stops on failure and re-arms on the next page turn, which keeps a dead
    -- server from being hammered.
    local schedulePrefetch
    local function prefetchNext()
        if closed then return end
        local current = viewer._images_list_cur
        if not current then return end
        local target
        for offset = 1, PREFETCH_AHEAD do
            local index = current - 1 + offset
            if index >= 0 and index < count and cache[index] == nil then
                target = index
                break
            end
        end
        if target == nil then return end
        local data = fetchPageData(target, true)
        if data then
            cacheStore(target, data)
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
        schedulePrefetch()
    end

    -- The cache holds plain strings, so there is nothing to free, but a queued
    -- prefetch must not outlive the viewer and touch it after it is gone.
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
