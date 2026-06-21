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
local utils = require("lvim-utils.utils")
local status = require("lvim-utils.status")

local NS = api.nvim_create_namespace("lvim-utils-picker")

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
            out[i] = {
                text = (format and format(it)) or it.text or tostring(it),
                icon = it.icon,
                icon_hl = it.icon_hl,
                _src = it,
            }
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
---@field items? any[]  STATIC candidates (strings, or tables — see `format`), fuzzy-filtered as you type
---@field source? fun(query: string, cb: fun(items: any[]))  a LIVE source: each query produces the results (e.g. ripgrep); use instead of `items`
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?, integer?  preview lines (+ a filetype, + a 1-based focus line) per selection
---@field preview_file? boolean  preview the item's REAL file buffer (EDITABLE, 2-way synced) instead of `preview` lines; items need `path` (+ lnum/col)
---@field preview_side? "right"|"left"|"below"|"above"  where the preview sits (default "right"); below/above stack + grow height
---@field preview_numbers? boolean  show line numbers in the preview (default true)
---@field preview_wrap? boolean  soft-wrap the preview (default false)
---@field list_wrap? boolean  soft-wrap the list rows (no "↳" marker) so far-right matches stay visible (default false)
---@field empty_text? string  shown when there are no results (list body + preview winbar)
---@field title? string  the float title / the statusline action title
---@field icon? string  an optional leading glyph for the title (statusline)
---@field subtitle? fun(item: any): string  per-selection subtitle shown after the title in the statusline (e.g. the file name)
---@field statusline? boolean  (docked layouts) publish title/counter/query to the bottom statusline (default true); false = draw them in the navigator
---@field prompt? string  the query prompt prefix (default "➤ ")
---@field keys? { key: string, name?: string, run: fun(item: any, close: fun()) }[]  extra row actions (split, code action…); `name` adds a footer hint
---@field filters? table[]  header filter button GROUPS — each `{ active = id, buttons = { { id, label, key?, predicate?(src), hl?, hl_active? }, … } }`; activate a filter by its key in NORMAL mode
---@field refresh? fun(): any[]  re-fetch the static items live (e.g. on DiagnosticChanged) — see refresh_events
---@field refresh_events? string[]  autocmd events that trigger a refresh
---@field close_on_empty? boolean  dismiss the finder when a refresh leaves no items (e.g. all diagnostics fixed)
---@field max_rows? integer  natural list/preview height hint (default 15)
---@field layout? "float"|"bottom"|"area"  centred float (default), a bottom dock, or the cmdheight area (heirline above)
---@field height? integer  rows for the bottom layout (default 16)

--- Open a fuzzy finder: a centred float with a query input on top, a results list and (with `preview`) a
--- scrollable preview beside it. INSERT prompt: type to filter (fzf), `<C-j>/<C-k>` move, `<C-d>/<C-u>`
--- scroll the preview, `<CR>` confirms, `<C-c>` cancels, `<Esc>`/`<C-f>` → NORMAL. NORMAL list: `j`/`k`
--- move, `<C-d>/<C-u>` scroll preview, `<C-l>`/`<C-h>` panel nav, filter hotkeys, `q` close, `/` → typing.
---@param opts LvimPickerOpts
function M.open(opts)
    opts = opts or {}
    local surface = require("lvim-utils.ui.surface")
    local items = normalize(opts.items, opts.format)
    local maxr = opts.max_rows or 15
    local state = { filtered = items, sel = 1, list_pan = nil, preview_pan = nil, st = nil, closed = false, query = "" }
    ---@type table?  the msgarea module when this finder HOSTS in its zone (area + zone enabled); else nil. Set
    --- below at open; the NORMAL-mode list `<C-j>` uses it to descend into the messages composed below us.
    local msgarea = nil

    -- Every highlight group is configurable + shared via `config.picker.hl` (fall back to the built-in
    -- tint-canon / peek groups).
    local pkcfg = require("lvim-utils.config").picker or {}
    local phl = pkcfg.hl or {}
    local function hl(key, default)
        return phl[key] or default
    end
    local empty_text = opts.empty_text or pkcfg.empty_text or "[no matches]"
    local prevcfg = pkcfg.preview or {}
    -- list wrap: per-call `opts.list_wrap` wins; else the shared `config.picker.list_wrap`.
    local list_wrap = opts.list_wrap
    if list_wrap == nil then
        list_wrap = pkcfg.list_wrap == true
    end

    -- FILTER bars (optional): `opts.filters` is a list of GROUPS, each `{ buttons = { { id, label, key?,
    -- predicate?(src), hl?, hl_active? }, … }, active }`. An item is kept only if it passes EVERY group's
    -- active button predicate; the surviving pool is then fuzzy-filtered by the query. Header buttons toggle
    -- the active button live (see build_filter_bar / set_filter). `set_filter` is assigned after `refilter`.
    local filters = opts.filters
    local set_filter ---@type fun(gi: integer, id: string)
    local function active_button(g)
        for _, b in ipairs(g.buttons) do
            if b.id == g.active then
                return b
            end
        end
        return g.buttons[1]
    end
    --- True when `src` passes every group's active predicate (optionally skipping `except`).
    ---@param src any
    ---@param except? table
    ---@return boolean
    local function passes_filters(src, except)
        for _, g in ipairs(filters or {}) do
            if g ~= except then
                local b = active_button(g)
                if b and b.predicate and not b.predicate(src) then
                    return false
                end
            end
        end
        return true
    end

    -- Forward declarations — the list panel's NORMAL-mode keys (defined with the panel, early) call these,
    -- but they are assigned further down (after the providers/state are wired).
    local move, confirm, cancel, focus_input, act, scroll_preview

    -- Kill the "↳" continuation marker on wrapped rows WITHOUT touching the user's global `showbreak`: the
    -- special window-local value "NONE" disables showbreak for THIS window only (an empty "" would just
    -- revert to the global) — no marker, no global mutation. (No `breakindent`: its virtual indent draws no
    -- text and so cannot carry the row tint — it would leave an un-tinted notch; instead continuations sit
    -- at column 0 as REAL wrapped text, fully covered by the row's `hl_eol` stripe.)
    local function tame_win(win, wrap)
        if win and api.nvim_win_is_valid(win) then
            vim.wo[win].wrap = wrap or false
            vim.wo[win].list = false
            vim.wo[win].showbreak = "NONE"
        end
    end

    -- statusline integration (default ON): publish the title + match counter + query to the bottom
    -- statusline (lvim-utils.status) so it shows the current action, instead of the navigator drawing its
    -- own border title. `statusline = false` keeps the title/counter IN the navigator. Only the DOCKED
    -- navigator (the area/minibuffer model) uses it; a centred float always shows its own title.
    local docked_layout = opts.layout == "bottom" or opts.layout == "area"
    -- the global echo master switch (config.status.enabled) AND this picker opting in
    local use_status = docked_layout and status.is_enabled() and opts.statusline ~= false
    local function publish_status()
        if use_status then
            -- a per-selection subtitle (e.g. the focused file name) shown after the title in the statusline
            local sub
            if opts.subtitle then
                local it = state.filtered[state.sel]
                sub = (it and opts.subtitle(it._src)) or ""
            end
            status.set({
                title = opts.title,
                icon = opts.icon,
                current = #state.filtered > 0 and state.sel or 0,
                total = #state.filtered,
                action = state.query,
                subtitle = sub,
            })
        end
    end

    -- list panel: the filtered rows in the tint canon (odd BLUE / even YELLOW full-row stripes, the
    -- selected row a STRONG tint of its accent), matched chars in red. Selection is the Sel stripe (not a
    -- window cursorline), so it survives the row tints; navigation re-renders to move it.
    -- Dynamic height: the container fits the TALLER of the two panels, capped at `max_rows`. The list
    -- contributes its result count; the preview contributes its content's line count (cached on selection).
    -- 0 results ⇒ both are 0 ⇒ only the prompt + the preview winbar show. relayout() re-fits on every change.
    state.preview_lines = {}
    local function list_h()
        return math.min(#state.filtered, maxr) -- 0 when empty (no [no matches] body row)
    end
    local function preview_h()
        -- the editable real-file preview wants the FULL height (room to edit), not the file's line count
        if opts.preview_file then
            return maxr
        end
        return math.min(#state.preview_lines, maxr)
    end
    local function has_results()
        return #state.filtered > 0
    end
    -- The CONTENT height shared by both panels. WITH results each panel is `content_h + 1` (the winbar row).
    -- With NO results there is no winbar — each panel is a SINGLE row (the prompt on the left, the
    -- `[no matches]` label on the right) — so the finder collapses to one tinted line.
    local function content_h()
        return math.max(1, list_h(), preview_h())
    end
    local function panel_height()
        return has_results() and (content_h() + 1) or 1
    end

    -- Each panel carries a WINBAR title, the lvim-lsp peek look: the list shows the title + result count,
    -- the preview shows the selected file (tail + dir). `%%` escapes a literal `%` in a name.
    local function esc(s)
        return (tostring(s or ""):gsub("%%", "%%%%"))
    end
    local function set_list_winbar()
        local p = state.list_pan
        if not (p and p.win and api.nvim_win_is_valid(p.win)) then
            return
        end
        -- No results ⇒ NO winbar (the panel is a single row — see panel_height); the prompt overlay owns it.
        if not has_results() then
            vim.wo[p.win].winbar = ""
            return
        end
        -- With a preview the scoped INPUT prompt overlays this row, so keep it blank (just reserve the row,
        -- so the first list item isn't hidden under the prompt); the title/count live in the statusline.
        -- Without a preview the list owns its title bar.
        if opts.preview then
            vim.wo[p.win].winbar = ("%%#%s# %%="):format(hl("bar", "LvimUiPeekFileBar"))
        else
            vim.wo[p.win].winbar = ("%%#%s# %s %%#%s# %d %%#%s#%%="):format(
                hl("list_title", "LvimUiPeekTitle"),
                esc(opts.title or "Pick"),
                hl("list_count", "LvimUiPeekCount"),
                #state.filtered,
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end
    local function set_preview_winbar(pan, it)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        -- No results ⇒ NO winbar; the `[no matches]` label is drawn as the panel's single tinted row instead
        -- (see the preview provider `update`).
        if not has_results() then
            vim.wo[pan.win].winbar = ""
            return
        end
        if it and it.path and it.path ~= "" then
            local rel = vim.fn.fnamemodify(it.path, ":~:.")
            local tail = vim.fn.fnamemodify(rel, ":t")
            local dir = vim.fn.fnamemodify(rel, ":h")
            dir = (dir == "." or dir == "") and "" or (dir .. "/")
            -- the file's devicon (when nvim-web-devicons is present and `preview.show_icon`)
            local icon = ""
            if prevcfg.show_icon ~= false then
                local ok_dev, dev = pcall(require, "nvim-web-devicons")
                if ok_dev then
                    local gl = dev.get_icon(tail, vim.fn.fnamemodify(tail, ":e"), { default = true })
                    icon = gl and (gl .. " ") or ""
                end
            end
            -- name = icon + file (bright); dir = padded path on the winbar bg (so it blends into the bar)
            local dpl, dpr = prevcfg.dir_pad_left or 1, prevcfg.dir_pad_right or 1
            vim.wo[pan.win].winbar = ("%%#%s# %s%s %%#%s#%s%s%s%%#%s#%%="):format(
                hl("preview_file", "LvimUiPeekFile"),
                esc(icon),
                esc(tail),
                hl("preview_dir", "LvimUiPickerPreviewDir"),
                string.rep(" ", dpl),
                esc(dir),
                string.rep(" ", dpr),
                hl("bar", "LvimUiPeekFileBar")
            )
        else
            -- A selected item with no path → its text; NO results → the empty label in the file-name spot.
            vim.wo[pan.win].winbar = ("%%#%s# %s %%#%s#%%="):format(
                hl("preview_file", "LvimUiPeekFile"),
                esc((it and it.text) or empty_text),
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end

    local list_provider = {
        cursorline = false,
        -- the SELECTION is the Sel stripe (not a window cursorline), so hide the hardware cursor while the
        -- list is focused (NORMAL mode) — the bright row, not a block cursor, shows where you are.
        hide_cursor = true,
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.32)), panel_height() -- +winbar with results; 1 when empty
        end,
        render = function()
            local lines, hls = {}, {}
            for i, it in ipairs(state.filtered) do
                local row, spans = list_row(it)
                lines[i] = row
                local odd = (i % 2) == 1
                local sel = i == state.sel
                local stripe = sel
                        and (odd and hl("sel_odd", "LvimUiMsgAreaSelOdd") or hl("sel_even", "LvimUiMsgAreaSelEven"))
                    or (odd and hl("row_odd", "LvimUiMsgAreaRowOdd") or hl("row_even", "LvimUiMsgAreaRowEven"))
                hls[#hls + 1] = { i - 1, 0, -1, stripe, sel and 200 or 100 } -- full-row tint (eol)
                -- the leading glyph keeps its OWN colour (e.g. diagnostic severity signs) — above the row
                -- stripe (incl. the selected row's strong tint) so it shows through; the row is ` <icon> …`.
                if it.icon and it.icon ~= "" and it.icon_hl then
                    hls[#hls + 1] = { i - 1, 1, 1 + #it.icon, it.icon_hl, 210 }
                end
                for _, ms in ipairs(spans) do
                    hls[#hls + 1] = { i - 1, ms.c0, ms.c1, hl("match", "LvimUiMsgAreaMatch"), 250 }
                end
            end
            -- No results: with a preview the `[no matches]` label lives in the PREVIEW panel (the list row
            -- stays blank under the prompt overlay); without a preview the list shows the tinted label itself.
            if #lines == 0 then
                if opts.preview then
                    lines = { "" }
                else
                    lines = { " " .. empty_text }
                    hls[1] = { 0, 0, -1, hl("preview_file", "LvimUiPeekFile"), 100 } -- a single yellow-tinted row
                end
            end
            return lines, hls
        end,
        keys = function(map, pan, st)
            state.list_pan, state.st = pan, st
            -- `list_wrap` soft-wraps long rows (so a match far to the right stays visible) — never with the
            -- "↳" continuation marker (tame_win sets showbreak=NONE for this window); default off = truncate.
            tame_win(pan.win, list_wrap)
            set_list_winbar()
            -- NORMAL-mode keys on the list (reached via <Esc> from the prompt): navigate + act without the
            -- query. `<C-l>`/`<C-h>` (panel nav) + the filter bar are owned by the surface chassis.
            if map then
                map({ "j", "<Down>" }, function()
                    move(1)
                end)
                map({ "k", "<Up>" }, function()
                    move(-1)
                end)
                map("<CR>", function()
                    confirm()
                end)
                map("<C-d>", function()
                    scroll_preview(1)
                end)
                map("<C-u>", function()
                    scroll_preview(-1)
                end)
                -- NOTE: <C-j>/<C-k> are the surface's SECTOR navigation (list → footer bar → … and, when
                -- hosted, on past the footer DOWN into the messages via `on_escape_below`). We do NOT bind
                -- them here — that would shadow the stack navigation.
                -- back to typing: `/` + <Tab> + <C-f> (NOT i/a — a consumer filter may own those hotkeys,
                -- e.g. diagnostics' [A]ll / [I]nfo; the filter button keys activate directly from the list).
                map({ "/", "<Tab>", "<C-f>" }, focus_input)
                map({ "q", "<Esc>" }, cancel)
                for _, a in ipairs(opts.keys or {}) do
                    map(a.key, function()
                        act(a.run)
                    end)
                end
            end
        end,
    }

    -- preview panel (optional). Two flavours:
    --   • `opts.preview_file` — the REAL file buffer (lvim-utils.ui.preview): fully EDITABLE, two-way in
    --     sync with the file, its own `<C-h>`/`<C-l>` nav when focused. Items must carry `path` (+ lnum/col).
    --   • `opts.preview(src)` — a read-only scratch buffer of the returned `lines` (+ filetype, focus line).
    local preview_provider
    if opts.preview_file then
        local up = require("lvim-utils.ui.preview").new({
            item = function()
                local it = state.filtered[state.sel]
                local s = it and it._src
                return (s and s.path and s.path ~= "") and { filename = s.path, lnum = s.lnum, col = s.col } or nil
            end,
            number = (opts.preview_numbers == false) and "none" or "normal",
        })
        preview_provider = {
            size = function()
                return math.max(40, math.floor(vim.o.columns * 0.5)), panel_height()
            end,
            update = up.update,
            on_close = up.on_close,
            -- only capture the panel (for C-d/C-u scroll); the file buffer is editable, so we add NO keys
            -- that would shadow `i`/`a` — ui.preview binds the panel-nav keys itself on focus.
            keys = function(_, pan)
                state.preview_pan = pan
            end,
        }
    end
    preview_provider = preview_provider
        or opts.preview
            and {
                size = function()
                    -- Both panels share the CONTENT height (the taller of list/preview, capped) so the
                    -- container fits the bigger one; the preview lines are cached in `state.preview_lines`
                    -- (fetched on selection — see `fetch_preview`). With results +1 for the winbar; with NO
                    -- results a single tinted `[no matches]` row.
                    return math.max(40, math.floor(vim.o.columns * 0.5)), panel_height()
                end,
                update = function(pan)
                    set_preview_winbar(pan, state.filtered[state.sel] and state.filtered[state.sel]._src or nil)
                    -- No results: a single yellow-tinted `[no matches]` row (no winbar, no number, no syntax).
                    if not has_results() then
                        if pan.win and api.nvim_win_is_valid(pan.win) then
                            vim.wo[pan.win].number = false
                        end
                        if vim.bo[pan.buf].filetype ~= "" then
                            pcall(api.nvim_set_option_value, "filetype", "", { buf = pan.buf })
                        end
                        vim.bo[pan.buf].modifiable = true
                        pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, { " " .. empty_text })
                        vim.bo[pan.buf].modifiable = false
                        api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
                        pcall(api.nvim_buf_set_extmark, pan.buf, NS, 0, 0, {
                            end_row = 1,
                            hl_group = hl("preview_file", "LvimUiPeekFile"),
                            hl_eol = true,
                        })
                        return
                    end
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = opts.preview_numbers ~= false -- restore line numbers
                    end
                    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
                    local lines = state.preview_lines or {}
                    vim.bo[pan.buf].modifiable = true
                    pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, lines)
                    vim.bo[pan.buf].modifiable = false
                    local ft = state.preview_ft
                    if ft and ft ~= "" and vim.bo[pan.buf].filetype ~= ft then
                        pcall(api.nvim_set_option_value, "filetype", ft, { buf = pan.buf })
                    end
                    -- `focus` (a 1-based line) scrolls the preview to that row and centres it — used by grep
                    -- to jump the preview to the matched line.
                    local focus = state.preview_focus
                    if focus and pan.win and api.nvim_win_is_valid(pan.win) then
                        pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(focus, #lines)), 0 })
                        api.nvim_win_call(pan.win, function()
                            vim.cmd("normal! zz")
                        end)
                    end
                end,
                keys = function(map, pan)
                    state.preview_pan = pan
                    tame_win(pan.win, opts.preview_wrap == true) -- no "↳" marker; wrap off unless opted in
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = opts.preview_numbers ~= false -- line numbers in the preview
                    end
                    -- NORMAL-mode keys on the preview (focused via <C-l>): the buffer is read-only, so a stray
                    -- `i`/`a` would error E21 — map them (and `/`/<Tab>) back to typing; `q`/<Esc> close,
                    -- `<CR>` opens the focused item. (`j`/`k` scroll the file; `<C-h>` → list via the chassis.)
                    if map then
                        map({ "i", "a", "/", "<Tab>", "<C-f>" }, focus_input)
                        map({ "q", "<Esc>" }, cancel)
                        map("<CR>", function()
                            confirm()
                        end)
                    end
                end,
            }
        or nil

    local function set_list_cursor()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            pcall(api.nvim_win_set_cursor, p.win, { math.max(1, math.min(#state.filtered, state.sel)), 0 })
        end
    end
    -- Fetch the CURRENT selection's preview content into the cache (so `content_h`/`size` know its line
    -- count before relayout, and `update` writes it). No preview, or no selection ⇒ empty.
    local function fetch_preview()
        if opts.preview_file or not opts.preview then
            -- the editable file preview owns its buffer (ui.preview); no scratch lines to cache
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            return
        end
        local it = state.filtered[state.sel]
        if not it then
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            return
        end
        local lines, ft, focus = opts.preview(it._src)
        state.preview_lines = (type(lines) == "table" and lines) or (lines and { tostring(lines) }) or {}
        state.preview_ft, state.preview_focus = ft, focus
    end
    -- Re-fit the surface to the CONTENT height (the taller of list/preview, capped) — only when it actually
    -- changes, so navigating within the same height doesn't reflow the windows.
    local last_h
    local function refit()
        local h = content_h()
        if h ~= last_h and state.st and state.st.relayout then
            last_h = h
            state.st.relayout()
        end
    end
    -- Re-render everything after a selection or result change: refresh the preview cache, re-fit the height,
    -- then re-render both panels + the chrome.
    local function rerender()
        fetch_preview()
        refit()
        if state.list_pan and state.list_pan.refresh then
            state.list_pan.refresh()
        end
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        set_list_winbar() -- the result count in the winbar follows the list
        set_list_cursor() -- scroll the window to keep the selection in view
        publish_status()
    end
    move = function(d)
        if #state.filtered == 0 then
            return
        end
        state.sel = math.max(1, math.min(#state.filtered, state.sel + d))
        rerender() -- the preview (and so the height) changes with the selection
    end
    -- Apply a new result list (from the fuzzy filter or a live source) to the UI.
    local function apply(list)
        if state.closed then
            return
        end
        state.filtered, state.sel = list, 1
        rerender()
    end
    -- A generation guard so a slow async source/filter callback for an OLD query can't overwrite a newer one.
    local refilter_gen = 0
    local function refilter(q)
        state.query = q or ""
        refilter_gen = refilter_gen + 1
        local mygen = refilter_gen
        local function guarded(list)
            if mygen == refilter_gen then
                -- A live source returns raw items (no fuzzy step), so highlight the query in each result text
                -- ourselves (the matched chars light up like the static path).
                local norm = normalize(list, opts.format)
                if state.query ~= "" then
                    for _, it in ipairs(norm) do
                        it.match = utils.match_indices(state.query, it.text)
                    end
                end
                apply(norm)
            end
        end
        if opts.source then
            -- LIVE source: the query drives the results (e.g. ripgrep) — no fuzzy over a static list.
            opts.source(state.query, guarded)
        else
            -- STATIC list: narrow by the active filter bars FIRST, then fuzzy-filter the survivors.
            local pool = items
            if filters then
                pool = {}
                for _, it in ipairs(items) do
                    if passes_filters(it._src) then
                        pool[#pool + 1] = it
                    end
                end
            end
            filter(pool, state.query, function(list)
                if mygen == refilter_gen then
                    apply(list)
                end
            end)
        end
    end
    -- Activate filter button `id` in group `gi`: re-narrow + re-render, then re-sync the button specs' live
    -- `active` flags (so the header re-paints the NEW active button, not the build-time one) + counts.
    set_filter = function(gi, id)
        if not (filters and filters[gi]) then
            return
        end
        filters[gi].active = id
        if state.sync_filter then
            state.sync_filter()
        end
        refilter(state.query)
        if state.st and state.st.refresh_chrome then
            state.st.refresh_chrome()
        end
    end
    scroll_preview = function(dir)
        local p = state.preview_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            api.nvim_win_call(p.win, function()
                vim.cmd("normal! " .. api.nvim_replace_termcodes(dir > 0 and "<C-d>" or "<C-u>", true, false, true))
            end)
        end
    end
    confirm = function()
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
    -- Dismiss the finder (no choice). Shared by the prompt (<C-c>) and NORMAL-mode list (q / <Esc>).
    cancel = function()
        vim.cmd("stopinsert")
        if use_status then
            status.clear()
        end
        if state.st then
            state.st.close()
        end
        if opts.on_cancel then
            opts.on_cancel()
        end
    end
    -- Telescope-style modes: the prompt is INSERT (fuzzy type); <Esc> drops to NORMAL on the list (j/k move,
    -- <C-l>/<C-h> panel nav, the filter bar) — `focus_input` returns to typing, `focus_list` leaves insert.
    focus_input = function()
        local w = state.input_buf and vim.fn.bufwinid(state.input_buf) or -1
        if w ~= -1 then
            api.nvim_set_current_win(w)
            vim.cmd("startinsert!")
        end
    end
    local function focus_list()
        vim.cmd("stopinsert")
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        end
    end
    -- Run a consumer `opts.keys` action on the SELECTED item: it gets the item's source value + a `close`
    -- callback (so an action can dismiss the finder, or keep it open). No selection ⇒ no-op.
    act = function(run)
        local it = state.filtered[state.sel]
        if not it then
            return
        end
        run(it._src, function()
            if use_status then
                status.clear()
            end
            if state.st then
                state.st.close()
            end
        end)
    end

    -- layout: a centred float (default), a "bottom" dock that FLOATS over the bottom rows (statusline
    -- unaffected), or "area" — the Emacs-minibuffer model: it GROWS `cmdheight` like the msgarea cmdline
    -- zone, so a global statusline (heirline) rises ABOVE it. Both bottom/area dock full-width borderless.
    local bottom = opts.layout == "bottom"
    local area = opts.layout == "area"
    local docked = bottom or area

    -- (HOSTED area) Detect early (before the footer + list keys reference it): when the msgarea zone is on, an
    -- `area` finder HOSTS in it (reserves rows above the messages, which compose below). Gates the footer
    -- `C-j msgs` hint, the NORMAL-mode `<C-j>` descend, and the `host` reserve wiring at open.
    if area then
        local ok_ma, m = pcall(require, "lvim-utils.msgarea")
        if ok_ma and m.is_enabled and m.is_enabled() then
            msgarea = m
        end
    end
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
    -- Docked layouts AUTO-fit their height to the result count (intelligent shrink/grow), capped so a huge
    -- result set doesn't take the whole screen. Floats keep a fixed comfortable size.
    local size
    if docked then
        -- The CONTENT (list/preview) is already capped at `max_rows`; the container cap adds the chrome
        -- overhead (winbar + footer + air ≈ 4 rows) so the content can actually reach `max_rows`. The
        -- area's own cmdheight clamp keeps it within the room available between the splits.
        local cap = opts.height or (maxr + 4)
        size = vertical and { height = { auto = true, max = 0.85 } } or { height = { auto = true, max = cap } }
    elseif vertical then
        size = { width = { fixed = 0.7 }, height = { fixed = 0.8 } }
    else
        size = { width = { fixed = 0.85 }, height = { fixed = 0.7 } }
    end
    -- Prompt badge (shared `config.picker.prompt`): an icon and/or label on the STRONG tint, then a gap on
    -- the LIGHT input tint before the typed text. Two virt_text chunks so the badge and the gap carry their
    -- own backgrounds. A per-call `opts.prompt` STRING overrides it (a single badge-tint chunk).
    local pcfg = (require("lvim-utils.config").picker or {}).prompt or {}
    local prompt_hl = hl("prompt", "LvimUiPickerPrompt")
    local input_hl = hl("input", "LvimUiPickerInput")
    local prompt_text
    if opts.prompt then
        prompt_text = opts.prompt -- a literal override
    else
        local sp = string.rep
        local has_icon = (pcfg.icon or "") ~= ""
        local has_label = (pcfg.label or "") ~= ""
        local badge = sp(" ", pcfg.pad_left or 1)
        if has_icon then
            badge = badge .. pcfg.icon
        end
        if has_icon and has_label then
            badge = badge .. sp(" ", pcfg.icon_gap or 1) -- the gap between the icon and the label
        end
        if has_label then
            badge = badge .. pcfg.label
        end
        badge = badge .. sp(" ", pcfg.pad_right or 1)
        -- chunk list: badge (strong tint) + a gap on the input tint before the typed text
        prompt_text = { { badge, prompt_hl }, { sp(" ", pcfg.input_gap or 1), input_hl } }
    end

    -- Footer hints: the standard actions + any consumer `opts.keys` that carry a `name`. `<Esc>` drops to
    -- NORMAL on the list (j/k move, <C-l> preview, the filter bar); `i` returns to typing, `<C-c>` cancels.
    local footer_items = {
        { key = "<CR>", name = "open" },
        { key = "C-j/k", name = "move" },
    }
    for _, a in ipairs(opts.keys or {}) do
        if a.name then
            footer_items[#footer_items + 1] = { key = a.key, name = a.name }
        end
    end
    footer_items[#footer_items + 1] = { key = "Esc", name = "normal" }
    if msgarea then -- (HOSTED) NORMAL-mode <C-j> descends into the messages composed below the finder
        footer_items[#footer_items + 1] = { key = "C-j", name = "msgs" }
    end
    footer_items[#footer_items + 1] = { key = "C-c", name = "close" }

    -- The header FILTER bar: a centred button bar (one button per filter, `●` between groups). Each button
    -- shows a live count (items passing it + the OTHER groups), highlights when active, and toggles its
    -- group on press. Built from `opts.filters`.
    local function build_filter_bar()
        local specs = {}
        for gi, g in ipairs(filters or {}) do
            if gi > 1 then
                specs[#specs + 1] =
                    { type = "separator", text = "●", style = { padding = { 3, 3 }, hl = "LvimUiPeekFilterSep" } }
            end
            for _, b in ipairs(g.buttons) do
                local accent = b.hl_active or "LvimUiPeekFilterActive"
                local dim = b.hl or "LvimUiPeekFilterInactive"
                specs[#specs + 1] = {
                    type = "button",
                    text = b.label,
                    key = b.key, -- brackets the key letter; the bracket takes the accent colour
                    accent = accent,
                    _gi = gi, -- so sync_filter can re-evaluate `active` after a toggle
                    _id = b.id,
                    count = function()
                        local n = 0
                        for _, it in ipairs(items) do
                            if passes_filters(it._src, g) and (not b.predicate or b.predicate(it._src)) then
                                n = n + 1
                            end
                        end
                        return n
                    end,
                    active = b.id == g.active,
                    run = function()
                        set_filter(gi, b.id)
                    end,
                    style = {
                        icon = { padding = { 0, 0 }, normal = accent, active = accent, hover = accent },
                        text = { padding = { 1, 1 }, normal = dim, active = accent, hover = accent },
                    },
                }
            end
        end
        -- keep the specs' `active` flags in step with the groups when a filter toggles (set_filter calls it)
        state.sync_filter = function()
            for _, s in ipairs(specs) do
                if s._gi and filters and filters[s._gi] then
                    s.active = filters[s._gi].active == s._id
                end
            end
        end
        return { items = specs, align = "center" }
    end

    -- (HOSTED area) When the msgarea zone is enabled, the area finder HOSTS itself in it: it reserves its rows
    -- ABOVE the messages (priority 5) instead of growing `cmdheight` on its own, so messages compose BELOW the
    -- finder (no longer covering its footer) and it follows the zone via `reposition` as the zone reflows. When
    -- the zone is off, `host` is nil and the surface grows cmdheight itself (the previous behaviour).
    local host = msgarea
        and function(h)
            return msgarea.segment("lvim-picker-host", { priority = 5 }):reserve(h, function(rect)
                if state.st and state.st.reposition then
                    state.st.reposition(rect)
                end
            end)
        end

    surface.open({
        mode = "float",
        -- "area" sits IN the cmdline region (grows cmdheight, heirline above) like the msgarea zone; the
        -- zindex keeps it in the cmdline layer so it isn't re-anchored below the statusline. "bottom" just
        -- floats over the bottom rows. When the msgarea zone is on, `host` re-homes us INSIDE it (above msgs).
        position = area and "cmdline" or (bottom and "bottom") or nil,
        host = host,
        -- (HOSTED) <C-j> off the bottom sector (the footer bar) descends INTO the messages composed below —
        -- the bottom of the finder's vertical stack (list → footer → messages). Only when there ARE messages;
        -- else the sector nav wraps as usual. The cursor lands on the first message; `<C-k>`/`q`/`<Esc>` return.
        on_escape_below = msgarea and function()
            if msgarea.has_messages() then
                msgarea.focus("messages")
                return true
            end
            return false
        end or nil,
        -- HOSTED: float ABOVE the msgarea zone's own content panel (container 200 / panel 201) so our list /
        -- preview aren't covered by it — our panels land at 211, the prompt at 212, all clear of the messages
        -- that render in the zone panel BELOW us. Unhosted area stays in the cmdline layer at 200.
        zindex = (host and 210) or (area and 200) or nil,
        header_air = (docked and not titled) and false or nil,
        direction = vertical and "vertical" or nil,
        title = surf_title,
        -- Docked: a native top-border TITLE when there IS a title (the canon — a top " " border, no ring +
        -- 1 air row under it), else NO border. A float keeps the rounded ring.
        border = docked and (titled and { "", " ", "", "", "", "", "", "" } or "none") or "rounded",
        separator = vertical and "─" or "│",
        separator_hl = hl("separator", "LvimUiPickerSeparator"),
        size = size,
        header = {
            bars = (function()
                local hb = {}
                if filters then
                    hb[#hb + 1] = build_filter_bar() -- a real header row above the prompt
                end
                hb[#hb + 1] = {
                    input = true,
                    prompt = prompt_text,
                    prompt_hl = prompt_hl,
                    input_hl = input_hl,
                    filetype = "lvim-picker-prompt",
                    -- narrow the prompt to the LIST panel (the left one) when a preview is shown, so it does
                    -- not span the preview — its title winbar owns that side.
                    scope_panel = (preview_provider and (side ~= "left" and side ~= "above")) and 1 or nil,
                    on_change = refilter,
                    keys = function(buf, st)
                        state.st = st
                        state.input_buf = buf -- so NORMAL-mode list can jump back to typing (focus_input)
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
                        imap("<C-c>", cancel) -- hard cancel from the prompt
                        -- Telescope-style: <Esc> / <C-f> drop to NORMAL on the list (where the filter hotkeys
                        -- activate directly — typing in INSERT would feed them to the query). <C-f> in normal
                        -- toggles back to typing.
                        imap("<Esc>", focus_list)
                        imap("<C-f>", focus_list)
                        -- consumer row actions: `opts.keys = { { key = lhs, run = fn(item, close) } }` — e.g.
                        -- open in a split, run a code action, yank. `run` gets the selected item + a close fn.
                        for _, a in ipairs(opts.keys or {}) do
                            imap(a.key, function()
                                vim.cmd("stopinsert")
                                act(a.run)
                            end)
                        end
                    end,
                }
                return hb
            end)(),
        },
        content = { blocks = blocks },
        footer = {
            bars = {
                {
                    items = footer_items,
                },
            },
        },
        close_keys = {}, -- the input owns <Esc>/<C-c>; the panels are not normally focused
        on_close = function()
            state.closed = true
            if msgarea then -- release our hosted rows so the zone shrinks back (or closes if nothing else)
                pcall(function()
                    msgarea.segment("lvim-picker-host"):release()
                end)
            end
            if state.live_augroup then
                pcall(api.nvim_del_augroup_by_id, state.live_augroup)
                state.live_augroup = nil
            end
        end,
    })

    -- initial: show all, select the first, preview it (fetch + fit + render)
    rerender()

    -- LIVE refresh: re-fetch the static items on `opts.refresh_events` (e.g. "DiagnosticChanged") via
    -- `opts.refresh()`, then re-narrow (filters) + re-fuzzy + re-render. Coalesce a burst into ONE reload.
    -- `opts.close_on_empty` dismisses the finder once nothing is left (e.g. all diagnostics fixed). Torn
    -- down in on_close.
    if opts.refresh and opts.refresh_events and not opts.source then
        state.live_augroup =
            api.nvim_create_augroup("LvimUtilsPickerLive_" .. tostring(state.st and state.st.container_buf or 0), {})
        local scheduled = false
        api.nvim_create_autocmd(opts.refresh_events, {
            group = state.live_augroup,
            callback = function(ev)
                -- ignore the echo from our OWN preview buffers (mirroring would loop)
                if state.preview_pan and state.preview_pan.buf == ev.buf then
                    return
                end
                if scheduled or state.closed then
                    return
                end
                scheduled = true
                vim.schedule(function()
                    scheduled = false
                    if state.closed then
                        return
                    end
                    local fresh = opts.refresh()
                    if type(fresh) ~= "table" then
                        return
                    end
                    if #fresh == 0 and opts.close_on_empty and state.st then
                        state.st.close()
                        return
                    end
                    items = normalize(fresh, opts.format)
                    refilter(state.query)
                end)
            end,
        })
    end
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

-- ── file / directory / grep finders ────────────────────────────────────────────

---@param bin string
---@return boolean
local function has(bin)
    return vim.fn.executable(bin) == 1
end

--- The best available command (argv) to LIST files under cwd: fd / fdfind / rg --files / find.
---@return string[]
local function file_list_cmd()
    if has("fd") then
        return { "fd", "--type", "f", "--hidden", "--strip-cwd-prefix", "--exclude", ".git" }
    elseif has("fdfind") then
        return { "fdfind", "--type", "f", "--hidden", "--strip-cwd-prefix", "--exclude", ".git" }
    elseif has("rg") then
        return { "rg", "--files", "--hidden", "--glob", "!.git" }
    end
    return { "find", ".", "-type", "f", "-not", "-path", "*/.git/*" }
end

--- The best available command (argv) to LIST directories under cwd.
---@return string[]
local function dir_list_cmd()
    if has("fd") then
        return { "fd", "--type", "d", "--hidden", "--strip-cwd-prefix", "--exclude", ".git" }
    elseif has("fdfind") then
        return { "fdfind", "--type", "d", "--hidden", "--strip-cwd-prefix", "--exclude", ".git" }
    end
    return { "find", ".", "-type", "d", "-not", "-path", "*/.git/*" }
end

--- Read up to `n` lines of `path` for a preview, with a filetype guessed from the name.
---@param path string
---@param n? integer
---@return string[] lines, string filetype
local function read_preview(path, n)
    local ft = vim.filetype.match({ filename = path }) or ""
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.readfile(path, "", n or 500), ft
    end
    return { "[unreadable]" }, ""
end

--- Run an argv synchronously and return its stdout lines (empty on failure).
---@param argv string[]
---@return string[]
local function run_lines(argv)
    local ok, res = pcall(vim.fn.systemlist, argv)
    if not ok or vim.v.shell_error ~= 0 then
        return type(res) == "table" and res or {}
    end
    return res or {}
end

--- Fuzzy file finder under cwd; confirming edits the file, with a content preview. `opts` forwarded to open.
---@param opts? table
function M.files(opts)
    local items = {}
    for _, p in ipairs(run_lines(file_list_cmd())) do
        if p ~= "" then
            items[#items + 1] = { text = p, path = p }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Files",
        items = items,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }, opts or {}))
end

--- Fuzzy directory finder under cwd; confirming `:cd`s into the chosen directory. `opts` forwarded to open.
---@param opts? table
function M.directories(opts)
    local items = {}
    for _, p in ipairs(run_lines(dir_list_cmd())) do
        if p ~= "" then
            items[#items + 1] = { text = p, path = p }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Directories",
        items = items,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.cd(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return run_lines({ "ls", "-A", it.path }), ""
        end,
    }, opts or {}))
end

--- LIVE grep (ripgrep) under cwd: each query re-runs `rg`, the matches ARE the results, with a preview that
--- jumps to the matched line; confirming opens the file at that line. `opts` forwarded to open.
---@param opts? table
function M.grep(opts)
    opts = opts or {}
    if not has("rg") then
        vim.notify("lvim-utils.picker.grep needs ripgrep (rg)", vim.log.levels.WARN)
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Grep",
        source = function(query, cb)
            if query == nil or #query < 2 then -- wait for a couple of chars (rg over a huge tree is heavy)
                cb({})
                return
            end
            -- `--fixed-strings`: match the query LITERALLY (so `vim.notify("x")` finds that exact text — its
            -- `.` `(` `)` `"` are not regex metacharacters). Set `opts.regex = true` for a regex search.
            local rg = { "rg", "--vimgrep", "--smart-case", "--color=never" }
            if not opts.regex then
                rg[#rg + 1] = "--fixed-strings"
            end
            rg[#rg + 1] = "--"
            rg[#rg + 1] = query
            vim.system(rg, { text = true }, function(res)
                vim.schedule(function()
                    local out = {}
                    for line in (res.stdout or ""):gmatch("[^\n]+") do
                        local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
                        if file then
                            out[#out + 1] = {
                                text = ("%s:%s  %s"):format(file, lnum, text),
                                path = file,
                                lnum = tonumber(lnum),
                                col = tonumber(col),
                            }
                        end
                    end
                    cb(out)
                end)
            end)
        end,
        preview = function(it)
            local lines, ft = read_preview(it.path)
            return lines, ft, it.lnum -- focus the preview on the matched line
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
                pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, (it.col or 1) - 1 })
                vim.cmd("normal! zz")
            end
        end,
    }, opts or {}))
end

--- Fuzzy finder over RECENT files (`v:oldfiles`, readable only), newest first; confirming edits the file.
---@param opts? table
function M.oldfiles(opts)
    local items, seen = {}, {}
    for _, p in ipairs(vim.v.oldfiles or {}) do
        if not seen[p] and vim.fn.filereadable(p) == 1 then
            seen[p] = true
            items[#items + 1] = { text = vim.fn.fnamemodify(p, ":~:."), path = p }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Recent",
        items = items,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }, opts or {}))
end

--- Fuzzy finder over HELP tags; confirming opens that help topic.
---@param opts? table
function M.help_tags(opts)
    local items = {}
    for _, t in ipairs(vim.fn.getcompletion("", "help")) do
        items[#items + 1] = { text = t, tag = t }
    end
    M.open(vim.tbl_extend("force", {
        title = "Help",
        items = items,
        on_confirm = function(it)
            if it and it.tag then
                pcall(vim.cmd.help, it.tag)
            end
        end,
    }, opts or {}))
end

--- Fuzzy finder over GIT-tracked files (`git ls-files`); confirming edits the file, with a content preview.
--- No-op outside a git work tree.
---@param opts? table
function M.git_files(opts)
    local inside = run_lines({ "git", "rev-parse", "--is-inside-work-tree" })[1]
    if inside ~= "true" then
        vim.notify("lvim-utils.picker.git_files: not inside a git work tree", vim.log.levels.WARN)
        return
    end
    local items = {}
    for _, p in ipairs(run_lines({ "git", "ls-files" })) do
        if p ~= "" then
            items[#items + 1] = { text = p, path = p }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Git files",
        items = items,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }, opts or {}))
end

--- Fuzzy finder over installed COLORSCHEMES; confirming applies it (`:colorscheme`). Restores the current
--- scheme on cancel so browsing is non-destructive.
---@param opts? table
function M.colorschemes(opts)
    local current = vim.g.colors_name
    local items = {}
    for _, c in ipairs(vim.fn.getcompletion("", "color")) do
        items[#items + 1] = { text = c, name = c }
    end
    M.open(vim.tbl_extend("force", {
        title = "Colorschemes",
        items = items,
        on_confirm = function(it)
            if it and it.name then
                pcall(vim.cmd.colorscheme, it.name)
            end
        end,
        on_cancel = function()
            if current then
                pcall(vim.cmd.colorscheme, current)
            end
        end,
    }, opts or {}))
end

--- Fuzzy finder over EX commands; confirming drops `:<cmd> ` into the command line (so args can be added)
--- rather than running it blindly.
---@param opts? table
function M.commands(opts)
    local items = {}
    for _, c in ipairs(vim.fn.getcompletion("", "command")) do
        items[#items + 1] = { text = c, cmd = c }
    end
    M.open(vim.tbl_extend("force", {
        title = "Commands",
        items = items,
        on_confirm = function(it)
            if it and it.cmd then
                vim.api.nvim_feedkeys(":" .. it.cmd .. " ", "n", false)
            end
        end,
    }, opts or {}))
end

--- Jump to a `[file] lnum:col  text` location item: open its file (if any) and place the cursor. Shared by
--- the marks / quickfix / jumplist finders, which all produce `{ path?, bufnr?, lnum, col, text }`.
---@param it table
local function jump_to(it)
    if not it then
        return
    end
    if it.path and it.path ~= "" then
        vim.cmd.edit(vim.fn.fnameescape(it.path))
    elseif it.bufnr and api.nvim_buf_is_valid(it.bufnr) then
        api.nvim_set_current_buf(it.bufnr)
    end
    pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, math.max(0, (it.col or 1) - 1) })
    vim.cmd("normal! zz")
end

--- Preview a location item: the file/buffer content with a focus on the target line.
---@param it table
---@return string[] lines, string filetype, integer? focus
local function preview_location(it)
    if it.path and it.path ~= "" then
        local lines, ft = read_preview(it.path)
        return lines, ft, it.lnum
    end
    if it.bufnr and api.nvim_buf_is_loaded(it.bufnr) then
        return api.nvim_buf_get_lines(it.bufnr, 0, 500, false), vim.bo[it.bufnr].filetype, it.lnum
    end
    return { "[no preview]" }, "", nil
end

--- Fuzzy finder over MARKS (`:marks`); confirming jumps to the mark, with a preview at its line.
---@param opts? table
function M.marks(opts)
    local items = {}
    for _, m in ipairs(vim.fn.getmarklist()) do -- global marks (A–Z, 0–9, …)
        local p = vim.fn.fnamemodify(m.file or "", ":~:.")
        items[#items + 1] = {
            text = ("%s  %s:%d"):format(m.mark, p, m.pos[2]),
            path = m.file,
            lnum = m.pos[2],
            col = m.pos[3],
        }
    end
    for _, m in ipairs(vim.fn.getmarklist(api.nvim_get_current_buf())) do -- buffer-local marks (a–z)
        items[#items + 1] = {
            text = ("%s  :%d"):format(m.mark, m.pos[2]),
            bufnr = api.nvim_get_current_buf(),
            lnum = m.pos[2],
            col = m.pos[3],
        }
    end
    M.open(vim.tbl_extend("force", {
        title = "Marks",
        items = items,
        on_confirm = jump_to,
        preview = preview_location,
    }, opts or {}))
end

--- Fuzzy finder over KEYMAPS (all modes); confirming feeds the mapping's lhs. The preview shows its rhs /
--- description.
---@param opts? table
function M.keymaps(opts)
    local items = {}
    for _, mode in ipairs({ "n", "i", "v", "x", "o", "c", "t" }) do
        for _, k in ipairs(vim.api.nvim_get_keymap(mode)) do
            items[#items + 1] = {
                text = ("%s  %s  %s"):format(mode, k.lhs, (k.desc or k.rhs or ""):gsub("%s+", " ")),
                mode = mode,
                lhs = k.lhs,
                detail = k.desc or k.rhs or "",
            }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Keymaps",
        items = items,
        on_confirm = function(it)
            if it and it.lhs and it.mode == "n" then
                api.nvim_feedkeys(api.nvim_replace_termcodes(it.lhs, true, false, true), "m", false)
            end
        end,
        preview = function(it)
            return { it.mode .. "  " .. it.lhs, "", it.detail }, ""
        end,
    }, opts or {}))
end

--- Fuzzy finder over the QUICKFIX list; confirming jumps to the entry, with a preview at its line.
---@param opts? table
function M.quickfix(opts)
    local items = {}
    for _, e in ipairs(vim.fn.getqflist()) do
        local p = e.bufnr ~= 0 and vim.fn.fnamemodify(api.nvim_buf_get_name(e.bufnr), ":~:.") or ""
        items[#items + 1] = {
            text = ("%s:%d  %s"):format(p, e.lnum, (e.text or ""):gsub("^%s+", "")),
            bufnr = e.bufnr ~= 0 and e.bufnr or nil,
            lnum = e.lnum,
            col = e.col,
        }
    end
    M.open(vim.tbl_extend("force", {
        title = "Quickfix",
        items = items,
        on_confirm = jump_to,
        preview = preview_location,
    }, opts or {}))
end

--- Fuzzy finder over the JUMPLIST (newest first); confirming jumps to the location, with a preview.
---@param opts? table
function M.jumplist(opts)
    local jumps = vim.fn.getjumplist()[1] or {}
    local items = {}
    for i = #jumps, 1, -1 do -- newest first
        local j = jumps[i]
        if api.nvim_buf_is_valid(j.bufnr) then
            local p = vim.fn.fnamemodify(api.nvim_buf_get_name(j.bufnr), ":~:.")
            items[#items + 1] = {
                text = ("%s:%d"):format(p ~= "" and p or "[No Name]", j.lnum),
                bufnr = j.bufnr,
                lnum = j.lnum,
                col = (j.col or 0) + 1,
            }
        end
    end
    M.open(vim.tbl_extend("force", {
        title = "Jumplist",
        items = items,
        on_confirm = jump_to,
        preview = preview_location,
    }, opts or {}))
end

return M
