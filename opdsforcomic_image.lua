-- Own every native resource until a fully independent BlitBuffer is ready.
-- No overrides of KOReader's shared renderers or global MuPDF context.
local Image = {}
local backend

function Image.errorKind(err)
    if type(err) == "table" and err.kind then return err.kind, err.detail end
    local detail = tostring(err)
    local lower = detail:lower()
    if lower:find("malloc", 1, true) or lower:find("allocate", 1, true)
        or lower:find("out of memory", 1, true) or lower:find("not enough memory", 1, true) then
        return "memory", detail
    end
    return "render", detail
end

-- Header-only inspection: no decoded pixel allocation or network request.
function Image.dimensions(data)
    local function u16(i)
        local a, b = data:byte(i, i + 1)
        return b and a * 256 + b
    end
    local function u32(i)
        local a, b = u16(i), u16(i + 2)
        return b and a * 65536 + b
    end
    if data:sub(1, 8) == "\137PNG\13\10\26\10" and data:sub(13, 16) == "IHDR" then
        return u32(17), u32(21)
    end
    if data:byte(1) == 255 and data:byte(2) == 216 then
        local i = 3
        while i + 3 <= #data do
            if data:byte(i) ~= 255 then break end
            local marker = data:byte(i + 1)
            if marker == 255 then i = i + 1
            elseif marker == 218 or marker == 217 then break
            else
                local length = u16(i + 2)
                if not length or length < 2 or i + 1 + length > #data then break end
                if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 200 and marker ~= 204
                    and length >= 8 then
                    return u16(i + 7), u16(i + 5)
                end
                i = i + 2 + length
            end
        end
    end
end

function Image.isLarge(data)
    local w, h = Image.dimensions(data)
    return w and h and w * h > 8 * 1024 * 1024 or false
end

local function getBackend()
    if backend then return backend end
    local ffi = require("ffi")
    require("ffi/mupdf_h")
    local path = package.searchpath and package.searchpath("ffi/mupdf", package.path) or "ffi/mupdf.lua"
    local file = path and io.open(path, "rb")
    if not file then error("cannot locate installed MuPDF version") end
    local source = file:read("*a")
    file:close()
    local version = source:match('local FZ_VERSION%s*=%s*"([%d%.]+)"')
    if not version then error("cannot determine installed MuPDF version") end
    backend = {ffi = ffi, M = ffi.loadlib("wrap-mupdf"), BB = require("ffi/blitbuffer"),
        version = version, settings = require("ffi/mupdf")}
    return backend
end

function Image.decodeMupdf(data, log)
    local loaded, api = pcall(getBackend)
    if not loaded then return nil, "backend", tostring(api) end
    local M, BB, ffi = api.M, api.BB, api.ffi
    local ctx, buffer, image, pixmap, output
    local function failed(stage)
        local detail = stage .. ": " .. ffi.string(M.mupdf_error_message(ctx))
        local kind = Image.errorKind(detail)
        error({kind = kind == "memory" and kind or "decode", detail = detail}, 0)
    end
    local ok, err = pcall(function()
        -- Match KOReader's store budget, but release this context on every path.
        ctx = M.fz_new_context_imp(nil, nil, 32 * 1024 * 1024, api.version)
        if ctx == nil then error({kind = "memory", detail = "cannot allocate MuPDF context"}, 0) end
        buffer = M.mupdf_new_buffer_from_shared_data(ctx, ffi.cast("unsigned char*", data), #data)
        if buffer == nil then failed("image buffer") end
        image = M.mupdf_new_image_from_buffer(ctx, buffer)
        if image == nil then failed("image header") end
        M.fz_drop_buffer(ctx, buffer); buffer = nil
        pixmap = M.mupdf_get_pixmap_from_image(ctx, image, nil, nil, nil, nil)
        if pixmap == nil then failed("image pixels") end
        M.fz_drop_image(ctx, image); image = nil
        local w, h = M.fz_pixmap_width(ctx, pixmap), M.fz_pixmap_height(ctx, pixmap)
        local n = M.fz_pixmap_components(ctx, pixmap)
        local types = {BB.TYPE_BB8, BB.TYPE_BB8A, BB.TYPE_BBRGB24, BB.TYPE_BBRGB32}
        if not types[n] then error({kind = "decode", detail = "unsupported image components"}, 0) end
        local gray = n == 3 and not require("device"):hasColorScreen()
        if api.settings.bgr and n >= 3 then
            local converted = M.mupdf_convert_pixmap(ctx, pixmap, M.fz_device_bgr(ctx), nil, nil,
                M.fz_default_color_params, n == 4 and 1 or 0)
            if converted == nil then failed("BGR conversion") end
            M.fz_drop_pixmap(ctx, pixmap); pixmap = converted
        end
        local view = BB.new(w, h, types[n], M.fz_pixmap_samples(ctx, pixmap))
        if gray then
            output = BB.new(w, h, BB.TYPE_BB8)
            output:blitFrom(view, 0, 0, 0, 0, w, h)
            if log then log("decode: RGB directly to gray, %d -> %d bytes (no RGB copy)", w*h*n, w*h) end
        else
            output = view:copy()
        end
    end)
    -- These drops also run when allocating/copying the final BB throws.
    if pixmap ~= nil then M.fz_drop_pixmap(ctx, pixmap) end
    if image ~= nil then M.fz_drop_image(ctx, image) end
    if buffer ~= nil then M.fz_drop_buffer(ctx, buffer) end
    if ctx ~= nil then M.fz_drop_context(ctx) end
    if not ok then
        if output then output:free() end
        local kind, detail = Image.errorKind(err)
        return nil, kind, detail
    end
    return output
end

function Image.decode(data, log)
    local jpeg = data:byte(1) == 255 and data:byte(2) == 216
    -- A permissive native JPEG parser may accept headers this small inspector
    -- cannot read. Unknown dimensions must never bypass the working budget.
    if (Image.isLarge(data) or (jpeg and not Image.dimensions(data)))
        and not require("device"):hasColorScreen() then
        local Lowmem = require("opdsforcomic_lowmem")
        if data:sub(1, 8) == "\137PNG\13\10\26\10" then
            return Lowmem.decodePNG(data, log)
        elseif jpeg then
            return Lowmem.decodeJPEG(data, log)
        end
    end
    local RenderImage = require("ui/renderimage")
    local header = data:sub(1, 4)
    if data:byte(1) == 255 and data:byte(2) == 216 then
        local ok, bb = pcall(RenderImage.renderJpegImageDataWithTurboJpeg, RenderImage, data, #data)
        if ok and bb then return bb end
        if not ok and Image.errorKind(bb) == "memory" then return nil, "memory", tostring(bb) end
    elseif header == "GIF8" or header == "RIFF" or header == "<svg" or header == "<?xm" then
        -- Call only the dedicated backend: the generic dispatcher would fall
        -- back to the shared MuPDF renderer and hide allocation failures.
        local render = header == "GIF8" and RenderImage.renderGifImageDataWithGifLib
            or header == "RIFF" and RenderImage.renderWebpImageDataWithLibwebp
            or RenderImage.renderSVGImageDataWithCRengine
        local ok, bb = pcall(render, RenderImage, data, #data)
        if ok and bb then return bb end
        if not ok then
            local kind, detail = Image.errorKind(bb)
            if kind == "memory" then return nil, kind, detail end
        end
    end
    return Image.decodeMupdf(data, log)
end

return Image
