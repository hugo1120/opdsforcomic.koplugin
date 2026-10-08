-- Bounded decoders for oversized images on monochrome readers. Native APIs
-- used here contain their own error handling; no longjmp crosses Lua frames.
local Lowmem = {OUTPUT_BYTES = 8 * 1024 * 1024, WORK_BYTES = 64 * 1024 * 1024}
local png_api, jpeg_api

function Lowmem.targetSize(w, h, channels)
    local ratio = math.min(1, math.sqrt(Lowmem.OUTPUT_BYTES / (w * h * channels)))
    local tw, th = math.max(1, math.floor(w * ratio)), math.max(1, math.floor(h * ratio))
    -- Clamping a very thin image's short side to one pixel can exceed the
    -- area budget; constrain its long side after that rounding.
    if tw * th * channels > Lowmem.OUTPUT_BYTES then
        if tw < th then th = math.floor(Lowmem.OUTPUT_BYTES / channels / tw)
        else tw = math.floor(Lowmem.OUTPUT_BYTES / channels / th) end
    end
    return tw, th
end

local function fail(kind, detail)
    error({kind = kind, detail = detail}, 0)
end

local function errorResult(err)
    local kind, detail = require("opdsforcomic_image").errorKind(err)
    return nil, kind, detail
end

local function pngBackend()
    if png_api then return png_api end
    local ffi = require("ffi")
    require("ffi/leptonica_h")
    if not pcall(ffi.typeof, "opds_png_image") then
        ffi.cdef[[
        typedef struct {
            void *opaque;
            unsigned int version, width, height, format, flags, colormap_entries, warning_or_error;
            char message[64];
        } opds_png_image;
        int png_image_begin_read_from_memory(opds_png_image *, const void *, size_t);
        int png_image_finish_read(opds_png_image *, const void *, void *, int, void *);
        void png_image_free(opds_png_image *);
        PIX *pixCreate(l_int32, l_int32, l_int32);
        l_uint32 *pixGetData(PIX *);
        l_int32 pixGetWpl(const PIX *);
        l_ok pixSetSpp(PIX *, l_int32);
        l_ok pixEndianByteSwap(PIX *);
        PIX *pixScaleAreaMap(PIX *, l_float32, l_float32);
        PIX *pixScaleGrayLI(PIX *, l_float32, l_float32);
        PIX *pixScaleColorLI(PIX *, l_float32, l_float32);
        PIX *pixGetRGBComponent(PIX *, l_int32);
        l_ok pixSetRGBComponent(PIX *, PIX *, l_int32);
        ]]
    end
    local P, L = ffi.loadlib("png16", 16), ffi.loadlib("leptonica", "6")
    -- Resolve symbols before allocating decoder state or pixel storage.
    assert(P.png_image_begin_read_from_memory and P.png_image_finish_read and P.png_image_free)
    assert(L.pixCreate and L.pixScaleAreaMap and L.pixScaleGrayLI and L.pixScaleColorLI)
    assert(L.pixSetSpp and L.pixEndianByteSwap and L.pixGetData and L.pixGetWpl)
    assert(L.pixGetRGBComponent and L.pixSetRGBComponent)
    png_api = {ffi = ffi, P = P, L = L, BB = require("ffi/blitbuffer")}
    return png_api
end

function Lowmem.decodePNG(data, log)
    local loaded, api = pcall(pngBackend)
    if not loaded then return nil, "backend", tostring(api) end
    local ffi, P, L, BB = api.ffi, api.P, api.L, api.BB
    local state = ffi.new("opds_png_image", {version = 1})
    local source, scaled = ffi.new("PIX*[1]"), ffi.new("PIX*[1]")
    local alpha_source, alpha_scaled = ffi.new("PIX*[1]"), ffi.new("PIX*[1]")
    local output
    local ok, err = pcall(function()
        if P.png_image_begin_read_from_memory(state, data, #data) == 0 then
            fail("decode", ffi.string(state.message))
        end
        local w, h = tonumber(state.width), tonumber(state.height)
        -- Keep alpha-bearing images in RGBA: interpolate premultiplied channels
        -- together instead of flattening transparent artwork onto a background.
        local alpha = require("bit").band(state.format, 1) ~= 0
        local channels = alpha and 4 or 1
        local stride = math.ceil(w * channels / 4) * 4
        if w < 1 or h < 1 or stride * h > Lowmem.WORK_BYTES then
            fail("budget", "PNG decoded pixels exceed the 64 MiB working budget")
        end
        source[0] = L.pixCreate(w, h, alpha and 32 or 8)
        if source[0] == nil then fail("memory", "cannot allocate PNG pixel buffer") end
        if alpha then L.pixSetSpp(source[0], 4) end
        state.format = alpha and 3 or 0 -- straight sRGB RGBA, or sRGB grayscale
        if P.png_image_finish_read(state, nil, L.pixGetData(source[0]), stride, nil) == 0 then
            local detail = ffi.string(state.message)
            local kind = require("opdsforcomic_image").errorKind(detail)
            fail(kind == "memory" and kind or "decode", detail)
        end
        if alpha then
            -- libpng's optimized associated-alpha mode mixes linear-light and
            -- sRGB samples. BB instead needs ordinary sRGB byte premultiplication.
            local p = ffi.cast("unsigned char*", L.pixGetData(source[0]))
            for i = 0, w * h * 4 - 4, 4 do
                local a = p[i + 3]
                if a < 255 then
                    p[i] = math.floor((p[i] * a + 127) / 255)
                    p[i + 1] = math.floor((p[i + 1] * a + 127) / 255)
                    p[i + 2] = math.floor((p[i + 2] * a + 127) / 255)
                end
            end
        end
        local tw, th = Lowmem.targetSize(w, h, channels)
        local sx, sy = tw / w, th / h
        local function resize(pix, is_gray)
            -- The generic scaler copies even plain 8bpp input. Calling the
            -- matching filter directly avoids another full grayscale sheet.
            if math.max(sx, sy) < 0.7 then return L.pixScaleAreaMap(pix, sx, sy) end
            if is_gray then return L.pixScaleGrayLI(pix, sx, sy) end
            return L.pixScaleColorLI(pix, sx, sy)
        end
        -- Leptonica's raster uses MSB-first words. Swap in place, with no second
        -- full-size image; pixScale chooses area sampling for strong reductions.
        L.pixEndianByteSwap(source[0])
        if alpha then
            -- Leptonica's automatic alpha transfer calls pixScale, which
            -- sharpens alpha even when the outer RGB resize disables it.
            -- Resize both planes explicitly with identical unsharpened filters.
            alpha_source[0] = L.pixGetRGBComponent(source[0], 3) -- L_ALPHA_CHANNEL
            if alpha_source[0] == nil then fail("memory", "cannot allocate alpha plane") end
            L.pixSetSpp(source[0], 3)
            scaled[0] = resize(source[0], false)
        else
            scaled[0] = resize(source[0], true)
        end
        if scaled[0] == nil then fail("memory", "cannot allocate resized PNG") end
        L.pixDestroy(source)
        if alpha then
            alpha_scaled[0] = resize(alpha_source[0], true)
            if alpha_scaled[0] == nil then fail("memory", "cannot allocate resized alpha") end
            L.pixDestroy(alpha_source)
            if L.pixSetRGBComponent(scaled[0], alpha_scaled[0], 3) ~= 0 then
                fail("render", "cannot attach resized alpha plane")
            end
            L.pixSetSpp(scaled[0], 4)
            L.pixDestroy(alpha_scaled)
        end
        L.pixEndianByteSwap(scaled[0])
        tw, th = L.pixGetWidth(scaled[0]), L.pixGetHeight(scaled[0])
        local kind = alpha and BB.TYPE_BBRGB32 or BB.TYPE_BB8
        local view = BB.new(tw, th, kind, L.pixGetData(scaled[0]), L.pixGetWpl(scaled[0]) * 4)
        output = BB.new(tw, th, kind)
        output:blitFrom(view, 0, 0, 0, 0, tw, th)
        if alpha and require("ffi/mupdf").bgr then
            local p = ffi.cast("unsigned char*", output.data)
            for i = 0, tw * th * 4 - 4, 4 do p[i], p[i + 2] = p[i + 2], p[i] end
        end
        if log then log("lowmem: PNG %dx%d -> %dx%d, %d bytes%s", w, h, tw, th,
            output.stride * output.h, alpha and " (alpha retained)" or " (direct gray)") end
    end)
    P.png_image_free(state)
    L.pixDestroy(alpha_scaled)
    L.pixDestroy(alpha_source)
    L.pixDestroy(scaled)
    L.pixDestroy(source)
    if not ok then
        if output then output:free() end
        return errorResult(err)
    end
    return output
end

local function jpegBackend()
    if jpeg_api then return jpeg_api end
    local ffi = require("ffi")
    require("ffi/turbojpeg_h")
    if not pcall(ffi.typeof, "opds_tjscalingfactor") then
        ffi.cdef[[
        typedef struct { int num, denom; } opds_tjscalingfactor;
        opds_tjscalingfactor *tj3GetScalingFactors(int *);
        int tj3SetScalingFactor(tjhandle, opds_tjscalingfactor);
        ]]
    end
    local J = ffi.loadlib("turbojpeg", "0.5.0", "turbojpeg", "0.4.0", "turbojpeg", "0.3.0", "turbojpeg")
    local init = pcall(function() return J.tj3Init end) and J.tj3Init or function(t)
        return J.tj3InitVersion(t, J.TURBOJPEG_VERSION_NUMBER)
    end
    assert(J.tj3GetScalingFactors and J.tj3SetScalingFactor)
    jpeg_api = {ffi = ffi, J = J, init = init, BB = require("ffi/blitbuffer")}
    return jpeg_api
end

function Lowmem.decodeJPEG(data, log)
    local loaded, api = pcall(jpegBackend)
    if not loaded then return nil, "backend", tostring(api) end
    local ffi, J, BB = api.ffi, api.J, api.BB
    local handle, output
    local ok, err = pcall(function()
        handle = api.init(J.TJINIT_DECOMPRESS)
        if handle == nil then fail("memory", "cannot allocate JPEG decoder") end
        local function checked(result)
            if result < 0 then
                local detail = ffi.string(J.tj3GetErrorStr(handle))
                local lower = detail:lower()
                if lower:find("memory limit", 1, true) or lower:find("backing store", 1, true)
                    or lower:find("too many scans", 1, true) or lower:find("scan limit", 1, true) then
                    fail("budget", detail)
                end
                if lower:find("unsupported", 1, true) or lower:find("not supported", 1, true) then
                    fail("backend", detail)
                end
                local kind = require("opdsforcomic_image").errorKind(detail)
                fail(kind == "memory" and kind or "decode", detail)
            end
        end
        -- Coefficient storage for progressive JPEGs also needs a bound.
        checked(J.tj3Set(handle, J.TJPARAM_MAXMEMORY, 32))
        checked(J.tj3Set(handle, J.TJPARAM_SCANLIMIT, 100))
        checked(J.tj3DecompressHeader(handle, data, #data))
        local w, h = J.tj3Get(handle, J.TJPARAM_JPEGWIDTH), J.tj3Get(handle, J.TJPARAM_JPEGHEIGHT)
        if w < 1 or h < 1 or w * h > Lowmem.WORK_BYTES then
            fail("budget", "JPEG dimensions exceed the low-memory working budget")
        end
        local count = ffi.new("int[1]")
        local factors, best, best_pixels = J.tj3GetScalingFactors(count), nil, 0
        if factors == nil then fail("backend", "JPEG scaling factors unavailable") end
        local tw, th
        for i = 0, count[0] - 1 do
            local f = factors[i]
            local cw, ch = math.ceil(w * f.num / f.denom), math.ceil(h * f.num / f.denom)
            local pixels = cw * ch
            if f.num <= f.denom and pixels <= Lowmem.OUTPUT_BYTES and pixels > best_pixels then
                best, best_pixels, tw, th = f, pixels, cw, ch
            end
        end
        if not best then fail("budget", "JPEG cannot fit the low-memory output budget") end
        checked(J.tj3SetScalingFactor(handle, best))
        output = BB.new(tw, th, BB.TYPE_BB8)
        checked(J.tj3Decompress8(handle, data, #data, ffi.cast("unsigned char*", output.data),
            output.stride, J.TJPF_GRAY))
        if log then log("lowmem: JPEG %dx%d -> %dx%d, %d bytes", w, h, tw, th, output.stride * output.h) end
    end)
    if handle ~= nil then J.tj3Destroy(handle) end
    if not ok then
        if output then output:free() end
        return errorResult(err)
    end
    return output
end

return Lowmem
