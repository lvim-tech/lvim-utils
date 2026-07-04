-- lvim-utils.image.util: format-free geometry helpers for the image pipeline — read a raster's pixel
-- dimensions WITHOUT a subprocess (PNG/GIF/JPEG headers are parsed inline), and convert between pixels and
-- terminal CELLS given the live cell-pixel size. Kept dependency-free so the sizing math never needs libvips.
--
---@module "lvim-utils.image.util"

local M = {}

---@class lvim-utils.image.Dim
---@field w integer  pixel width
---@field h integer  pixel height

--- Read the 4-byte big-endian unsigned int at 1-based byte offset `i` in `s`.
---@param s string
---@param i integer
---@return integer
local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a or 0) * 0x1000000) + ((b or 0) * 0x10000) + ((c or 0) * 0x100) + (d or 0)
end

--- Read the 2-byte big-endian unsigned int at 1-based byte offset `i` in `s`.
---@param s string
---@param i integer
---@return integer
local function u16be(s, i)
    local a, b = s:byte(i, i + 1)
    return ((a or 0) * 0x100) + (b or 0)
end

--- Pixel dimensions of a PNG from its IHDR chunk. Width/height are the two big-endian u32 right after the
--- 8-byte signature + 4-byte length + "IHDR" tag (bytes 17..24). No subprocess, no decode.
---@param s string  the first bytes of the file (≥ 24)
---@return lvim-utils.image.Dim?
local function png_dim(s)
    if s:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil
    end
    if s:sub(13, 16) ~= "IHDR" then
        return nil
    end
    return { w = u32be(s, 17), h = u32be(s, 21) }
end

--- Pixel dimensions of a GIF (GIF87a/GIF89a) — width/height are little-endian u16 at bytes 7..10.
---@param s string
---@return lvim-utils.image.Dim?
local function gif_dim(s)
    local sig = s:sub(1, 6)
    if sig ~= "GIF87a" and sig ~= "GIF89a" then
        return nil
    end
    local a, b, c, d = s:byte(7, 10)
    return { w = (b or 0) * 256 + (a or 0), h = (d or 0) * 256 + (c or 0) }
end

--- Pixel dimensions of a JPEG by walking its marker segments to the SOFn frame header (which carries the
--- image height/width as big-endian u16). Returns nil for progressive edge cases we cannot cheaply parse.
---@param s string
---@return lvim-utils.image.Dim?
local function jpeg_dim(s)
    if s:byte(1) ~= 0xFF or s:byte(2) ~= 0xD8 then
        return nil
    end
    local i = 3
    local n = #s
    while i < n do
        if s:byte(i) ~= 0xFF then
            return nil
        end
        local marker = s:byte(i + 1)
        -- SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15 carry the frame dimensions.
        local is_sof = (marker >= 0xC0 and marker <= 0xCF)
            and marker ~= 0xC4 -- DHT
            and marker ~= 0xC8 -- JPG
            and marker ~= 0xCC -- DAC
        if is_sof then
            return { h = u16be(s, i + 5), w = u16be(s, i + 7) }
        end
        local seglen = u16be(s, i + 2)
        if seglen < 2 then
            return nil
        end
        i = i + 2 + seglen
    end
    return nil
end

--- Pixel dimensions of a raster file, header-only (no decode / no subprocess). Reads just the first 32 KiB.
--- Handles PNG, GIF and JPEG — the formats whose size lives in a fixed header. For everything else the
--- caller falls back to the decoder (libvips), which returns real dimensions anyway.
---@param path string
---@return lvim-utils.image.Dim?
function M.file_dim(path)
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local head = fd:read(32768) or ""
    fd:close()
    return png_dim(head) or gif_dim(head) or jpeg_dim(head)
end

--- Pixel dimensions from an already-loaded header string (same detectors as `file_dim`).
---@param head string
---@return lvim-utils.image.Dim?
function M.bytes_dim(head)
    return png_dim(head) or gif_dim(head) or jpeg_dim(head)
end

--- Convert a pixel box to a CELL box for the given cell-pixel size, rounding UP so the image is never
--- clipped short by a fractional final row/column.
---@param px_w integer
---@param px_h integer
---@param cell_w integer  pixels per cell column
---@param cell_h integer  pixels per cell row
---@return integer cols, integer rows
function M.pixels_to_cells(px_w, px_h, cell_w, cell_h)
    local cols = math.max(1, math.ceil(px_w / math.max(1, cell_w)))
    local rows = math.max(1, math.ceil(px_h / math.max(1, cell_h)))
    return cols, rows
end

--- Fit a `(w, h)` cell box inside a `(max_w, max_h)` cell box, preserving aspect ratio. Only shrinks
--- (never upscales past the source), so a small image stays its natural cell size.
---@param w integer
---@param h integer
---@param max_w integer
---@param max_h integer
---@return integer cols, integer rows
function M.fit(w, h, max_w, max_h)
    if w <= 0 or h <= 0 then
        return 1, 1
    end
    local scale = math.min(max_w / w, max_h / h, 1)
    local cols = math.max(1, math.floor(w * scale + 0.5))
    local rows = math.max(1, math.floor(h * scale + 0.5))
    return cols, rows
end

return M
