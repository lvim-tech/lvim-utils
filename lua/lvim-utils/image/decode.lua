-- lvim-utils.image.decode: turn any non-PNG raster (JPEG/GIF/WEBP/TIFF/HEIC/… and, via loaders, SVG/PDF) into
-- raw RGBA pixels IN MEMORY, using libvips through LuaJIT FFI. Nothing is ever written to disk — libvips
-- decodes to an in-memory sRGB + alpha uchar buffer that maps 1:1 onto the kitty `f=32` transmit format. This
-- is the whole point of the module's "no ImageMagick, no PNG cache" design: PNGs are passed through untouched
-- (see image.lua) and everything else is decoded here without a temp copy.
--
-- libvips' processing functions are variadic (a NULL-terminated option list); we call them with a trailing
-- `nil` to terminate with no options. `libvips.so.42` is discovered from a small soname list (overridable via
-- config.decode.libvips). The module degrades gracefully — if libvips cannot be loaded, `to_rgba` returns nil
-- and the caller reports "unsupported format".
--
---@module "lvim-utils.image.decode"

local config = require("lvim-utils.image.config")

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")

-- Common sonames across distros / macOS. config.decode.libvips overrides with an absolute path.
local SONAMES = { "libvips.so.42", "libvips.so", "libvips.42.dylib", "libvips.dylib", "libvips-42.dll" }

-- VipsInterpretation / VipsBandFormat enum values we need.
local VIPS_INTERPRETATION_sRGB = 22
local VIPS_FORMAT_UCHAR = 0

---@type ffi.namespace*|nil
local vips = nil
---@type boolean|nil
local ready = nil

--- Load + initialise libvips once. Returns false (cached) when it is unavailable so callers fall back.
---@return boolean
local function ensure()
    if ready ~= nil then
        return ready
    end
    if not ffi_ok then
        ready = false
        return false
    end
    pcall(
        ffi.cdef,
        [[
        typedef void VipsImage;
        int   vips_init(const char* argv0);
        VipsImage* vips_image_new_from_file(const char* name, ...);
        int   vips_colourspace(VipsImage* in, VipsImage** out, int space, ...);
        int   vips_addalpha(VipsImage* in, VipsImage** out, ...);
        int   vips_cast(VipsImage* in, VipsImage** out, int format, ...);
        void* vips_image_write_to_memory(VipsImage* in, size_t* size_out);
        int   vips_image_get_width(VipsImage* image);
        int   vips_image_get_height(VipsImage* image);
        int   vips_image_get_bands(VipsImage* image);
        const char* vips_error_buffer(void);
        void  vips_error_clear(void);
        void  g_object_unref(void* object);
        void  g_free(void* mem);
    ]]
    )
    local names = config.decode.libvips and { config.decode.libvips } or SONAMES
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            vips = lib
            break
        end
    end
    if not vips then
        ready = false
        return false
    end
    ready = pcall(vips.vips_init, "lvim-utils.image") and true or false
    return ready
end

--- Whether libvips-backed decoding is available on this system.
---@return boolean
function M.available()
    return ensure()
end

--- The last libvips error string (cleared as read).
---@return string
local function last_error()
    if not vips then
        return "libvips not loaded"
    end
    local msg = ffi.string(vips.vips_error_buffer())
    vips.vips_error_clear()
    return msg ~= "" and msg or "unknown libvips error"
end

---@class lvim-utils.image.decode.Result
---@field rgba string   raw RGBA bytes, row-major, width*height*4
---@field w integer     pixel width
---@field h integer     pixel height

--- Decode `path` to RGBA pixels entirely in memory (no temp file). Normalises to sRGB, ensures a 4th (alpha)
--- band and 8-bit samples, then reads the raw buffer — exactly the `f=32` layout kitty wants.
---@param path string
---@return lvim-utils.image.decode.Result? result, string? err
function M.to_rgba(path)
    if not ensure() then
        return nil, "libvips unavailable"
    end
    local v = assert(vips) -- non-nil once ensure() succeeded

    local img = v.vips_image_new_from_file(path, nil)
    if img == nil then
        return nil, "load failed: " .. last_error()
    end

    -- Chain: sRGB colourspace → ensure alpha → cast to uchar. Each step unrefs the previous image; `cur`
    -- always owns the single live VipsImage.
    local cur = img
    local function step(fn, ...)
        local out = ffi.new("VipsImage*[1]")
        if fn(cur, out, ...) ~= 0 then
            return false
        end
        v.g_object_unref(cur)
        cur = out[0]
        return true
    end

    if not step(v.vips_colourspace, VIPS_INTERPRETATION_sRGB, nil) then
        v.g_object_unref(cur)
        return nil, "colourspace failed: " .. last_error()
    end
    if v.vips_image_get_bands(cur) < 4 then
        if not step(v.vips_addalpha, nil) then
            v.g_object_unref(cur)
            return nil, "addalpha failed: " .. last_error()
        end
    end
    if not step(v.vips_cast, VIPS_FORMAT_UCHAR, nil) then
        v.g_object_unref(cur)
        return nil, "cast failed: " .. last_error()
    end

    local w = v.vips_image_get_width(cur)
    local h = v.vips_image_get_height(cur)
    local size = ffi.new("size_t[1]")
    local buf = v.vips_image_write_to_memory(cur, size)
    if buf == nil then
        v.g_object_unref(cur)
        return nil, "write_to_memory failed: " .. last_error()
    end

    local rgba = ffi.string(buf, size[0])
    v.g_free(buf)
    v.g_object_unref(cur)
    return { rgba = rgba, w = w, h = h }
end

return M
