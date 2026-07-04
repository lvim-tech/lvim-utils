-- lvim-utils.image.image: the protocol-agnostic Image identity. An Image owns a source (a file path today;
-- data URIs / in-memory pixels later), the pixel dimensions, a per-protocol transmit id, and the "already
-- sent" flag that gates re-transmission. It PREPARES the source into what the active protocol needs — a PNG
-- is passed through untouched (`kind = "png_file"`, zero conversion, zero disk); any other raster is decoded
-- to RGBA in memory by image/decode.lua (added incrementally). Actual escape encoding is delegated to the
-- picked backend in image/protocols/*.
--
---@module "lvim-utils.image.image"

local util = require("lvim-utils.image.util")
local terminal = require("lvim-utils.image.terminal")
local config = require("lvim-utils.image.config")

local M = {}

-- Lazily-required protocol backends, keyed by protocol id. Only the picked one is loaded.
---@type table<string, table|false>
local backends = {}
local function backend(name)
    if backends[name] == nil then
        local ok, mod = pcall(require, "lvim-utils.image.protocols." .. name)
        backends[name] = ok and mod or false
    end
    return backends[name] or nil
end

--- The active protocol id for this session (auto-detected unless pinned in config).
---@return string|nil
local function active_protocol()
    if config.backend ~= "auto" then
        return config.backend
    end
    return terminal.pick_protocol(config.force)
end

---@class lvim-utils.image.Image
---@field src string                 source path (absolute)
---@field id integer                 protocol transmit id (currently kitty's 24-bit id)
---@field protocol string            the backend that owns this image
---@field kind "png_file"|"png_bytes"|"rgba"|nil  how the payload is transmitted
---@field path string|nil            file path for `png_file` transmit
---@field bytes string|nil           in-memory bytes for `png_bytes`
---@field rgba string|nil            in-memory RGBA for `rgba` transmit
---@field w integer                  pixel width
---@field h integer                  pixel height
---@field sent boolean               transmitted to the terminal already
---@field err string|nil             preparation error, if any
local Image = {}
Image.__index = Image

--- Lower-case extension of a path (no dot), or "".
---@param path string
---@return string
local function ext(path)
    return (path:match("%.([%w]+)$") or ""):lower()
end

--- Create an Image for `src` under the active protocol. Does NOT transmit yet — call `:prepare()` then
--- `:transmit()`. Returns nil when no protocol is available.
---@param src string
---@return lvim-utils.image.Image|nil
function M.new(src)
    local proto = active_protocol()
    if not proto then
        return nil
    end
    local be = backend(proto)
    if not be then
        return nil
    end
    local self = setmetatable({
        src = vim.fn.fnamemodify(src, ":p"),
        protocol = proto,
        id = be.next_id and be.next_id() or 0,
        sent = false,
    }, Image)
    return self
end

--- Resolve the source into a transmittable payload + pixel dimensions. PNG → passthrough by file path (no
--- conversion, no disk). Non-PNG raster → decoded to RGBA in memory (image/decode.lua) when that module is
--- present; until then such sources set `err`. Idempotent.
---@return boolean ok
function Image:prepare()
    if self.kind then
        return true
    end
    if vim.fn.filereadable(self.src) ~= 1 then
        self.err = "not readable: " .. self.src
        return false
    end
    local e = ext(self.src)
    if e == "png" then
        local dim = util.file_dim(self.src)
        self.kind, self.path = "png_file", self.src
        self.w, self.h = dim and dim.w or 0, dim and dim.h or 0
        return true
    end
    -- Non-PNG: hand off to the in-memory decoder (libvips). Loaded lazily so PNG-only setups need nothing.
    local ok, decode = pcall(require, "lvim-utils.image.decode")
    if ok and decode then
        local res, derr = decode.to_rgba(self.src)
        if res then
            self.kind, self.rgba = "rgba", res.rgba
            self.w, self.h = res.w, res.h
            return true
        end
        self.err = derr or ("decode failed: " .. self.src)
        return false
    end
    self.err = "unsupported format '" .. e .. "' (decoder not available)"
    return false
end

--- Transmit the image to the terminal once (gated by `sent`).
function Image:transmit()
    if self.sent or not self.kind then
        return
    end
    local be = backend(self.protocol)
    if be and be.transmit then
        be.transmit(self)
        self.sent = true
    end
end

--- Cell size a `(cols, rows)` box for this image within a `(max_w, max_h)` CELL budget, aspect preserved.
--- The image's NATURAL cell size is fractional (px / cell-px); `util.fit` scales it into the budget and ROUNDS
--- (not ceils) so the box matches the image aspect as tightly as the cell grid allows — otherwise a tall cell
--- turns a fractional row into a whole empty one (a letterbox stripe above/below the image).
---@param max_w integer
---@param max_h integer
---@return integer cols, integer rows
function Image:cells(max_w, max_h)
    local cell = terminal.cell_size()
    local nat_cols = self.w / math.max(1, cell.w)
    local nat_rows = self.h / math.max(1, cell.h)
    return util.fit(nat_cols, nat_rows, max_w, max_h)
end

--- Delete this image (and all its placements) from the terminal.
function Image:delete()
    local be = backend(self.protocol)
    if be and be.delete then
        be.delete(self.id)
    end
    self.sent = false
end

return M
