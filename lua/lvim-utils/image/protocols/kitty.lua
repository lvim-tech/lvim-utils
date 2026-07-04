-- lvim-utils.image.protocols.kitty: the Kitty graphics protocol encoder (kitty, ghostty, wezterm-partial).
-- Every command is `ESC _ G <k=v,…> ; <base64 payload> ESC \` (APC-introduced, ST-terminated) written through
-- terminal.write (which adds tmux passthrough). We inject `q=2` on every command so the terminal never echoes
-- OK/error replies back into the tty.
--
-- Two transmit paths: a LOCAL png is sent by FILE PATH (`t=f`, zero image bytes over the tty); raw RGBA
-- pixels (from libvips) or a remote file are sent as CHUNKED base64 (`t=d`). Placement has two modes: unicode
-- PLACEHOLDERS (`U=1`, the robust extmark-anchored path, added by placement.lua) and a CURSOR-POSITIONED
-- fallback (`set_cursor` then `a=p`) for terminals without placeholder support.
--
---@module "lvim-utils.image.protocols.kitty"

local bit = require("bit")
local terminal = require("lvim-utils.image.terminal")

local b64 = vim.base64.encode

local M = {}

local CHUNK = 4096 -- kitty caps a single transmit payload chunk at 4096 base64 bytes

-- ── id scheme ───────────────────────────────────────────────────────────────
-- The kitty image id is 24-bit. Two Neovim instances sharing one kitty window must not collide, so we reserve
-- the top 10 bits for a per-process id derived from the PID and use the low 14 bits as a sequence.
local nvim_id =
    bit.band(bit.bxor(vim.fn.getpid(), bit.rshift(vim.fn.getpid(), 5), bit.rshift(vim.fn.getpid(), 10)), 0x3FF)
local seq = 0

--- Allocate a fresh 24-bit kitty image id unique to this Neovim process.
---@return integer
function M.next_id()
    seq = seq + 1
    return bit.bor(bit.lshift(nvim_id, 14), bit.band(seq, 0x3FFF))
end

-- ── low-level command ───────────────────────────────────────────────────────

--- Emit one graphics command. `keys` is the control block (`k=v` pairs); `payload` is the already-base64'd
--- data (or nil). `q=2` is forced unless the caller set it, to suppress terminal responses.
---@param keys table<string, any>
---@param payload? string
local function cmd(keys, payload)
    if keys.q == nil then
        keys.q = 2
    end
    local parts = {}
    for k, v in pairs(keys) do
        parts[#parts + 1] = string.format("%s=%s", k, tostring(v))
    end
    local msg = "\27_G" .. table.concat(parts, ",")
    if payload then
        msg = msg .. ";" .. payload
    end
    msg = msg .. "\27\\"
    terminal.write(msg)
end

-- ── transmit ────────────────────────────────────────────────────────────────

--- Transmit a LOCAL PNG file by PATH — the terminal reads the file itself, so no image bytes cross the tty.
---@param id integer
---@param path string
local function transmit_file(id, path)
    cmd({ a = "t", t = "f", f = 100, i = id, data = b64(path) })
end

--- Transmit raw RGBA pixels (or arbitrary bytes) as chunked base64. `fmt` is 32 (RGBA) or 100 (PNG). For raw
--- pixels the terminal needs the source pixel dimensions (`s`,`v`); pass 0 for PNG (self-describing). `extra`
--- merges into the FIRST chunk's control keys (used to fold a virtual placement into the transmit).
---@param id integer
---@param bytes string
---@param fmt integer
---@param w integer
---@param h integer
---@param extra? table<string, any>
local function transmit_data(id, bytes, fmt, w, h, extra)
    local data = b64(bytes)
    local n = #data
    local i = 1
    local first = true
    while i <= n do
        local chunk = data:sub(i, i + CHUNK - 1)
        i = i + CHUNK
        local more = i <= n and 1 or 0
        if first then
            local keys = { a = "t", t = "d", f = fmt, i = id, m = more }
            if fmt == 32 then
                keys.s, keys.v = w, h
            end
            for k, v in pairs(extra or {}) do
                keys[k] = v
            end
            cmd(keys, chunk)
            first = false
        else
            cmd({ m = more }, chunk)
        end
    end
end

--- Send an image's pixels/file to the terminal. `img` carries `{ id, kind, path|rgba, w, h }` where kind is
--- "png_file" (transmit by path), "png_bytes"/"rgba" (transmit chunked). Idempotent per id at the protocol
--- level — callers gate re-sends via the image's `sent` flag.
---@param img { id: integer, kind: string, path?: string, bytes?: string, rgba?: string, w: integer, h: integer }
function M.transmit(img)
    if img.kind == "png_file" and img.path then
        transmit_file(img.id, img.path)
    elseif img.kind == "png_bytes" and img.bytes then
        transmit_data(img.id, img.bytes, 100, 0, 0)
    elseif img.kind == "rgba" and img.rgba then
        transmit_data(img.id, img.rgba, 32, img.w, img.h)
    end
end

-- ── placement ───────────────────────────────────────────────────────────────

--- Move the terminal cursor to a 1-based screen cell (used by the fallback placement).
---@param row integer
---@param col integer
local function set_cursor(row, col)
    terminal.write(string.format("\27[%d;%dH", row, col))
end

--- CURSOR-POSITIONED placement (fallback for terminals without unicode placeholders, and for standalone
--- float viewers): move the OS cursor to `(row,col)` and draw the image there sized `cols × rows` cells,
--- WITHOUT moving the cursor afterwards (`C=1`).
---@param img { id: integer }
---@param row integer  1-based screen row
---@param col integer  1-based screen column
---@param cols integer
---@param rows integer
---@param placement_id integer
function M.place_at(img, row, col, cols, rows, placement_id)
    set_cursor(row, col)
    cmd({ a = "p", i = img.id, p = placement_id, c = cols, r = rows, C = 1 })
end

--- Transmit the image AND create its VIRTUAL placement in ONE operation — the reliable unicode-placeholder
--- path, matching `kitten icat --unicode-placeholder`. (Transmitting first with `a=t` and placing separately
--- with `a=p` does NOT render the placeholder image; the combined `a=T,U=1` command is required.) A local PNG
--- is a single `a=T,U=1,t=f` command; in-memory pixels/bytes fold `a=T,U=1,c,r` into the first chunk. The
--- image then renders wherever the placeholder cells (built by placement.lua) appear.
---
--- No placement id (`p=`) is sent: it defaults to 0. The placeholder cells carry the placement id in their
--- UNDERLINE colour, but Neovim only emits that colour when the cell is actually underlined — so both the
--- created placement AND the cells settle on 0, and they match. Pinning a non-zero `p` here would create a
--- placement the cells (which still report 0) never reference — the image would not render (real bug seen
--- with inline document images). Both the float viewer and inline rely on this default-0 match.
---@param img { id: integer, kind: string, path?: string, bytes?: string, rgba?: string, w: integer, h: integer }
---@param cols integer
---@param rows integer
function M.show_virtual(img, cols, rows)
    local place = { a = "T", U = 1, i = img.id, c = cols, r = rows }
    if img.kind == "png_file" and img.path then
        place.f, place.t = 100, "f"
        cmd(place, b64(img.path))
    elseif img.kind == "rgba" and img.rgba then
        transmit_data(img.id, img.rgba, 32, img.w, img.h, place)
    elseif img.kind == "png_bytes" and img.bytes then
        transmit_data(img.id, img.bytes, 100, 0, 0, place)
    end
end

--- Re-create a virtual placement for an ALREADY-transmitted image (`a=p,U=1`) — e.g. a second placement of
--- the same image in another window. The first placement should use `show_virtual`.
---@param img { id: integer }
---@param cols integer
---@param rows integer
---@param placement_id integer
function M.place_virtual(img, cols, rows, placement_id)
    cmd({ a = "p", U = 1, i = img.id, p = placement_id, c = cols, r = rows })
end

-- ── delete ──────────────────────────────────────────────────────────────────

--- Delete an image (all its placements) or a single placement of it from the terminal.
---@param id integer
---@param placement_id? integer
function M.delete(id, placement_id)
    if placement_id then
        cmd({ a = "d", d = "i", i = id, p = placement_id })
    else
        cmd({ a = "d", d = "i", i = id })
    end
end

return M
