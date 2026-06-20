-- lua/lvim-utils/picker/init.lua
-- A native fuzzy finder built on the lvim-utils.ui.surface chassis: a centred float with a typed query
-- INPUT band on top (a surface header input), a results LIST panel on the left and a scrollable PREVIEW
-- panel on the right — the diagnostics-peek layout, but fuzzy. The MATCHING ENGINE is the native `fzf`
-- binary in --filter mode (no TUI): candidates go in on stdin, fzf returns them matched + ranked by score,
-- and the surface renders the result. So ranking is fzf's exactly while WE own the view (engine vs view,
-- like the blink integration). Without fzf it falls back to a Lua subsequence matcher
-- (lvim-utils.utils.match_indices). Highlight positions are always computed locally (fzf's --filter does
-- not emit them), so the matched characters light up in the list.
--
---@module "lvim-utils.picker"

local api = vim.api
local fuzzy = require("lvim-utils.fuzzy")
local status = require("lvim-utils.status")

local M = {}

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

--- Filter `items` (normalised `{ text, icon?, _src }`) by `query` via the shared fuzzy engine and hand the
--- ranked GRID items (`{ text, icon, icon_hl, _src, match }`) to `cb`. Empty query = all, source order.
---@param items table[]
---@param query string
---@param cb fun(list: table[])
local function filter(items, query, cb)
    local texts = {}
    for i, it in ipairs(items) do
        texts[i] = it.text
    end
    fuzzy.filter(texts, query, function(ranked)
        local out = {}
        for i, r in ipairs(ranked) do
            local it = items[r.idx]
            out[i] = { text = it.text, icon = it.icon, icon_hl = it.icon_hl, _src = it._src, match = r.match }
        end
        cb(out)
    end)
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
---@field preview_side? "right"|"left"|"below"|"above"  where the preview sits (default "right"); below/above stack + grow height
---@field title? string  the float title / the statusline action title
---@field icon? string  an optional leading glyph for the title (statusline)
---@field statusline? boolean  (docked layouts) publish title/counter/query to the bottom statusline (default true); false = draw them in the navigator
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
    local surface = require("lvim-utils.ui.surface")
    local items = normalize(opts.items, opts.format)
    local maxr = opts.max_rows or 15
    local state = { filtered = items, sel = 1, list_pan = nil, preview_pan = nil, st = nil, closed = false, query = "" }

    -- statusline integration (default ON): publish the title + match counter + query to the bottom
    -- statusline (lvim-utils.status) so it shows the current action, instead of the navigator drawing its
    -- own border title. `statusline = false` keeps the title/counter IN the navigator. Only the DOCKED
    -- navigator (the area/minibuffer model) uses it; a centred float always shows its own title.
    local docked_layout = opts.layout == "bottom" or opts.layout == "area"
    -- the global echo master switch (config.status.enabled) AND this picker opting in
    local use_status = docked_layout and status.is_enabled() and opts.statusline ~= false
    local function publish_status()
        if use_status then
            status.set({
                title = opts.title,
                icon = opts.icon,
                current = #state.filtered > 0 and state.sel or 0,
                total = #state.filtered,
                action = state.query,
            })
        end
    end

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
        publish_status() -- the counter follows the selection
    end
    local function refilter(q)
        state.query = q or ""
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
            publish_status() -- new total + reset counter + query as the action
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
        if use_status then
            status.clear()
        end
        if state.st then
            state.st.close()
        end
        if it and opts.on_confirm then
            opts.on_confirm(it._src)
        end
    end

    -- layout: a centred float (default), a "bottom" dock that FLOATS over the bottom rows (statusline
    -- unaffected), or "area" — the Emacs-minibuffer model: it GROWS `cmdheight` like the msgarea cmdline
    -- zone, so a global statusline (heirline) rises ABOVE it. Both bottom/area dock full-width borderless.
    local bottom = opts.layout == "bottom"
    local area = opts.layout == "area"
    local docked = bottom or area
    -- preview side: where the preview panel sits relative to the list. right/left → side-by-side; below/
    -- above → stacked (the surface grows its height — see ui.surface `direction = "vertical"`).
    local side = opts.preview_side or "right"
    local vertical = side == "below" or side == "above"
    -- Docked: borderless panels (the separator divides them) so they fill the zone edge-to-edge, like the
    -- cmdline zone. A float keeps the default per-panel border.
    local pbord = docked and "none" or nil
    -- The surface's own border-title is shown ONLY when we're NOT publishing the title to the statusline
    -- (else it would duplicate). `surf_title` = nil suppresses it.
    local surf_title = (not use_status) and opts.title or nil
    local titled = surf_title ~= nil and surf_title ~= ""
    local list_block = {
        id = "list",
        provider = list_provider,
        border = pbord,
        size = vertical and { height = { fixed = 0.45 } } or { width = { fixed = 0.4 } },
    }
    local preview_block = preview_provider and { id = "preview", provider = preview_provider, border = pbord }
    local blocks
    if not preview_block then
        blocks = { list_block }
    elseif side == "left" or side == "above" then
        blocks = { preview_block, list_block }
    else
        blocks = { list_block, preview_block }
    end
    -- Size by layout × preview side. Docked: a list-only height, or a TALLER one when the preview is stacked
    -- below/above (it grows up). Float: a wide two-pane, or a taller stacked one.
    local size
    if docked then
        size = vertical and { height = { fixed = 0.5 } } or { height = { fixed = opts.height or 16 } }
    elseif vertical then
        size = { width = { fixed = 0.7 }, height = { fixed = 0.8 } }
    else
        size = { width = { fixed = 0.85 }, height = { fixed = 0.7 } }
    end
    surface.open({
        mode = "float",
        -- "area" sits IN the cmdline region (grows cmdheight, heirline above) like the msgarea zone; the
        -- zindex keeps it in the cmdline layer so it isn't re-anchored below the statusline. "bottom" just
        -- floats over the bottom rows.
        position = area and "cmdline" or (bottom and "bottom") or nil,
        zindex = area and 200 or nil,
        header_air = (docked and not titled) and false or nil,
        direction = vertical and "vertical" or nil,
        title = surf_title,
        -- Docked: a native top-border TITLE when there IS a title (the canon — a top " " border, no ring +
        -- 1 air row under it), else NO border. A float keeps the rounded ring.
        border = docked and (titled and { "", " ", "", "", "", "", "", "" } or "none") or "rounded",
        separator = vertical and "─" or "│",
        size = size,
        header = {
            bars = {
                {
                    input = true,
                    prompt = opts.prompt or "➤ ",
                    filetype = "lvim-picker-prompt",
                    on_change = refilter,
                    keys = function(buf, st)
                        state.st = st
                        publish_status() -- show the title + initial counter the moment the navigator opens
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
                            if use_status then
                                status.clear()
                            end
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
