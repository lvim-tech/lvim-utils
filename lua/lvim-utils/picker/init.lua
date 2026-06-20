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
---@field items? any[]  STATIC candidates (strings, or tables — see `format`), fuzzy-filtered as you type
---@field source? fun(query: string, cb: fun(items: any[]))  a LIVE source: each query produces the results (e.g. ripgrep); use instead of `items`
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?, integer?  preview lines (+ a filetype, + a 1-based focus line) per selection
---@field preview_side? "right"|"left"|"below"|"above"  where the preview sits (default "right"); below/above stack + grow height
---@field preview_numbers? boolean  show line numbers in the preview (default true)
---@field preview_wrap? boolean  soft-wrap the preview (default false)
---@field empty_text? string  shown when there are no results (list body + preview winbar)
---@field title? string  the float title / the statusline action title
---@field icon? string  an optional leading glyph for the title (statusline)
---@field statusline? boolean  (docked layouts) publish title/counter/query to the bottom statusline (default true); false = draw them in the navigator
---@field prompt? string  the query prompt prefix (default "➤ ")
---@field max_rows? integer  natural list/preview height hint (default 15)
---@field layout? "float"|"bottom"|"area"  centred float (default), a bottom dock, or the cmdheight area (heirline above)
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

    -- Every highlight group is configurable + shared via `config.picker.hl` (fall back to the built-in
    -- tint-canon / peek groups).
    local pkcfg = require("lvim-utils.config").picker or {}
    local phl = pkcfg.hl or {}
    local function hl(key, default)
        return phl[key] or default
    end
    local empty_text = opts.empty_text or pkcfg.empty_text or "[no matches]"
    local prevcfg = pkcfg.preview or {}

    -- The global `showbreak`/`wrap` would draw a "↳" continuation marker on a wrapped long row — kill it on
    -- our windows (the list/input never wrap; the preview wraps but shows no marker).
    local function tame_win(win, wrap)
        if win and api.nvim_win_is_valid(win) then
            vim.wo[win].wrap = wrap or false
            vim.wo[win].list = false
            vim.wo[win].showbreak = ""
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
    -- Dynamic height: the container fits the TALLER of the two panels, capped at `max_rows`. The list
    -- contributes its result count; the preview contributes its content's line count (cached on selection).
    -- 0 results ⇒ both are 0 ⇒ only the prompt + the preview winbar show. relayout() re-fits on every change.
    state.preview_lines = {}
    local function list_h()
        return math.min(#state.filtered, maxr) -- 0 when empty (no [no matches] body row)
    end
    local function preview_h()
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
        keys = function(_, pan, st)
            state.list_pan, state.st = pan, st
            tame_win(pan.win, false) -- no wrap / no "↳" continuation marker on long rows
            set_list_winbar()
        end,
    }

    -- preview panel (optional): the selected item's content, scrollable + syntax-highlighted. An `update`
    -- provider OWNS its buffer, so it writes the lines AND sets the filetype — which fires FileType, so
    -- treesitter / syntax colour the preview. `opts.preview(src)` returns `lines, filetype?`.
    local preview_provider = opts.preview
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
                    -- No results: a single yellow-tinted `[no matches]` row (no winbar, no syntax).
                    if not has_results() then
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
                keys = function(_, pan)
                    state.preview_pan = pan
                    tame_win(pan.win, opts.preview_wrap == true) -- no "↳" marker; wrap off unless opted in
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = opts.preview_numbers ~= false -- line numbers in the preview
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
        if not opts.preview then
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
    local function move(d)
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
            -- STATIC list: fuzzy-filter it (filter already returns grid items, so skip re-normalising).
            filter(items, state.query, function(list)
                if mygen == refilter_gen then
                    apply(list)
                end
            end)
        end
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
        separator_hl = hl("separator", "LvimUiPickerSeparator"),
        size = size,
        header = {
            bars = {
                {
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

    -- initial: show all, select the first, preview it (fetch + fit + render)
    rerender()
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
            vim.system(
                { "rg", "--vimgrep", "--smart-case", "--color=never", "--", query },
                { text = true },
                function(res)
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
                end
            )
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
