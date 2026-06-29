-- lua/lvim-utils/dashboard/render.lua
-- The dashboard RENDER ENGINE: turn the declarative `sections` tree (config.dashboard.sections) into a laid-
-- out buffer. The pipeline is resolve → format → layout → paint:
--   • resolve  — flatten the section tree (functions, `{ section = … }` built-ins, nested arrays, titles,
--                gap/padding) into one flat list of ITEMS;
--   • format   — each item becomes a BLOCK of lines: a left ICON, a centre field (header/title/desc/file/
--                free text) and a right KEY/LABEL, aligned to the pane width, with top/bottom padding;
--   • layout   — items are distributed into side-by-side PANES (by `item.pane`), as many as fit the window;
--   • paint    — the panes are merged horizontally, centred in the window, written to the buffer, and the
--                per-chunk highlights applied as extmarks. Each actionable item records its on-screen row/col
--                so the chassis can place keymaps + snap the cursor.
-- No snacks code — an independent implementation of the same model.
--
---@module "lvim-utils.dashboard.render"

local api = vim.api
local M = {}

-- ─── small helpers ────────────────────────────────────────────────────────────

--- Resolve a short hl key ("icon"/"key"/"desc"/…) to its group via `config.dashboard.hl`; a full group name
--- (e.g. "Title") passes through unchanged; nil stays nil.
---@param self table
---@param name string?
---@return string?
local function rhl(self, name)
    if not name then
        return nil
    end
    return (self.opts.hl or {})[name] or name
end

--- Display width of a string.
---@param s string
---@return integer
local function dw(s)
    return vim.fn.strdisplaywidth(s or "")
end

--- Normalise a `text` value into a flat list of CHUNKS `{ [1]=str, hl?, width? }`.
---@param t string|table
---@return table[]
local function norm(t)
    if type(t) == "string" then
        return { { t } }
    end
    if type(t[1]) == "string" then
        return { t } -- a single chunk { str, hl=… }
    end
    return t -- already a list of chunks
end

--- Split chunks into LINES on embedded "\n" (so a multi-line banner becomes multiple lines). Returns a list
--- of lines, each a list of chunks.
---@param text string|table
---@return table[][]
local function to_lines(text)
    local chunks = norm(text)
    local lines = { {} }
    for _, ch in ipairs(chunks) do
        local s = ch[1] or ""
        if s:find("\n", 1, true) then
            local parts = vim.split(s, "\n", { plain = true })
            for i, part in ipairs(parts) do
                if i > 1 then
                    lines[#lines + 1] = {}
                end
                local c = { part }
                for k, v in pairs(ch) do
                    if k ~= 1 then
                        c[k] = v
                    end
                end
                lines[#lines][#lines[#lines] + 1] = c
            end
        else
            lines[#lines][#lines[#lines] + 1] = ch
        end
    end
    return lines
end

--- A chunk list → `{ str, marks = { {start_col, end_col, hl}, … } }` (byte columns within `str`).
---@param chunks table[]
---@return { str: string, marks: table[] }
local function flat(chunks)
    local str, marks = "", {}
    for _, ch in ipairs(chunks) do
        local s = ch[1] or ""
        if ch.hl and s ~= "" then
            marks[#marks + 1] = { #str, #str + #s, ch.hl }
        end
        str = str .. s
    end
    return { str = str, marks = marks }
end

-- ─── field formatting ─────────────────────────────────────────────────────────

-- Fallback glyphs for when nvim-web-devicons is NOT ready yet — the dashboard auto-opens early in startup,
-- before the lazy devicons plugin has run its setup(), so get_icon returns nil then. A directory always uses
-- the folder glyph (devicons is file-oriented). Sourced from config.dashboard.icons (the live config).

--- The icon chunk for a file/directory item: the per-type devicon when available, else a generic file/folder
--- glyph (so a row always has an icon).
---@param self table
---@param file string
---@param kind string  "file" | "directory"
---@return table
local function devicon(self, file, kind)
    local icons = require("lvim-utils.config").dashboard.icons
    if kind == "directory" then
        return { icons.directory .. " ", hl = rhl(self, "icon") }
    end
    local ok, dev = pcall(require, "nvim-web-devicons")
    if ok then
        local tail = vim.fn.fnamemodify(file, ":t")
        local glyph, hl = dev.get_icon(tail, vim.fn.fnamemodify(tail, ":e"), { default = true })
        if glyph then
            return { glyph .. " ", hl = hl }
        end
    end
    return { icons.file .. " ", hl = rhl(self, "icon") }
end

--- A `file` item → a shortened path split into a dimmed DIR chunk + a bright FILE chunk.
---@param self table
---@param item table
---@return table[]
local function format_file(self, item)
    local path = vim.fn.fnamemodify(item.file, ":~")
    local maxw = self.opts.width - (item.indent or 0) - 6
    if dw(path) > maxw then
        path = vim.fn.pathshorten(path)
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    local name = vim.fn.fnamemodify(path, ":t")
    dir = (dir == "." or dir == "") and "" or (dir .. "/")
    return { { dir, hl = rhl(self, "dir") }, { name, hl = rhl(self, "file") } }
end

--- Format `item[field]` into chunks (+ its alignment). Applies `config.dashboard.formats[field]`: a template
--- `{ "%s", align?, width?, hl? }` (substitute the value into `%s`), a `fun(item, ctx)` (returns text), or —
--- absent — the raw value highlighted with the field's group. Special: `file`, and `icon` for a file item.
---@param self table
---@param item table
---@param field string
---@return table[] chunks, string? align
local function format_field(self, item, field)
    if field == "file" then
        return format_file(self, item), nil
    end
    local val = item[field]
    if field == "icon" and item.file and (val == "file" or val == "directory") then
        return { devicon(self, item.file, val) }, nil
    end
    local fmt = (self.opts.formats or {})[field]
    if type(fmt) == "function" then
        return norm(fmt(item, { width = self.opts.width })), nil
    elseif type(fmt) == "table" then
        local str = (fmt[1] or "%s"):gsub("%%s", tostring(val))
        return { { str, hl = rhl(self, fmt.hl or field), width = fmt.width } }, fmt.align
    end
    return { { tostring(val), hl = rhl(self, field) } }, nil
end

-- ─── item → block of rendered lines ───────────────────────────────────────────

--- `item.padding` → `{ bottom, top }` (a number = bottom only).
---@param item table
---@return integer[]
local function padding(item)
    local p = item.padding
    if type(p) == "table" then
        return { p[1] or 0, p[2] or 0 }
    elseif type(p) == "number" then
        return { p, 0 }
    end
    return { 0, 0 }
end

--- Compose one rendered line: `indent + left + (aligned centre) + right`, exactly `width` wide.
---@param self table
---@param indent integer
---@param left table[]
---@param center table[]
---@param right table[]
---@param align string
---@return { str: string, marks: table[] }
local function compose(self, indent, left, center, right, align)
    local width = self.opts.width
    local function w(cs)
        local n = 0
        for _, c in ipairs(cs) do
            n = n + dw(c[1] or "")
        end
        return n
    end
    local lw, cw, rw = w(left), w(center), w(right)
    local avail = math.max(0, width - indent - lw - rw)
    local before, after = 0, 0
    if align == "center" then
        before = math.max(0, math.floor((avail - cw) / 2))
        after = math.max(0, avail - cw - before)
    elseif align == "right" then
        before = math.max(0, avail - cw)
    else
        after = math.max(0, avail - cw)
    end
    local chunks = {}
    if indent > 0 then
        chunks[#chunks + 1] = { string.rep(" ", indent) }
    end
    vim.list_extend(chunks, left)
    if before > 0 then
        chunks[#chunks + 1] = { string.rep(" ", before) }
    end
    vim.list_extend(chunks, center)
    if after > 0 then
        chunks[#chunks + 1] = { string.rep(" ", after) }
    end
    vim.list_extend(chunks, right)
    return flat(chunks)
end

--- Render one item into a list of `{ str, marks }` lines (already padded to the pane width).
---@param self table
---@param item table
---@return { str: string, marks: table[] }[]
function M.render_item(self, item)
    local indent = item.indent or 0
    local pad = padding(item)

    -- LEFT: the icon (+ a trailing gap)
    local left = {}
    if item.icon and item.icon ~= "" then
        left = format_field(self, item, "icon")
        -- a menu row (icon + a command description) gets one extra space between the glyph and the name, so
        -- the label breathes; file/title rows keep the tight single gap.
        if item.desc then
            left[#left + 1] = { " " }
        end
    end

    -- RIGHT: an explicit label, else the key shortcut
    local right = {}
    if item.label then
        right = { { tostring(item.label), hl = rhl(self, "desc") } }
    elseif item.key then
        right = { { item.key, hl = rhl(self, "key") } }
    end

    -- CENTRE: free text, else the first present field
    local lines, align = nil, item.align or "left"
    if item.text ~= nil then
        lines = to_lines(item.text)
        -- resolve short hl keys ("special"/"footer"/…) on free-text chunks (the field path resolves its own)
        for _, ln in ipairs(lines) do
            for _, ch in ipairs(ln) do
                ch.hl = rhl(self, ch.hl)
            end
        end
    else
        for _, f in ipairs({ "header", "footer", "title", "desc", "file" }) do
            if item[f] ~= nil then
                local chunks, falign = format_field(self, item, f)
                lines = to_lines(chunks)
                align = item.align or falign or "left"
                break
            end
        end
    end
    lines = lines or { {} }

    local out = {}
    local blank = { str = string.rep(" ", self.opts.width), marks = {} }
    for _ = 1, pad[2] do
        out[#out + 1] = blank
    end
    for li, cline in ipairs(lines) do
        local L = (li == 1) and left or {}
        local R = (li == 1) and right or {}
        out[#out + 1] = compose(self, indent, L, cline, R, align)
    end
    for _ = 1, pad[1] do
        out[#out + 1] = blank
    end
    return out
end

-- ─── resolve the section tree → flat items ────────────────────────────────────

--- Whether an item is enabled (`enabled` may be a `fun(opts)`; nil/true = on).
---@param self table
---@param item table
---@return boolean
local function enabled(self, item)
    local e = item.enabled
    if type(e) == "function" then
        return e(self.opts) and true or false
    end
    return e == nil or e == true
end

--- Add `(bottom, top)` to an item's padding (accumulates into `{ bottom, top }`).
---@param item table
---@param bottom integer
---@param top integer
local function add_pad(item, bottom, top)
    local p = padding(item)
    item.padding = { p[1] + (bottom or 0), p[2] + (top or 0) }
end

--- After a SECTION's children were appended to `out[first..#out]`: insert its title row, then spread `gap`
--- between children + `padding` above the first / below the last.
---@param section table
---@param out table[]
---@param first integer
local function decorate(section, out, first)
    local last = #out
    if last < first then
        return -- no children produced
    end
    if section.title then
        table.insert(out, first, {
            title = section.title,
            icon = section.icon,
            pane = section.pane,
            -- the title sits at `title_indent` if given (so it can sit to the LEFT of its list, which keeps
            -- its own `indent` — the nested-list look); otherwise it shares the list's indent.
            indent = section.title_indent or section.indent,
            action = section.action,
            key = section.key,
            label = section.label,
        })
        section.action, section.key, section.label = nil, nil, nil
        last = last + 1
    end
    if section.gap then
        for i = first, last - 1 do
            add_pad(out[i], section.gap, 0)
        end
    end
    if section.padding then
        local p = type(section.padding) == "table" and section.padding or { section.padding, section.padding }
        add_pad(out[first], 0, p[2] or p[1])
        add_pad(out[last], p[1], 0)
    end
end

--- Recursively flatten a section into `out` (the flat item list). A section is a function (called with self),
--- a `{ section = "<built-in>" }` reference, a nested array, or a leaf item. Children inherit indent / align /
--- pane from their parent.
---@param self table
---@param section any
---@param out? table[]
---@param parent? table
---@return table[]
function M.resolve(self, section, out, parent)
    out = out or {}
    if section == nil then
        return out
    end
    if type(section) == "function" then
        return M.resolve(self, section(self), out, parent)
    end
    if type(section) ~= "table" then
        return out
    end
    if parent then
        section.indent = section.indent or parent.indent
        section.align = section.align or parent.align
        section.pane = section.pane or parent.pane
    end
    if not enabled(self, section) then
        return out
    end
    if section.section then -- a built-in section generator
        local gen = require("lvim-utils.dashboard.sections")[section.section]
        if gen then
            local first = #out + 1
            M.resolve(self, gen(section), out, section)
            decorate(section, out, first)
        end
        return out
    end
    if section[1] ~= nil then -- a nested array of children
        local first = #out + 1
        for _, child in ipairs(section) do
            M.resolve(self, child, out, section)
        end
        decorate(section, out, first)
        return out
    end
    out[#out + 1] = section -- a leaf item
    return out
end

-- ─── layout + paint ───────────────────────────────────────────────────────────

--- Distribute `self.items` into side-by-side panes (by `item.pane`), capped at how many panes fit the window.
---@param self table
local function layout(self)
    local win_w = api.nvim_win_get_width(self.win)
    local W, gap = self.opts.width, self.opts.pane_gap
    local max_panes = math.max(1, math.floor((win_w + gap) / (W + gap)))
    local by_pane = {}
    for _, item in ipairs(self.items) do
        if not item.hidden then
            local p = ((item.pane or 1) - 1) % max_panes + 1
            by_pane[p] = by_pane[p] or {}
            table.insert(by_pane[p], item)
        end
    end
    self.panes = {}
    for i = 1, max_panes do
        if by_pane[i] then
            self.panes[#self.panes + 1] = by_pane[i]
        end
    end
end

--- Lay out (panes) and PAINT the already-resolved `self.items` into the buffer. Sets `self.panes` /
--- `self.lines` / `self.row` and records each item's on-screen `_row` (0-based) + `_col` (byte) for the
--- chassis. (Run AFTER autokeys are assigned, so each row shows its key.)
---@param self table
function M.paint(self)
    layout(self)

    local W, gap = self.opts.width, self.opts.pane_gap
    local win_w = api.nvim_win_get_width(self.win)
    local win_h = api.nvim_win_get_height(self.win)

    -- render each pane to a list of lines; remember each item's content row + which item anchors each row (so
    -- the merge below can record that item's on-screen byte cell, for the active-row highlight).
    local pane_lines, pane_anchor, max_h = {}, {}, 0
    for _, pane in ipairs(self.panes) do
        local lines, anchor = {}, {}
        for _, item in ipairs(pane) do
            -- anchor on the item's first CONTENT line, skipping its top padding (so the cursor lands on the
            -- text, not the blank padding row above it — e.g. the first key of a `padding`-ed section).
            item._prow = #lines + padding(item)[2]
            anchor[item._prow + 1] = item -- 1-based pane-line index of the content row
            for _, l in ipairs(M.render_item(self, item)) do
                lines[#lines + 1] = l
            end
        end
        pane_lines[#pane_lines + 1] = lines
        pane_anchor[#pane_anchor + 1] = anchor
        max_h = math.max(max_h, #lines)
    end

    local total_w = #self.panes * W + math.max(0, #self.panes - 1) * gap
    local left = self.opts.col or math.max(0, math.floor((win_w - total_w) / 2))
    local top = self.opts.row or math.max(0, math.floor((win_h - max_h) / 2))
    self.row = top

    -- pane → horizontal offset of its content within a merged line
    local pane_off = {}
    for pi = 1, #self.panes do
        pane_off[pi] = left + (pi - 1) * (W + gap)
    end

    -- merge panes horizontally, prepend the vertical centring blanks, collect extmarks
    local out_lines, extmarks = {}, {}
    for _ = 1, top do
        out_lines[#out_lines + 1] = ""
    end
    for row = 1, max_h do
        local str = string.rep(" ", left)
        local marks = {}
        for pi, lines in ipairs(pane_lines) do
            if pi > 1 then
                str = str .. string.rep(" ", gap)
            end
            local l = lines[row] or { str = string.rep(" ", W), marks = {} }
            local off = #str
            for _, m in ipairs(l.marks) do
                marks[#marks + 1] = { off + m[1], off + m[2], m[3] }
            end
            str = str .. l.str
            -- the byte cell [start, end) of the item anchored on this pane row — for the active-row highlight
            local item = pane_anchor[pi][row]
            if item then
                item._hl = { off, #str }
            end
        end
        local buf_row = #out_lines -- 0-based
        out_lines[#out_lines + 1] = str
        for _, m in ipairs(marks) do
            extmarks[#extmarks + 1] = { buf_row, m[1], m[2], m[3] }
        end
    end

    -- record each item's on-screen position (first line) + its pane index, for keymaps + cursor nav. The
    -- cursor column must be a BYTE offset: `_hl[1]` is the byte start of the item's cell on its row (which
    -- accounts for multi-byte content in earlier panes, e.g. the logo), so use it — NOT the display-column
    -- pane offset, which would land the cursor mid-glyph in the previous pane.
    for pi, pane in ipairs(self.panes) do
        for _, item in ipairs(pane) do
            item._row = top + (item._prow or 0) -- 0-based buffer row
            item._pane = pi
            if item._hl then
                item._col = item._hl[1] + (item.indent or 0)
            else
                item._col = pane_off[pi] + (item.indent or 0)
            end
        end
    end

    -- write the buffer + extmarks
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, out_lines)
    vim.bo[self.buf].modifiable = false
    api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
    for _, e in ipairs(extmarks) do
        pcall(api.nvim_buf_set_extmark, self.buf, self.ns, e[1], e[2], { end_col = e[3], hl_group = e[4] })
    end
    self.lines = out_lines
end

return M
