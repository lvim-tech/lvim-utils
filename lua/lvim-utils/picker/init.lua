-- lua/lvim-utils/picker/init.lua
-- A native fuzzy finder built on the lvim-utils.ui.frame chassis: a centred float with a typed query
-- INPUT band on top (a frame header input), a results LIST panel on the left and a scrollable PREVIEW
-- panel on the right — the diagnostics-peek layout, but fuzzy. The MATCHING ENGINE is the native `fzf`
-- binary in --filter mode (no TUI): candidates go in on stdin, fzf returns them matched + ranked by score,
-- and the frame renders the result. So ranking is fzf's exactly while WE own the view (engine vs view,
-- like the blink integration). Without fzf it falls back to a Lua subsequence matcher
-- (lvim-utils.utils.match_indices). Highlight positions are always computed locally (fzf's --filter does
-- not emit them), so the matched characters light up in the list.
--
---@module "lvim-utils.picker"

local api = vim.api
local utils = require("lvim-utils.utils")

local M = {}

---@type string?  cached path to the fzf binary (false-y string when absent)
local fzf_bin
--- The fzf binary path, or nil when fzf is not installed.
---@return string?
local function fzf_path()
    if fzf_bin == nil then
        fzf_bin = vim.fn.exepath("fzf")
    end
    return (fzf_bin ~= "" and fzf_bin) or nil
end

--- Normalise the caller's items into `{ text, icon?, _src }`. A string item is its own text; a table item
--- uses `opts.format(item)` (or `item.text`) for the display text and keeps the original as `_src`.
---@param items any[]
---@param format? fun(item: any): string
---@return table[]
local function normalize(items, format)
    local out = {}
    for i, it in ipairs(items or {}) do
        if type(it) == "string" then
            out[i] = { text = it, _src = it }
        else
            out[i] = { text = (format and format(it)) or it.text or tostring(it), icon = it.icon, _src = it }
        end
    end
    return out
end

--- A grid item for the source `it`, with the matched-char indices for `query` (nil query = none).
---@param it table
---@param query? string
---@return table
local function to_grid(it, query)
    return {
        text = it.text,
        icon = it.icon,
        icon_hl = it.icon_hl,
        _src = it._src,
        match = query and query ~= "" and utils.match_indices(query, it.text) or nil,
    }
end

--- Lua fallback filter (no fzf): subsequence match + a simple score (earlier and tighter matches rank
--- higher). Returns grid items in ranked order.
---@param items table[]
---@param query string
---@return table[]
local function lua_filter(items, query)
    local scored = {}
    for _, it in ipairs(items) do
        local m = utils.match_indices(query, it.text)
        if m then
            scored[#scored + 1] = { it = it, m = m, score = m[1] * 1000 + (m[#m] - m[1]) }
        end
    end
    table.sort(scored, function(a, b)
        return a.score < b.score
    end)
    local out = {}
    for i, s in ipairs(scored) do
        out[i] = { text = s.it.text, icon = s.it.icon, icon_hl = s.it.icon_hl, _src = s.it._src, match = s.m }
    end
    return out
end

--- Filter `items` by `query` and hand the ranked grid items to `cb`. Empty query = all (source order, no
--- highlight). With fzf: pipe `idx\ttext` to `fzf --filter` (matching field 2 only), read back the ranked
--- indices, and rebuild from the source. Without fzf: the Lua fallback. fzf runs async (vim.system).
---@param items table[]
---@param query string
---@param cb fun(list: table[])
local function filter(items, query, cb)
    if query == "" then
        local out = {}
        for i, it in ipairs(items) do
            out[i] = to_grid(it, nil)
        end
        cb(out)
        return
    end
    local bin = fzf_path()
    if not bin or type(vim.system) ~= "function" then
        cb(lua_filter(items, query))
        return
    end
    local lines = {}
    for i, it in ipairs(items) do
        lines[i] = i .. "\t" .. (it.text:gsub("[\t\n]", " "))
    end
    vim.system(
        { bin, "--filter", query, "--delimiter", "\t", "--nth", "2" },
        { stdin = table.concat(lines, "\n"), text = true },
        function(res)
            vim.schedule(function()
                local out = {}
                for line in (res.stdout or ""):gmatch("[^\n]+") do
                    local idx = tonumber(line:match("^(%d+)\t"))
                    if idx and items[idx] then
                        out[#out + 1] = to_grid(items[idx], query)
                    end
                end
                cb(out)
            end)
        end
    )
end

--- Build a list ROW for a grid item: ` icon text`, plus the BYTE spans of its matched label characters.
---@param it table
---@return string row, { c0: integer, c1: integer }[] match_spans
local function list_row(it)
    local icon = (it.icon and it.icon ~= "") and (it.icon .. " ") or ""
    local text = (it.text or ""):gsub("[\r\n]+", " ")
    local row = " " .. icon .. text
    local spans = {}
    if it.match and #it.match > 0 then
        local base = 1 + #icon -- byte offset of the label within `row`
        local nch = vim.fn.strchars(text)
        for _, ci in ipairs(it.match) do
            if ci >= 0 and ci < nch then
                spans[#spans + 1] =
                    { c0 = base + vim.str_byteindex(text, ci), c1 = base + vim.str_byteindex(text, ci + 1) }
            end
        end
    end
    return row, spans
end

---@class LvimPickerOpts
---@field items any[]  candidates (strings, or tables — see `format`)
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?  preview lines (+ a filetype for syntax) per selection
---@field title? string  the float title
---@field prompt? string  the query prompt prefix (default "➤ ")
---@field max_rows? integer  natural list/preview height hint (default 15)
---@field layout? "float"|"bottom"  centred float (default) or an Emacs-style bottom dock
---@field height? integer  rows for the bottom layout (default 16)

--- Open a fuzzy finder: a centred float with a query input on top, a results list and (with `preview`) a
--- scrollable preview beside it. Type to filter (fzf), `<C-j>/<C-k>` move, `<C-d>/<C-u>` scroll the
--- preview, `<CR>` confirms, `<Esc>` cancels.
---@param opts LvimPickerOpts
function M.open(opts)
    opts = opts or {}
    local frame = require("lvim-utils.ui.frame")
    local items = normalize(opts.items, opts.format)
    local maxr = opts.max_rows or 15
    local state = { filtered = items, sel = 1, list_pan = nil, preview_pan = nil, st = nil, closed = false }

    -- list panel: the filtered rows in the tint canon (odd BLUE / even YELLOW full-row stripes, the
    -- selected row a STRONG tint of its accent), matched chars in red. Selection is the Sel stripe (not a
    -- window cursorline), so it survives the row tints; navigation re-renders to move it.
    local list_provider = {
        cursorline = false,
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.32)), maxr
        end,
        render = function()
            local lines, hls = {}, {}
            for i, it in ipairs(state.filtered) do
                local row, spans = list_row(it)
                lines[i] = row
                local odd = (i % 2) == 1
                local sel = i == state.sel
                local stripe = sel and (odd and "LvimUiMsgAreaSelOdd" or "LvimUiMsgAreaSelEven")
                    or (odd and "LvimUiMsgAreaRowOdd" or "LvimUiMsgAreaRowEven")
                hls[#hls + 1] = { i - 1, 0, -1, stripe, sel and 200 or 100 } -- full-row tint (eol)
                for _, ms in ipairs(spans) do
                    hls[#hls + 1] = { i - 1, ms.c0, ms.c1, "LvimUiMsgAreaMatch", 250 }
                end
            end
            if #lines == 0 then
                lines = { "  (no matches)" }
            end
            return lines, hls
        end,
        keys = function(_, pan, st)
            state.list_pan, state.st = pan, st
        end,
    }

    -- preview panel (optional): the selected item's content, scrollable + syntax-highlighted. An `update`
    -- provider OWNS its buffer, so it writes the lines AND sets the filetype — which fires FileType, so
    -- treesitter / syntax colour the preview. `opts.preview(src)` returns `lines, filetype?`.
    local preview_provider = opts.preview
            and {
                size = function()
                    return math.max(40, math.floor(vim.o.columns * 0.5)), maxr
                end,
                update = function(pan)
                    local it = state.filtered[state.sel]
                    local lines, ft = nil, nil
                    if it then
                        lines, ft = opts.preview(it._src)
                    end
                    lines = (type(lines) == "table" and lines) or (lines and { tostring(lines) }) or {}
                    vim.bo[pan.buf].modifiable = true
                    pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, lines)
                    vim.bo[pan.buf].modifiable = false
                    if ft and ft ~= "" and vim.bo[pan.buf].filetype ~= ft then
                        pcall(api.nvim_set_option_value, "filetype", ft, { buf = pan.buf })
                    end
                end,
                keys = function(_, pan)
                    state.preview_pan = pan
                end,
            }
        or nil

    local function set_list_cursor()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            pcall(api.nvim_win_set_cursor, p.win, { math.max(1, math.min(#state.filtered, state.sel)), 0 })
        end
    end
    local function update_preview()
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
    end
    local function move(d)
        if #state.filtered == 0 then
            return
        end
        state.sel = math.max(1, math.min(#state.filtered, state.sel + d))
        if state.list_pan and state.list_pan.refresh then
            state.list_pan.refresh() -- re-render so the Sel stripe moves to the new row
        end
        set_list_cursor() -- scroll the window to keep the selection in view
        update_preview()
    end
    local function refilter(q)
        filter(items, q, function(list)
            if state.closed then
                return
            end
            state.filtered, state.sel = list, 1
            if state.list_pan and state.list_pan.refresh then
                state.list_pan.refresh()
            end
            set_list_cursor()
            update_preview()
        end)
    end
    local function scroll_preview(dir)
        local p = state.preview_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            api.nvim_win_call(p.win, function()
                vim.cmd("normal! " .. api.nvim_replace_termcodes(dir > 0 and "<C-d>" or "<C-u>", true, false, true))
            end)
        end
    end
    local function confirm()
        local it = state.filtered[state.sel]
        if state.st then
            state.st.close()
        end
        if it and opts.on_confirm then
            opts.on_confirm(it._src)
        end
    end

    local blocks = { { id = "list", provider = list_provider, size = { width = { fixed = 0.4 } } } }
    if preview_provider then
        blocks[#blocks + 1] = { id = "preview", provider = preview_provider }
    end

    -- layout: a centred float (default), or an Emacs-style dock at the bottom of the screen (full width).
    local bottom = opts.layout == "bottom"
    frame.open({
        mode = "float",
        position = bottom and "bottom" or nil,
        title = opts.title or "Pick",
        border = bottom and "none" or "rounded",
        separator = "│",
        size = bottom and { height = { fixed = opts.height or 16 } }
            or { width = { fixed = 0.85 }, height = { fixed = 0.7 } },
        header = {
            bars = {
                {
                    input = true,
                    prompt = opts.prompt or "➤ ",
                    filetype = "lvim-picker-prompt",
                    on_change = refilter,
                    keys = function(buf, st)
                        state.st = st
                        local function imap(lhs, fn)
                            vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
                        end
                        imap("<C-j>", function()
                            move(1)
                        end)
                        imap("<Down>", function()
                            move(1)
                        end)
                        imap("<C-k>", function()
                            move(-1)
                        end)
                        imap("<Up>", function()
                            move(-1)
                        end)
                        imap("<C-d>", function()
                            scroll_preview(1)
                        end)
                        imap("<C-u>", function()
                            scroll_preview(-1)
                        end)
                        imap("<CR>", function()
                            vim.cmd("stopinsert")
                            confirm()
                        end)
                        local function cancel()
                            vim.cmd("stopinsert")
                            st.close()
                            if opts.on_cancel then
                                opts.on_cancel()
                            end
                        end
                        imap("<Esc>", cancel)
                        imap("<C-c>", cancel)
                    end,
                },
            },
        },
        content = { blocks = blocks },
        footer = {
            bars = {
                {
                    items = {
                        { key = "<CR>", name = "open" },
                        { key = "C-j/k", name = "move" },
                        { key = "C-d/u", name = "preview" },
                        { key = "Esc", name = "close" },
                    },
                },
            },
        },
        close_keys = {}, -- the input owns <Esc>/<C-c>; the panels are not normally focused
        on_close = function()
            state.closed = true
        end,
    })

    -- initial: show all, select the first, preview it
    set_list_cursor()
    update_preview()
end

--- A ready finder over the listed buffers; confirming switches to the chosen buffer, with a content preview.
---@param opts? table  forwarded to M.open
function M.buffers(opts)
    local items = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
        if vim.bo[b].buflisted then
            local name = api.nvim_buf_get_name(b)
            name = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
            items[#items + 1] = { text = name, bufnr = b }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Buffers",
        items = items,
        on_confirm = function(it)
            if it and api.nvim_buf_is_valid(it.bufnr) then
                api.nvim_set_current_buf(it.bufnr)
            end
        end,
        preview = function(it)
            local b = it.bufnr
            local name = b and api.nvim_buf_get_name(b) or ""
            -- the filetype drives the preview's syntax: a loaded buffer's own ft, else match by filename
            local ft = (b and api.nvim_buf_is_loaded(b) and vim.bo[b].filetype) or ""
            if ft == "" and name ~= "" then
                ft = vim.filetype.match({ filename = name }) or ""
            end
            if b and api.nvim_buf_is_loaded(b) then
                return api.nvim_buf_get_lines(b, 0, 500, false), ft
            end
            if name ~= "" and vim.fn.filereadable(name) == 1 then
                return vim.fn.readfile(name, "", 500), ft
            end
            return { "[no preview]" }, ""
        end,
    }, opts or {}))
end

return M
