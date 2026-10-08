-- Plugin-local image and cache policies; no changes to KOReader globals.
local Perf = {}

function Perf.canStash(bb)
    -- Leave room for the next decode instead of duplicating a huge whole sheet.
    return bb.stride * bb.h <= 8 * 1024 * 1024
end

-- Use the same luminance conversion as Blitbuffer's final grayscale blit.
-- Alpha-bearing images retain their format to preserve composition semantics.
function Perf.grayscale(bb, log)
    local Device = require("device")
    local BB = require("ffi/blitbuffer")
    local kind = bb:getType()
    if Device:hasColorScreen() or (kind ~= BB.TYPE_BBRGB24 and kind ~= BB.TYPE_BBRGB16) then
        return bb
    end
    local gray
    local ok = pcall(function()
        gray = BB.new(bb:getWidth(), bb:getHeight(), BB.TYPE_BB8)
        gray:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
    end)
    if not ok then
        if gray then gray:free() end
        return bb
    end
    if log then log("grayscale: %d -> %d bytes", bb.stride * bb.h, gray.stride * gray.h) end
    bb:free()
    return gray
end

-- Wrap only this widget. Its source remains full resolution for future zooms;
-- ImageWidget owns the temporary scaled/rotated buffer, as in its normal path.
function Perf.prepareWidget(widget, log, now)
    local render = widget._render
    widget._render = function(this)
        if this._bb then return end
        local started = now()
        local source, requested = this.image, this.scale_factor
        local disposable = this.image_disposable
        local angle = this.rotation_angle or 0
        local factor, w, h
        if source and angle % 180 ~= 0 and requested ~= nil then
            w, h = source:getWidth(), source:getHeight()
            factor = requested == 0 and math.min(this.width / h, this.height / w) or requested
        end
        local scaled
        if factor and factor > 0 and factor < 1 then
            local ok, result = pcall(function()
                return require("ui/renderimage"):scaleBlitBuffer(source,
                    math.max(1, math.floor(w * factor)), math.max(1, math.floor(h * factor)), false)
            end)
            if ok and result and result ~= source then
                scaled = result
                this.image, this.image_disposable, this.scale_factor = scaled, true, 1
            end
        end
        local ok, err = pcall(render, this)
        this.image, this.image_disposable = source, disposable
        if not ok then
            if this._bb and this._bb ~= source and this._bb_disposable then
                this._bb:free()
            elseif scaled and not this._bb then
                scaled:free()
            end
            this._bb, this._bb_disposable = nil, false
            this.scale_factor, this._initial_scale_factor = requested, requested
            this._img_w, this._img_h, this._bb_w, this._bb_h = nil, nil, nil, nil
            error(err, 0)
        end
        if scaled then
            this.scale_factor = factor
            this._initial_scale_factor = requested
            this._img_w, this._img_h = h, w
        end
        log("display: %d ms%s", math.floor((now() - started) * 1000),
            scaled and " (scale before rotation)" or "")
    end
end

-- Decide admission before changing the cache. Only replace pages farther away
-- than the target, so a speculative request cannot displace the current page.
function Perf.rawAdmission(cache, target, size, current, budget)
    if size > budget then return nil end
    local total, candidates = size, {}
    local distance = math.abs(target - current)
    for index, data in pairs(cache) do
        if index ~= target then
            total = total + #data
            if math.abs(index - current) > distance then
                candidates[#candidates + 1] = index
            end
        end
    end
    table.sort(candidates, function(a, b) return math.abs(a-current) > math.abs(b-current) end)
    local evict = {}
    for _, index in ipairs(candidates) do
        if total <= budget then break end
        total = total - #cache[index]
        evict[#evict + 1] = index
    end
    return total <= budget and evict or nil
end

function Perf.prefetchTarget(cache, current, count, ahead, behind, direction, budget, on_disk)
    local bytes, entries = 0, 0
    for _, data in pairs(cache) do bytes, entries = bytes + #data, entries + 1 end
    local estimate = entries > 0 and math.ceil(bytes / entries) or 256 * 1024
    local function scan(sign, depth)
        for offset = 1, depth do
            local index = current + offset * sign
            if index >= 0 and index < count and not cache[index] and not on_disk(index)
                and Perf.rawAdmission(cache, index, estimate, current, budget) then
                return index
            end
        end
    end
    if direction < 0 then return scan(-1, ahead) or scan(1, behind) end
    return scan(1, ahead) or scan(-1, behind)
end

return Perf
