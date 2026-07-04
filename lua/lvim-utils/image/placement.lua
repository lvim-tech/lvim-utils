-- lvim-utils.image.placement: binds a prepared Image to a window/buffer and renders it. The robust path is
-- the kitty UNICODE-PLACEHOLDER grid: after a virtual placement (`U=1`) the image is drawn wherever a grid of
-- the placeholder char `U+10EEEE` appears, each cell tagged with row/column COMBINING DIACRITICS and the image
-- id carried in the cell's FOREGROUND colour. Because the grid is ordinary buffer cells, the terminal repaints
-- the image whenever Neovim repaints those cells — scroll/resize tracking is free. Terminals without
-- placeholder support (wezterm) fall back to a CURSOR-POSITIONED placement re-issued on redraw.
--
-- Two placement targets share the grid: the standalone float VIEWER (a scratch buffer we own, whose lines
-- become the grid — `M.new`) and INLINE document images (extmark `virt_lines` over the user's own buffer,
-- never touching its text — `M.inline`).
--
---@module "lvim-utils.image.placement"

local api = vim.api
local terminal = require("lvim-utils.image.terminal")
local kitty = require("lvim-utils.image.protocols.kitty")

local M = {}

-- Kitty row/column diacritics (gen/rowcolumn-diacritics.txt). Index i (1-based) encodes position i-1.
---@type integer[]
-- stylua: ignore
local DIA = {
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C, 0x0350,
    0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B,
    0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595,
    0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9, 0x05AB, 0x05AC,
    0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658, 0x0659,
    0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0,
    0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A,
    0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
    0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F,
    0x0820, 0x0821, 0x0822, 0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951,
    0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75,
    0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
    0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5,
    0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7,
    0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4,
    0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
    0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7,
    0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4,
    0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA, 0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C,
    0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9,
    0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8,
    0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185,
    0x1D186, 0x1D187, 0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local ns = api.nvim_create_namespace("lvim-utils.image")

--- The 3-codepoint placeholder cell for image position (row, col), 0-based: placeholder + row diacritic +
--- column diacritic. Positions beyond the diacritic table clamp to the last entry (images wider/taller than
--- 287 cells are not a real concern).
---@param row integer
---@param col integer
---@return string
local function cell(row, col)
    local rd = DIA[math.min(row + 1, #DIA)]
    local cd = DIA[math.min(col + 1, #DIA)]
    return PLACEHOLDER .. vim.fn.nr2char(rd) .. vim.fn.nr2char(cd)
end

---@class lvim-utils.image.Placement
---@field img lvim-utils.image.Image
---@field buf integer
---@field win integer
---@field cols integer
---@field rows integer
---@field pid integer            kitty placement id
---@field center boolean         pad the grid to centre the image in its window (file viewer) vs top-left (float)
---@field mode "placeholder"|"fallback"
local Placement = {}
Placement.__index = Placement

local pid_seq = 0

--- Render an image into a buffer/window as a placeholder grid (or a cursor-positioned fallback). `opts`:
---   buf     the scratch buffer to fill with placeholder cells (viewer-owned)
---   win     the window showing `buf` (for sizing + fallback screen position)
---   max_w   max width in cells  (defaults to the window width)
---   max_h   max height in cells (defaults to the window height)
---@param img lvim-utils.image.Image
---@param opts { buf: integer, win: integer, max_w?: integer, max_h?: integer, center?: boolean }
---@return lvim-utils.image.Placement|nil
function M.new(img, opts)
    if not (img.w and img.h and img.w > 0 and img.h > 0) then
        return nil
    end
    local caps = terminal.capabilities()
    local win_w = opts.max_w or api.nvim_win_get_width(opts.win)
    local win_h = opts.max_h or api.nvim_win_get_height(opts.win)
    local cols, rows = img:cells(win_w, win_h)

    pid_seq = pid_seq + 1
    local self = setmetatable({
        img = img,
        buf = opts.buf,
        win = opts.win,
        cols = cols,
        rows = rows,
        pid = pid_seq,
        center = opts.center or false,
        mode = caps.placeholders and "placeholder" or "fallback",
    }, Placement)

    if self.mode == "placeholder" then
        self:render_placeholder()
    else
        img:transmit()
        self:render_fallback()
    end
    return self
end

--- Placeholder path: transmit the image AND create its virtual placement in one command (`show_virtual` —
--- the two-step transmit+place does NOT render), then fill the buffer with the placeholder grid and colour
--- every cell with `fg = image id` so the terminal knows which image these cells belong to.
function Placement:render_placeholder()
    kitty.show_virtual(self.img, self.cols, self.rows)
    self.img.sent = true

    -- When centring (the full-window image-file viewer), pad the grid with blank rows above and a run of
    -- spaces before each row so the image sits in the middle of the window; the float viewer is already sized
    -- to the image so it pads nothing.
    local pad_top, pad_left = 0, 0
    if self.center and api.nvim_win_is_valid(self.win) then
        pad_top = math.max(0, math.floor((api.nvim_win_get_height(self.win) - self.rows) / 2))
        pad_left = math.max(0, math.floor((api.nvim_win_get_width(self.win) - self.cols) / 2))
    end
    local indent = string.rep(" ", pad_left)

    local lines = {}
    for _ = 1, pad_top do
        lines[#lines + 1] = ""
    end
    for r = 0, self.rows - 1 do
        local parts = {}
        for c = 0, self.cols - 1 do
            parts[#parts + 1] = cell(r, c)
        end
        lines[#lines + 1] = indent .. table.concat(parts)
    end
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false

    -- The image id lives in the foreground RGB; the placement id in the underline colour. `nocombine` keeps
    -- the diacritics from inheriting other highlights. The highlight starts AFTER the centring indent.
    local hl = "LvimImage_" .. self.img.id
    api.nvim_set_hl(0, hl, { fg = self.img.id, sp = self.pid, nocombine = true })
    for r = 0, self.rows - 1 do
        local row = pad_top + r
        api.nvim_buf_set_extmark(self.buf, ns, row, pad_left, {
            end_col = #lines[row + 1],
            hl_group = hl,
            priority = 200,
        })
    end
end

--- Fallback path (no placeholders): move the OS cursor to the window's top-left screen cell and draw the
--- image there. Re-issued on redraw/resize by the viewer's autocmds.
function Placement:render_fallback()
    if not api.nvim_win_is_valid(self.win) then
        return
    end
    local pos = api.nvim_win_get_position(self.win) -- {row, col}, 0-based, editor-relative
    kitty.place_at(self.img, pos[1] + 1, pos[2] + 1, self.cols, self.rows, self.pid)
end

--- Re-issue the fallback placement (no-op in placeholder mode, which tracks itself).
function Placement:refresh()
    if self.mode == "fallback" then
        self:render_fallback()
    end
end

-- ── inline document placement (virtual lines over someone else's buffer) ──────
-- Unlike the viewer path above (which OWNS a scratch buffer and fills its lines), inline images live inside
-- the user's markdown/latex/html buffer. We must not touch its text — so the placeholder grid is anchored as
-- an extmark's `virt_lines` BELOW the image's source line. The grid tracks edits (extmarks move) and the
-- terminal repaints the image wherever those virtual cells render, so scrolling needs no re-issue.

---@class lvim-utils.image.InlinePlacement
---@field img lvim-utils.image.Image
---@field buf integer
---@field ns integer
---@field extmark integer
---@field pid integer
---@field cols integer
---@field rows integer
local Inline = {}
Inline.__index = Inline

--- Place `img` inline as virtual lines under source line `row` (0-based) of `buf`, in namespace `ns`. The
--- image is transmitted + given its virtual placement only once (gated on `img.sent`); on a reconcile the
--- SAME `pid` re-anchors the still-alive placement, so no re-transmit. `max_w`/`max_h` bound the cell box;
--- `pid` must be STABLE per image across reconciles (the inline manager keeps it). Returns nil if the image
--- has no pixel size yet.
---@param img lvim-utils.image.Image
---@param opts { buf: integer, ns: integer, row: integer, pid: integer, max_w: integer, max_h: integer }
---@return lvim-utils.image.InlinePlacement|nil
function M.inline(img, opts)
    if not (img.w and img.h and img.w > 0 and img.h > 0) then
        return nil
    end
    local cols, rows = img:cells(opts.max_w, opts.max_h)
    if not img.sent then
        kitty.show_virtual(img, cols, rows)
        img.sent = true
    end

    -- Image id in the foreground RGB (matches the float viewer). The `sp` carries the placement id, but with
    -- no underline it is not emitted — so the cells reference placement 0, exactly the placement show_virtual
    -- created. `nocombine` keeps the diacritics from inheriting other highlights.
    local hl = "LvimImage_" .. img.id
    api.nvim_set_hl(0, hl, { fg = img.id, sp = opts.pid, nocombine = true })
    local vlines = {}
    for r = 0, rows - 1 do
        local parts = {}
        for c = 0, cols - 1 do
            parts[#parts + 1] = cell(r, c)
        end
        vlines[#vlines + 1] = { { table.concat(parts), hl } }
    end
    local extmark = api.nvim_buf_set_extmark(opts.buf, opts.ns, opts.row, 0, {
        virt_lines = vlines,
        virt_lines_above = false,
    })
    return setmetatable(
        { img = img, buf = opts.buf, ns = opts.ns, extmark = extmark, pid = opts.pid, cols = cols, rows = rows },
        Inline
    )
end

--- Remove just this placement's virtual lines (the extmark). Does NOT delete the kitty image — the inline
--- manager owns image lifetime and re-places the same (still-transmitted) image on the next reconcile.
function Inline:clear()
    if api.nvim_buf_is_valid(self.buf) then
        pcall(api.nvim_buf_del_extmark, self.buf, self.ns, self.extmark)
    end
end

--- Tear down: delete the terminal placement, clear extmarks, and free the image.
function Placement:close()
    pcall(api.nvim_buf_clear_namespace, self.buf, ns, 0, -1)
    self.img:delete()
end

return M
