-- lvim-utils.ui.peek: a two-pane "peek" navigator for a list of source locations.
--
-- Left pane = the locations grouped by file as a collapsible tree (header = file icon + name +
-- directory + count; an expanded group's rows are plain source text behind a `▏` guide, no line
-- numbers). Right pane = a LIVE preview of the focused location in its REAL buffer, WITH line
-- numbers, so syntax/treesitter highlighting comes for free. The list is glance-flat: only the
-- centred title is tinted.
--
-- Expansion is configurable (`peek.expand`): "auto" keeps just the focused group open and lets
-- it follow the cursor; "manual" toggles groups open/closed by click or <CR> on their header.
-- Both modes support the mouse (click a header to fold, an item to preview, double-click to
-- open). Two presentations via `opts.mode`: "split" (bottom splits) or "float" (detached).
--
-- Pure UI: the caller passes normalized `items`, a `title`, and an optional `on_jump` handler.
--
---@module "lvim-utils.ui.peek"

local api = vim.api
local util = require("lvim-utils.ui.util")
local uibar = require("lvim-utils.ui.bar")

local M = {}

local NS_LIST = api.nvim_create_namespace("LvimUiPeekList")
local NS_PREV = api.nvim_create_namespace("LvimUiPeekPreview")
local NS_CHROME = api.nvim_create_namespace("LvimUiPeekChrome")

-- Forward declaration: tear the panel down (defined below; referenced by update_preview's keys).
---@type fun(state: table)
local close_all

-- Forward declaration: enter a bar "menu" (focus + keyboard selection). Defined before set_keys, but
-- referenced earlier by update_preview's preview keymap (the `m` key from the preview).
---@type fun(state: table, where?: string)
local enter_menu

-- Forward declaration: cycle focus through the sectors (header · center · footer). Defined before
-- set_keys, referenced earlier by update_preview's preview keymaps (the sector keys).
---@type fun(state: table, dir: integer)
local sector_cycle

-- Forward declaration: the footer ACTION defs ({key,name,run}) — the single source for the footer
-- buttons AND the footer bar-menu hotkeys. Defined near build_action_buttons; used earlier by set_keys.
---@type fun(state: table): table[]
local footer_actions

-- Forward declaration: recompute geometry and re-place the panes in place (defined after
-- open_panel; referenced by the VimResized autocmd in set_keys, which is defined earlier).
---@type fun(state: table)
local relayout

-- Forward declaration: drag the list|preview divider with the mouse (defined before set_keys but
-- referenced by update_preview's preview keymaps, which are defined earlier).
---@type fun(state: table)
local drag_divider

-- Forward declaration: redraw the container chrome (centred filter bar + divider) from stored dims;
-- defined below but referenced by set_filter (filter changes re-render the bar), defined earlier.
---@type fun(state: table, W?: integer, H?: integer, sep_col?: integer, sep_char?: string)
local render_chrome

-- ─── list-pane cursor hiding ──────────────────────────────────────────────────
-- In the list the focused row is shown by the cursorline, so the hardware cursor only adds
-- noise — hide it while the list pane is focused and restore it on the way out (to the preview
-- or on close). Same technique as lvim-utils.cursor: a transparent 1-cell bar via the
-- LvimUtilsHiddenCursor group (blend=100), which is imperceptible in both GUI and TUI. Focus,
-- not visibility, drives it — the cursor must come back the moment focus enters the preview.

--- Hide the hardware cursor (no-op when already hidden). Saves the prior guicursor on `state`.
---@param state table
local function hide_cursor(state)
    if state.cursor_hidden then
        return
    end
    state.saved_guicursor = vim.o.guicursor
    api.nvim_set_hl(0, "LvimUtilsHiddenCursor", { blend = 100, nocombine = true })
    vim.o.guicursor = "a:ver1-LvimUtilsHiddenCursor"
    state.cursor_hidden = true
end

--- Restore the cursor saved by hide_cursor (no-op when not hidden).
---@param state table
local function show_cursor(state)
    if not state.cursor_hidden then
        return
    end
    if state.saved_guicursor then
        vim.o.guicursor = state.saved_guicursor
        state.saved_guicursor = nil
    end
    state.cursor_hidden = false
end

--- Define highlight `out` as a TINT of `accent`'s foreground: bg = the accent fg blended toward the
--- panel bg (`LvimUiPeekNormal`) by `t` (0 = panel bg, 1 = the full accent colour); when `fg_too`, fg
--- is the accent colour too (bold) for a chrome cell coloured by its TYPE. Recomputed from the CURRENT
--- theme each call (survives colorscheme changes). Returns `out`, or nil when the accent has no fg.
---@param accent? string
---@param t number
---@param out string
---@param fg_too? boolean
---@return string|nil
local function tint_hl(accent, t, out, fg_too)
    local af = accent and api.nvim_get_hl(0, { name = accent, link = false })
    local fg = af and af.fg
    if not fg then
        return nil
    end
    local nb = api.nvim_get_hl(0, { name = "LvimUiPeekNormal", link = false })
    local bg = nb.bg or 0
    local function comp(c, sh)
        return math.floor(c / sh) % 256
    end
    local function mix(a, b)
        return math.floor(a * t + b * (1 - t) + 0.5)
    end
    local rgb = mix(comp(fg, 65536), comp(bg, 65536)) * 65536
        + mix(comp(fg, 256), comp(bg, 256)) * 256
        + mix(comp(fg, 1), comp(bg, 1))
    api.nvim_set_hl(0, out, { bg = rgb, fg = fg_too and fg or nil, bold = fg_too or nil })
    return out
end

---@class LvimUiPeekItem
---@field filename string   absolute path
---@field lnum     integer  1-based line
---@field col      integer  1-based column
---@field end_lnum? integer
---@field end_col?  integer
---@field text?    string   the source line text (shown in the list)
---@field icon?    string   optional glyph rendered before the row text (e.g. a severity sign)
---@field icon_hl? string   highlight group for `icon`
---@field severity? integer optional caller tag (e.g. diagnostic severity) for filter predicates

---@class LvimUiPeekBarButton
---@field id        string                         unique within its group; `active` points at one
---@field label     string                         button caption (its first letter is bracketed)
---@field key?      string                         hotkey (default: the label's first letter, lowercased)
---@field predicate? fun(item: LvimUiPeekItem): boolean  keep an item when true (nil = keep all)
---@field hl?        string                         inactive-state highlight override
---@field hl_active? string                         active-state highlight override

---@class LvimUiPeekBarGroup
---@field id      string                  group identifier
---@field active  string                  id of the currently active button
---@field primary? boolean                the `keys.filter` cycle key drives this group
---@field buttons LvimUiPeekBarButton[]

---@class LvimUiPeekBar
---@field groups LvimUiPeekBarGroup[]  one row of toggle buttons; the effective filter is the AND
---                                    of every group's active button predicate

--- Resolve the effective peek config: defaults ⊕ instance overrides ⊕ per-call opts.
---@param instance_cfg table|nil
---@param opts table
---@return table
local function resolve_cfg(instance_cfg, opts)
    local p = vim.deepcopy(util.cfg().peek or {})
    if instance_cfg and instance_cfg.peek then
        p = vim.tbl_deep_extend("force", p, instance_cfg.peek)
    end
    if opts.mode then
        p.mode = opts.mode
    end
    return p
end

--- Group the flat items by file (first-seen order) into a tree + flat index maps.
---@param items LvimUiPeekItem[]
---@return table  { groups = { {tail, dir, items={{it, idx}}} }, items_flat, item_group }
local function build_model(items)
    local order, byfile = {}, {}
    for _, it in ipairs(items) do
        if not byfile[it.filename] then
            byfile[it.filename] = {}
            order[#order + 1] = it.filename
        end
        table.insert(byfile[it.filename], it)
    end
    local groups, items_flat, item_group = {}, {}, {}
    for gi, fname in ipairs(order) do
        local rel = vim.fn.fnamemodify(fname, ":~:.")
        local dir = vim.fn.fnamemodify(rel, ":h")
        local g = {
            tail = vim.fn.fnamemodify(fname, ":t"),
            dir = (dir == "." or dir == "") and "" or dir,
            items = {},
        }
        for _, it in ipairs(byfile[fname]) do
            items_flat[#items_flat + 1] = it
            local idx = #items_flat
            item_group[idx] = gi
            g.items[#g.items + 1] = { it = it, idx = idx }
        end
        groups[gi] = g
    end
    return { groups = groups, items_flat = items_flat, item_group = item_group }
end

--- The button currently active in `group` (the one whose id matches `group.active`).
---@param group LvimUiPeekBarGroup
---@return LvimUiPeekBarButton|nil
local function active_button(group)
    for _, b in ipairs(group.buttons) do
        if b.id == group.active then
            return b
        end
    end
    return group.buttons[1]
end

--- True when `it` passes every group's active predicate EXCEPT `except` (nil = all groups). Used
--- both for the effective filter (except = nil) and for per-button counts (except = that group).
---@param bar LvimUiPeekBar
---@param it LvimUiPeekItem
---@param except LvimUiPeekBarGroup|nil
---@return boolean
local function passes_bar(bar, it, except)
    for _, g in ipairs(bar.groups) do
        if g ~= except then
            local b = active_button(g)
            if b and b.predicate and not b.predicate(it) then
                return false
            end
        end
    end
    return true
end

--- (Re)build the visible model from `state.all_items` through the bar's effective filter, then
--- reset the selection to the first item. Called on open and on every filter change, so the panel
--- re-filters live without reopening. With no bar the full item set is used (locations unchanged).
---@param state table
local function apply_filter(state)
    local items = state.all_items
    if state.bar then
        local kept = {}
        for _, it in ipairs(items) do
            if passes_bar(state.bar, it, nil) then
                kept[#kept + 1] = it
            end
        end
        items = kept
    end
    local model = build_model(items)
    state.groups = model.groups
    state.items_flat = model.items_flat
    state.item_group = model.item_group
    state.cur = 1
    state.expanded = { [1] = true }
    state.bar_rows = 0 -- the bar is in the container now, so the list has no leading bar row
    if state.mode == "manual" then
        state.sel = (#state.groups > 0 and #state.groups[1].items > 0) and 2 or 1
    end
end

--- Compose one display line from segments, recording byte-range highlight spans.
---@param segments table[]  { {text, hl_or_nil}, ... }
---@return string text, table spans
local function compose(segments)
    local text, spans, off = "", {}, 0
    for _, seg in ipairs(segments) do
        local t = seg[1]
        if t ~= "" and seg[2] then
            spans[#spans + 1] = { off, off + #t, seg[2] }
        end
        text = text .. t
        off = off + #t
    end
    return text, spans
end

--- Per-side insets (top, right, bottom, left) of a resolved 8-element border: 1 cell for any side
--- whose element is a non-empty string (a glyph OR a " " padding), 0 for an empty "" side.
---@param b table  resolved border { tl, t, tr, r, br, b, bl, l }
---@return integer top, integer right, integer bottom, integer left
local function insets(b)
    if type(b) ~= "table" then
        return 0, 0, 0, 0
    end
    local function on(i)
        local e = b[i]
        local s = type(e) == "table" and e[1] or e
        return (s and s ~= "") and 1 or 0
    end
    return on(2), on(4), on(6), on(8)
end

--- The first item index of group `gi`.
---@param state table
---@param gi integer
---@return integer
local function group_first(state, gi)
    for idx, g in ipairs(state.item_group) do
        if g == gi then
            return idx
        end
    end
    return 1
end

--- The item currently in focus (and its index), or nil when a header row is focused (manual).
---@param state table
---@return LvimUiPeekItem|nil, integer|nil
local function focused_item(state)
    if state.mode == "manual" then
        local row = state.rows and state.rows[state.sel]
        if row and row.kind == "item" then
            return state.items_flat[row.idx], row.idx
        end
        return nil, nil
    end
    return state.items_flat[state.cur], state.cur
end

--- A filetype icon glyph for `filename` from nvim-web-devicons when installed. Its COLOUR is
--- intentionally discarded — the winbar paints the icon with its own group (`LvimUiPeekFileIcon`),
--- not the per-filetype devicon colour. Falls back to a generic document glyph.
---@param filename string
---@return string
local function file_icon(filename)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok and devicons then
        local icon = devicons.get_icon(
            vim.fn.fnamemodify(filename, ":t"),
            vim.fn.fnamemodify(filename, ":e"),
            { default = true }
        )
        if icon and icon ~= "" then
            return icon
        end
    end
    return "󰈙"
end

--- Update the right pane: load the focused location's real buffer and mark the match range.
---@param state table
local function update_preview(state)
    local it = focused_item(state)
    if not (it and api.nvim_win_is_valid(state.preview_win)) then
        return
    end
    local pbuf = vim.fn.bufadd(it.filename)
    vim.fn.bufload(pbuf)
    api.nvim_win_set_buf(state.preview_win, pbuf)
    local ft = vim.filetype.match({ filename = it.filename, buf = pbuf })
    if ft and vim.bo[pbuf].filetype ~= ft then
        vim.bo[pbuf].filetype = ft
    end
    -- Preview winbar (full width): the filetype icon, the file name, then its directory path.
    local rel = vim.fn.fnamemodify(it.filename, ":~:.")
    local tail = vim.fn.fnamemodify(it.filename, ":t")
    local dir = vim.fn.fnamemodify(rel, ":h")
    local wb = "%#LvimUiPeekFileIcon# " .. file_icon(it.filename) .. " %#LvimUiPeekFile#" .. tail .. " "
    if dir ~= "." and dir ~= "" then
        wb = wb .. "%#LvimUiPeekFileBar# " .. dir
    end
    vim.wo[state.preview_win].winbar = wb .. "%#LvimUiPeekFileBar#%="
    -- Only the line-number gutter (per config) — no signs/folds/diagnostics columns from the
    -- real file buffer. Re-applied here because the buffer swap can re-trigger plugins.
    local pn = state.cfg.preview_number or "normal"
    vim.wo[state.preview_win].number = pn == "normal" or pn == "relative"
    vim.wo[state.preview_win].relativenumber = pn == "relative"
    vim.wo[state.preview_win].signcolumn = "no"
    vim.wo[state.preview_win].foldcolumn = "0"
    vim.wo[state.preview_win].statuscolumn = ""
    vim.wo[state.preview_win].cursorline = true

    -- Buffer-local keys on the preview (the real file buffer): focus back to the list, and close.
    -- Re-bound when the previewed file changes; removed in close_all so the file buffer is left
    -- clean afterwards.
    if state.preview_mapped ~= pbuf then
        if state.preview_mapped and api.nvim_buf_is_valid(state.preview_mapped) then
            for _, k in ipairs(state.preview_keys or {}) do
                pcall(vim.keymap.del, "n", k, { buffer = state.preview_mapped })
            end
        end
        local keys, p = {}, state.cfg
        local function pmap(lhs, fn)
            if lhs then
                vim.keymap.set("n", lhs, fn, { buffer = pbuf, nowait = true, silent = true })
                keys[#keys + 1] = lhs
            end
        end
        pmap(p.keys.focus_list, function()
            if api.nvim_win_is_valid(state.list_win) then
                api.nvim_set_current_win(state.list_win)
            end
        end)
        -- `m` from the preview also focuses the filter bar menu (only when there is a bar).
        if state.bar then
            pmap(p.keys.focus_menu or "m", function()
                enter_menu(state, "header")
            end)
        end
        -- Sector navigation from the preview too.
        pmap(p.keys.sector_next or "<C-j>", function()
            sector_cycle(state, 1)
        end)
        pmap(p.keys.sector_prev or "<C-k>", function()
            sector_cycle(state, -1)
        end)
        pmap(p.keys.close, function()
            close_all(state)
        end)
        -- Drag the divider from the preview side too (the preview is non-focusable, but a drag that
        -- started in the list keeps firing its map; this covers a drag that begins over the preview).
        pmap("<LeftDrag>", function()
            drag_divider(state)
        end)
        state.preview_mapped, state.preview_keys = pbuf, keys
    end
    local lnum = math.min(it.lnum, math.max(1, api.nvim_buf_line_count(pbuf)))
    pcall(api.nvim_win_set_cursor, state.preview_win, { lnum, math.max(0, (it.col or 1) - 1) })
    api.nvim_win_call(state.preview_win, function()
        vim.cmd("normal! zz")
    end)
    api.nvim_buf_clear_namespace(pbuf, NS_PREV, 0, -1)
    local l1 = (it.end_lnum or it.lnum) - 1
    local c0 = math.max(0, (it.col or 1) - 1)
    local c1 = it.end_col and (it.end_col - 1) or (c0 + 1)
    pcall(api.nvim_buf_set_extmark, pbuf, NS_PREV, it.lnum - 1, c0, {
        end_row = l1,
        end_col = c1,
        hl_group = "LvimUiPeekMatch",
    })
end

--- Which groups are expanded right now: just the focused group in "auto", the toggled set in
--- "manual".
---@param state table
---@return table<integer, boolean>
local function expanded_set(state)
    if state.mode == "manual" then
        return state.expanded
    end
    return { [state.item_group[state.cur] or 1] = true }
end

--- Render the list, rebuild the row map, then place the marker / cursor and refresh the preview.
---@param state table
local function refresh(state)
    local p, buf = state.cfg, state.list_buf
    local exp = expanded_set(state)
    local texts, spans, rows, item_line = {}, {}, {}, {}
    local function emit(descriptor, segments)
        local text, sp = compose(segments)
        texts[#texts + 1] = text
        spans[#texts] = sp
        rows[#texts] = descriptor
        return #texts
    end
    -- The filter bar lives in the container (centred under the title), not in the list — see
    -- render_chrome / build_bar_row. The list starts straight at the first file group.
    for gi, g in ipairs(state.groups) do
        local icon = exp[gi] and (p.group_icon_open or "") or (p.group_icon_closed or "")
        emit({ kind = "header", gi = gi }, {
            { icon, "LvimUiPeekGroupIcon" },
            { " ", nil },
            { g.tail, "LvimUiPeekGroup" },
            { g.dir ~= "" and "  " or "", nil },
            { g.dir, "LvimUiPeekDir" },
            { "  ", nil },
            { tostring(#g.items), "LvimUiPeekCount" },
        })
        if exp[gi] then
            for _, entry in ipairs(g.items) do
                local it = entry.it
                local guide = p.guide_icon or "▏"
                local raw = it.text or ""
                local shown = raw:gsub("^%s+", "")
                local lead = #raw - #shown -- bytes of stripped leading indent
                -- Optional per-item icon (e.g. a diagnostic severity sign) sits between the guide
                -- gutter and the text; its bytes count toward the row prefix so the match span stays
                -- aligned.
                local iconseg = it.icon and (it.icon .. " ") or ""
                local prefix = #guide + 2 + #iconseg
                local ln = emit({ kind = "item", gi = gi, idx = entry.idx }, {
                    { guide, "LvimUiPeekGuide" },
                    { "  ", nil },
                    { iconseg, it.icon_hl or "LvimUiPeekText" },
                    { shown, "LvimUiPeekText" },
                })
                -- Highlight the reference (match span) inside the row text — the SAME range the
                -- preview marks, so every location kind (references / definition / implementation /
                -- … ) shows its match in both panes. Only valid when the row text IS the source line
                -- (so col/end_col index into it): callers whose rows are a MESSAGE, not the source
                -- line — e.g. diagnostics — pass `list_match = false` to suppress it. Cols are 1-based
                -- on the ORIGINAL line, so subtract the stripped indent and add the row prefix. A
                -- same-line `end_col` gives an exact range; a multi-line match runs to the end of the
                -- shown text; a bare position (no `end_col`) falls back to a single cell.
                if state.list_match ~= false then
                    local c0 = math.max(0, (it.col or 1) - 1 - lead)
                    local same = not it.end_lnum or it.end_lnum == it.lnum
                    local c1
                    if it.end_col and same then
                        c1 = it.end_col - 1 - lead
                    elseif it.end_lnum and not same then
                        c1 = #shown
                    else
                        c1 = c0 + 1
                    end
                    c1 = math.max(c0 + 1, math.min(c1, #shown))
                    if c0 < #shown then
                        local sp = spans[ln]
                        sp[#sp + 1] = { prefix + c0, prefix + c1, "LvimUiPeekMatch" }
                    end
                end
                item_line[entry.idx] = ln
            end
        end
    end
    state.rows = rows

    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, texts)
    api.nvim_buf_clear_namespace(buf, NS_LIST, 0, -1)
    for i, sp in ipairs(spans) do
        for _, s in ipairs(sp) do
            pcall(api.nvim_buf_set_extmark, buf, NS_LIST, i - 1, s[1], { end_col = s[2], hl_group = s[3] })
        end
    end
    vim.bo[buf].modifiable = false

    -- List winbar: kind + the (filtered) count, LABELLED by the active PRIMARY filter so it shows what
    -- the count is OF — e.g. "Diagnostics  All (7)" / "Diagnostics  Error (2)". Falls back to a plain
    -- "(N)" when there is no bar / no primary group.
    if api.nvim_win_is_valid(state.list_win) then
        local label, accent
        for _, g in ipairs(state.bar and state.bar.groups or {}) do
            if g.primary then
                for _, b in ipairs(g.buttons) do
                    if b.id == g.active then
                        label = b.label
                        accent = b.hl_active or "LvimUiPeekFilterActive"
                    end
                end
            end
        end
        -- Both winbar cells are tinted by the active filter's TYPE colour (Error → red, All → green, …),
        -- each keeping its OWN tint STRENGTH: the kind label is the stronger 0.4 chrome, the count the
        -- lighter 0.3 one (matching the static LvimUiPeekKind / …Bar). No accent → the static groups.
        local kind_hl = (accent and tint_hl(accent, 0.4, "LvimUiPeekKindLabel", true)) or "LvimUiPeekKind"
        local count_hl = (accent and tint_hl(accent, 0.3, "LvimUiPeekKindType", true)) or "LvimUiPeekKindBar"
        vim.wo[state.list_win].winbar = "%#"
            .. kind_hl
            .. "# "
            .. (state.kind or "Locations")
            .. " %#"
            .. count_hl
            .. "# "
            .. (label and (label .. " ") or "")
            .. "("
            .. #state.items_flat
            .. ")%="
    end

    -- Selected line: the focused item in auto, the tracked row in manual (clamped so it never
    -- lands on the pinned filter row — selection starts at the first row after the bar).
    local minrow = (state.bar_rows or 0) + 1
    local sel_line
    if state.mode == "manual" then
        local hi = math.max(1, #rows)
        state.sel = math.min(math.max(state.sel or minrow, minrow), hi)
        sel_line = state.sel
    else
        sel_line = item_line[state.cur]
    end

    -- Focus is shown by the cursorline alone (no row marker).
    local on_item = sel_line and rows[sel_line] and rows[sel_line].kind == "item"
    if sel_line and api.nvim_win_is_valid(state.list_win) then
        api.nvim_win_set_cursor(state.list_win, { sel_line, 0 })
    end
    if on_item then
        update_preview(state)
    end
end

--- Close every window the peek opened and wipe its scratch list buffer.
---@param state table
close_all = function(state)
    -- Bring the hardware cursor back before anything else, so it is restored even if a later
    -- step errors (the list pane was focused, so it was hidden).
    show_cursor(state)
    if state.saved_mousemove ~= nil then
        vim.o.mousemoveevent = state.saved_mousemove
        state.saved_mousemove = nil
    end
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    if state.preview_mapped and api.nvim_buf_is_valid(state.preview_mapped) then
        for _, k in ipairs(state.preview_keys or {}) do
            pcall(vim.keymap.del, "n", k, { buffer = state.preview_mapped })
        end
        state.preview_mapped = nil
    end
    for _, w in ipairs({ state.list_win, state.preview_win, state.container_win, state.backdrop_win }) do
        if w and api.nvim_win_is_valid(w) then
            pcall(api.nvim_win_close, w, true)
        end
    end
    if state.list_buf and api.nvim_buf_is_valid(state.list_buf) then
        pcall(api.nvim_buf_delete, state.list_buf, { force = true })
    end
    -- Focus has returned to a normal window; nudge focus-dependent UI (e.g. a colorscheme's
    -- dim_inactive) to re-evaluate it, since closing floats does not always emit a WinEnter.
    vim.schedule(function()
        pcall(api.nvim_exec_autocmds, "WinEnter", { modeline = false })
    end)
end

--- Open the focused location and tear the peek down. Uses `on_jump` when supplied, else jumps
--- in the origin window with the given command ("edit" | "split" | "vsplit" | "tabedit").
---@param state table
---@param cmd string
local function do_jump(state, cmd)
    local it = focused_item(state)
    if not it then
        return
    end
    local origin, on_jump = state.origin, state.on_jump
    close_all(state)
    if on_jump then
        on_jump(it, cmd)
        return
    end
    if origin and api.nvim_win_is_valid(origin) then
        api.nvim_set_current_win(origin)
    end
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(it.filename))
    pcall(api.nvim_win_set_cursor, 0, { it.lnum, math.max(0, (it.col or 1) - 1) })
    vim.cmd("normal! zz")
end

--- Toggle (manual) or expand-and-focus (auto) the group `gi`.
---@param state table
---@param gi integer
local function toggle_group(state, gi)
    if state.mode == "manual" then
        state.expanded[gi] = not state.expanded[gi]
    else
        state.cur = group_first(state, gi)
    end
    refresh(state)
end

--- Act on a row (used by <CR> and mouse): toggle a header, jump on an item.
---@param state table
---@param line integer
---@param jump boolean  open the location when the row is an item
local function activate(state, line, jump)
    local row = state.rows[line]
    if not row or row.kind == "filter" then
        return
    end
    -- Keep the cursor where the user acted (manual tracks the line directly).
    if state.mode == "manual" then
        state.sel = line
    end
    if api.nvim_win_is_valid(state.list_win) then
        api.nvim_win_set_cursor(state.list_win, { line, 0 })
    end
    if row.kind == "header" then
        toggle_group(state, row.gi)
        return
    end
    if state.mode ~= "manual" then
        state.cur = row.idx
    end
    if jump then
        do_jump(state, "edit")
    else
        refresh(state)
    end
end

--- Per-pane window dressing. The list has no line numbers (plain text rows); the preview shows
--- numbers like a normal buffer. Both share the tinted chrome.
---@param win integer
---@param is_list boolean
local function dress(win, is_list)
    vim.wo[win].number = not is_list
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true
    -- Line numbers (preview pane) are left UNMAPPED so they inherit the editor's real LineNr /
    -- CursorLineNr — the preview reads like a normal buffer, number column included.
    vim.wo[win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiPeekCursorLine,FloatBorder:LvimUiPeekBorder"
    vim.wo[win].wrap = false -- clean glance look: no soft-wrap in either pane
end

-- Forward declaration: move focus to another group (defined after set_keys).
---@type fun(state: table, gi: integer)
local toggle_group_to

--- Switch bar group `gi`'s active button to `button_id`, re-filter, and re-render. No-op when it
--- is already active.
---@param state table
---@param gi integer
---@param button_id string
local function set_filter(state, gi, button_id)
    local g = state.bar and state.bar.groups[gi]
    if not g or g.active == button_id then
        return
    end
    g.active = button_id
    apply_filter(state)
    render_chrome(state) -- redraw the container bar (counts + active state) from stored dims
    refresh(state)
end

--- Cycle the PRIMARY group's active button to the next one (wraps). Bound to `keys.filter`.
---@param state table
local function cycle_primary(state)
    if not state.bar then
        return
    end
    for gi, g in ipairs(state.bar.groups) do
        if g.primary then
            local idx = 1
            for i, b in ipairs(g.buttons) do
                if b.id == g.active then
                    idx = i
                    break
                end
            end
            set_filter(state, gi, g.buttons[(idx % #g.buttons) + 1].id)
            return
        end
    end
end

--- The buttons of the bar the menu is focused on (header = filter buttons, footer = action buttons).
---@param state table
---@return table[]
local function active_buttons(state)
    if state.menu and state.menu.where == "footer" then
        return state.footer_buttons or {}
    end
    return state.bar_buttons or {}
end

--- Fire a button: every button spec (filter or action) carries a `run` callback (the bar/`ui.button`
--- model). Separators have no spec/run and are ignored.
---@param spec table|nil
local function activate_button(spec)
    if spec and spec.run then
        spec.run()
    end
end

--- The header menu's initial selection: the active button of the PRIMARY group (e.g. the diagnostics
--- severity All/Error/…, switched far more often than the scope group), falling back to any active
--- button, then 1.
---@param state table
---@return integer
local function menu_initial_sel(state)
    local any_active
    for i, bb in ipairs(state.bar_buttons or {}) do
        if bb.spec and bb.spec.active then
            if bb.spec.primary then
                return i
            end
            any_active = any_active or i
        end
    end
    return any_active or 1
end

--- Focus a bar (`where` = "header" | "footer") as a keyboard menu: focus the chrome container, hide
--- the cursor, select a button and redraw with the selection + responsive chevrons.
---@param state table
---@param where? string
enter_menu = function(state, where)
    where = where or "header"
    if where == "header" and not (state.bar and state.bar_buttons and #state.bar_buttons > 0) then
        return
    end
    if where == "footer" and not (state.footer_buttons and #state.footer_buttons > 0) then
        return
    end
    if not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local ret = (state.menu and state.menu.ret) or api.nvim_get_current_win()
    -- Restore the selection where it was last left in THIS bar (the scroll offset persists too — both
    -- are kept on leave), falling back to the active filter (header) / the first button (footer).
    local sel = state["_sel_" .. where] or (where == "header" and menu_initial_sel(state) or 1)
    state.menu = { where = where, sel = sel, ret = ret }
    api.nvim_set_current_win(state.container_win)
    local ln = where == "footer" and (state.footer_line or 1) or (state.bar_line or 1)
    pcall(api.nvim_win_set_cursor, state.container_win, { ln, 0 })
    hide_cursor(state)
    render_chrome(state)
end

--- Leave the menu and return focus to the pane it was entered from (its WinEnter restores the cursor).
--- The selection AND scroll offset of the bar are kept (not reset), so re-entering resumes where you
--- left off and the bar stays scrolled as it was.
---@param state table
local function leave_menu(state)
    if not state.menu then
        return
    end
    local ret = state.menu.ret
    state["_sel_" .. state.menu.where] = state.menu.sel
    state.menu = nil
    render_chrome(state)
    if ret and api.nvim_win_is_valid(ret) then
        api.nvim_set_current_win(ret)
    end
end

--- Move the menu selection by `delta` buttons (clamped), skipping non-interactive separators, and
--- redraw (which scrolls it into view).
---@param state table
---@param delta integer
local function menu_move(state, delta)
    if not state.menu then
        return
    end
    local btns = active_buttons(state)
    local n = #btns
    if n == 0 then
        return
    end
    local step = delta > 0 and 1 or -1
    local i = state.menu.sel
    repeat
        i = i + step
    until i < 1 or i > n or not (btns[i] and btns[i].sep) -- skip separators
    if i >= 1 and i <= n then
        state.menu.sel = i
        render_chrome(state)
    end
end

--- Activate the selected button (apply filter / run action); stays in the menu.
---@param state table
local function menu_confirm(state)
    if not state.menu then
        return
    end
    local bb = active_buttons(state)[state.menu.sel]
    if bb and not bb.sep then
        activate_button(bb.spec)
    end
end

--- Cycle focus through the sectors: header (filter bar) → center (list) → footer (actions). `dir` = 1
--- moves down, -1 up; wraps. Sectors that do not exist (header without a bar) are skipped.
---@param state table
---@param dir integer
sector_cycle = function(state, dir)
    local order = {}
    if state.bar then
        order[#order + 1] = "header"
    end
    order[#order + 1] = "center"
    order[#order + 1] = "footer"
    local cur = (state.menu and state.menu.where) or "center"
    local idx = 1
    for i, n in ipairs(order) do
        if n == cur then
            idx = i
            break
        end
    end
    local target = order[((idx - 1 + dir) % #order) + 1]
    if target == "center" then
        leave_menu(state)
    else
        enter_menu(state, target)
    end
end

--- Drag the divider between the panes with the mouse: set the list pane to an ABSOLUTE width from
--- the pointer position and re-lay-out live. Works whether the pointer is over the list or the
--- (non-focusable) preview — getmousepos() reports the window under it and the in-window column, and
--- the list keeps focus through the drag so its `<LeftDrag>` map keeps firing.
---@param state table
drag_divider = function(state)
    if not (state.list_win and api.nvim_win_is_valid(state.list_win)) then
        return
    end
    if not (state.preview_win and api.nvim_win_is_valid(state.preview_win)) then
        return
    end
    local p = state.cfg
    local m = vim.fn.getmousepos()
    local list_w = api.nvim_win_get_width(state.list_win)
    local prev_w = api.nvim_win_get_width(state.preview_win)
    local sep_w = (p.separator and p.separator ~= "") and 1 or 0
    local avail = list_w + prev_w + sep_w
    local list_left = p.list_position ~= "right"
    local new_cw
    if m.winid == state.list_win then
        new_cw = list_left and m.wincol or (list_w - m.wincol + 1)
    elseif m.winid == state.preview_win then
        new_cw = list_left and (list_w + sep_w + m.wincol) or (avail - m.wincol)
    else
        return -- pointer over the gap / a border — ignore
    end
    new_cw = math.max(8, math.min(new_cw, avail - 8))
    if new_cw ~= list_w then
        p.list_width = new_cw -- absolute (> 1): compute_layout uses it as a column count
        relayout(state)
    end
end

--- Install the list keymaps + mouse (navigation, group toggle, open actions, close).
---@param state table
local function set_keys(state)
    local p, buf = state.cfg, state.list_buf
    local manual = state.mode == "manual"
    local function map(lhs, fn)
        if lhs then
            vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    local n = #state.items_flat

    map(p.keys.down, function()
        if manual then
            state.sel = math.min((state.sel or 1) + 1, #state.rows)
        else
            state.cur = math.min(state.cur + 1, n)
        end
        refresh(state)
    end)
    map(p.keys.up, function()
        if manual then
            state.sel = math.max((state.sel or 1) - 1, (state.bar_rows or 0) + 1)
        else
            state.cur = math.max(state.cur - 1, 1)
        end
        refresh(state)
    end)
    map(p.keys.next_group, function()
        local cur_g = manual and (state.rows[state.sel] and state.rows[state.sel].gi or 1)
            or state.item_group[state.cur]
        if cur_g < #state.groups then
            toggle_group_to(state, cur_g + 1)
        end
    end)
    map(p.keys.prev_group, function()
        local cur_g = manual and (state.rows[state.sel] and state.rows[state.sel].gi or 1)
            or state.item_group[state.cur]
        if cur_g > 1 then
            toggle_group_to(state, cur_g - 1)
        end
    end)
    map(p.keys.toggle, function()
        local line = api.nvim_win_get_cursor(state.list_win)[1]
        activate(state, line, true)
    end)
    if p.keys.jump and p.keys.jump ~= p.keys.toggle then
        map(p.keys.jump, function()
            local line = api.nvim_win_get_cursor(state.list_win)[1]
            activate(state, line, true)
        end)
    end
    map(p.keys.split, function()
        do_jump(state, "split")
    end)
    map(p.keys.vsplit, function()
        do_jump(state, "vsplit")
    end)
    map(p.keys.tabedit, function()
        do_jump(state, "tabedit")
    end)
    map(p.keys.focus_preview, function()
        if api.nvim_win_is_valid(state.preview_win) then
            api.nvim_set_current_win(state.preview_win)
        end
    end)
    if state.bar then
        map(p.keys.filter, function()
            cycle_primary(state)
        end)
        -- `m` (from the list — the preview maps it too) focuses the filter bar as a keyboard menu.
        map(p.keys.focus_menu or "m", function()
            enter_menu(state, "header")
        end)
    end
    -- Sector navigation (configurable, e.g. "]" / "["): cycle header · center · footer.
    map(p.keys.sector_next or "<C-j>", function()
        sector_cycle(state, 1)
    end)
    map(p.keys.sector_prev or "<C-k>", function()
        sector_cycle(state, -1)
    end)
    -- Menu navigation on the CHROME buffer (live only while a bar — header or footer — is focused):
    -- move the selection / apply / leave, plus the sector keys so cycling continues from the menu.
    local function cmap(lhs, fn)
        for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            vim.keymap.set("n", key, fn, { buffer = state.container_buf, nowait = true, silent = true })
        end
    end
    cmap(p.keys.menu_prev or { "h", "<Left>" }, function()
        menu_move(state, -1)
    end)
    cmap(p.keys.menu_next or { "l", "<Right>" }, function()
        menu_move(state, 1)
    end)
    cmap(p.keys.menu_confirm or { "<CR>", "<Space>" }, function()
        menu_confirm(state)
    end)
    cmap(p.keys.menu_exit or { "<Esc>", "q" }, function()
        leave_menu(state)
    end)
    cmap(p.keys.sector_next or "<C-j>", function()
        sector_cycle(state, 1)
    end)
    cmap(p.keys.sector_prev or "<C-k>", function()
        sector_cycle(state, -1)
    end)
    if state.bar then
        cmap(p.keys.focus_menu or "m", function()
            leave_menu(state)
        end)
    end
    -- Caller-supplied row actions: each runs on the focused item, receiving a `close` callback so it
    -- can tear the peek down (e.g. jump elsewhere then act).
    for _, a in ipairs(state.actions or {}) do
        map(a.key, function()
            local it = focused_item(state)
            if it then
                a.run(it, function()
                    close_all(state)
                end)
            end
        end)
    end
    map(p.keys.close, function()
        close_all(state)
    end)

    -- A bar hit-test: returns (where, button, index) when the pointer `m` is over a clickable button
    -- on the header (filter) or footer (action) bar in the container window, else nil.
    local function bar_hit(m)
        if m.winid ~= state.container_win then
            return nil
        end
        local col = m.column - 1 -- 0-based byte offset into the bar line
        local function find(buttons, where)
            for i, bb in ipairs(buttons or {}) do
                if bb.c0 and col >= bb.c0 and col < bb.c1 then
                    return where, bb, i
                end
            end
        end
        if state.bar and m.line == state.bar_line then
            return find(state.bar_buttons, "header")
        end
        if m.line == state.footer_line then
            return find(state.footer_buttons, "footer")
        end
    end

    -- Mouse: a click on a header/footer button runs it; a click elsewhere in the chrome is ignored;
    -- a click in the list selects (or folds a header); double click opens.
    map("<LeftMouse>", function()
        local m = vim.fn.getmousepos()
        local where, bb = bar_hit(m)
        if where and bb and not bb.sep then
            activate_button(bb.spec)
            return
        end
        if m.winid == state.container_win then
            return
        end
        activate(state, m.line, false)
    end)
    -- Hover: tint the button under the pointer (needs 'mousemoveevent', enabled in M.open).
    map("<MouseMove>", function()
        local where, _, idx = bar_hit(vim.fn.getmousepos())
        local new = where and { where = where, idx = idx } or nil
        local changed = (state.hover ~= nil) ~= (new ~= nil)
            or (new and (state.hover.where ~= new.where or state.hover.idx ~= new.idx))
        if changed then
            state.hover = new
            render_chrome(state)
        end
    end)
    -- Keys the bar MENU owns (navigation / control): a button hotkey is NOT bound on the chrome buffer
    -- for these, so h/l/<CR>/<Esc>/q/m/<C-j>/<C-k> keep navigating / confirming / leaving the menu. The
    -- button stays reachable by selecting it + <CR>, and its key still works from the list.
    local reserved_menu = {}
    do
        local function add(v)
            for _, x in ipairs(type(v) == "table" and v or { v }) do
                reserved_menu[x] = true
            end
        end
        add(p.keys.menu_prev or { "h", "<Left>" })
        add(p.keys.menu_next or { "l", "<Right>" })
        add(p.keys.menu_confirm or { "<CR>", "<Space>" })
        add(p.keys.menu_exit or { "<Esc>", "q" })
        add(p.keys.focus_menu or "m")
        add(p.keys.sector_next or "<C-j>")
        add(p.keys.sector_prev or "<C-k>")
    end
    -- Bracket-key hotkeys, defined ONCE: each filter button's `key` works from BOTH the list (`map`)
    -- and the bar menu (`cmap`, unless the key is a reserved menu key). It applies the filter, and
    -- inside the menu also moves the selection to that button.
    if state.bar then
        for gi, g in ipairs(state.bar.groups) do
            for _, b in ipairs(g.buttons) do
                if b.key then
                    local id, key = b.id, b.key
                    local fire = function()
                        set_filter(state, gi, id)
                        if state.menu and state.menu.where == "header" then
                            for i, bb in ipairs(state.bar_buttons) do
                                if bb.spec and bb.spec.key == key then
                                    state.menu.sel = i
                                    render_chrome(state)
                                    break
                                end
                            end
                        end
                    end
                    map(b.key, fire) -- from the list
                    if not reserved_menu[b.key] then
                        cmap(b.key, fire) -- from the bar menu (unless the key navigates the menu)
                    end
                end
            end
        end
    end
    -- The footer action hotkeys (the same `footer_actions` source that builds the footer buttons) work
    -- from a bar menu too, on the chrome buffer — unless the key is a reserved menu key (those keep
    -- navigating / confirming / leaving the menu; the action is reached by selecting it + <CR>). The
    -- rest (split / preview …) run and move the footer selection.
    do
        for _, d in ipairs(footer_actions(state)) do
            if d.key and not reserved_menu[d.key] then
                local key, run = d.key, d.run
                cmap(key, function()
                    if state.menu and state.menu.where == "footer" then
                        for i, bb in ipairs(state.footer_buttons) do
                            if bb.spec and bb.spec.key == key then
                                state.menu.sel = i
                                break
                            end
                        end
                    end
                    run()
                end)
            end
        end
    end
    map("<2-LeftMouse>", function()
        local m = vim.fn.getmousepos()
        activate(state, m.line, true)
    end)
    -- Drag the boundary between the panes to resize the split live.
    map("<LeftDrag>", function()
        drag_divider(state)
    end)

    api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.list_win),
        once = true,
        callback = function()
            close_all(state)
        end,
    })
    -- Focus may move freely BETWEEN the panes (list ↔ preview); the panel only tears down when
    -- focus lands on a window that is NOT part of it, so it never lingers unfocused.
    state.augroup = api.nvim_create_augroup("LvimUiPeek_" .. state.list_win, { clear = true })
    api.nvim_create_autocmd("WinEnter", {
        group = state.augroup,
        callback = function()
            local w = api.nvim_get_current_win()
            -- Focus reached a CONTENT pane (e.g. via the footer's preview action / C-l-C-h): we left the
            -- bar, so drop any menu selection + hover and redraw the chrome to clear their highlight.
            local function leave_bars()
                if state.menu or state.hover then
                    state.menu, state.hover = nil, nil
                    render_chrome(state)
                end
            end
            if w == state.list_win then
                leave_bars()
                -- Returning to the list re-centres the preview on the focused location (it may
                -- have been scrolled away while the preview pane was focused).
                hide_cursor(state)
                update_preview(state)
            elseif w == state.preview_win then
                leave_bars()
                show_cursor(state)
            elseif w ~= state.container_win then
                close_all(state)
            end
        end,
    })
    -- Re-lay-out the whole panel on terminal/window resize (all four windows updated in place).
    api.nvim_create_autocmd("VimResized", {
        group = state.augroup,
        callback = function()
            relayout(state)
        end,
    })
end

--- Move focus to group `gi` (auto: its first item; manual: its header row).
---@param state table
---@param gi integer
toggle_group_to = function(state, gi)
    if state.mode == "manual" then
        state.expanded[gi] = true
        refresh(state)
        for line, row in ipairs(state.rows) do
            if row.kind == "header" and row.gi == gi then
                state.sel = line
                break
            end
        end
        refresh(state)
    else
        state.cur = group_first(state, gi)
        refresh(state)
    end
end

--- Build the HEADER filter bar's entries for `ui.bar`: one `label` button per group option (`[X]abel
--- N`, key=accent, label/count follow active/inactive, live count, `run` = apply the filter) plus a
--- `●` separator between groups. The active option carries `active = true`.
---@param state table
---@return table[]  -- ui.bar entries (button specs + separators)
local function build_filter_buttons(state)
    local barcfg = state.bar
    local entries = {}
    for gi, g in ipairs(barcfg.groups) do
        if gi > 1 then
            entries[#entries + 1] = { separator = "●", hl = "LvimUiPeekFilterSep", pad = "   " }
        end
        for _, b in ipairs(g.buttons) do
            local count = 0
            for _, it in ipairs(state.all_items) do
                if passes_bar(barcfg, it, g) and (not b.predicate or b.predicate(it)) then
                    count = count + 1
                end
            end
            local accent = b.hl_active or "LvimUiPeekFilterActive"
            local dim = b.hl or "LvimUiPeekFilterInactive"
            entries[#entries + 1] = {
                type = "label",
                label = b.label,
                count = count,
                key = b.key, -- so the hotkey works from inside the bar menu too (set on the chrome buffer)
                accent = accent, -- the button's "own colour" — its hover/select bg is a tint of this
                active = b.id == g.active,
                primary = g.primary, -- the menu's initial selection prefers the PRIMARY group's active one
                run = function()
                    set_filter(state, gi, b.id)
                end,
                hl = {
                    -- the [X] key is always the accent; the label + count follow active / inactive.
                    -- hover == normal here: the header's hover is a separate bg overlay (place_bar).
                    normal = { key = accent, label = dim, count = dim },
                    active = { key = accent, label = accent, count = accent },
                    hover = { key = accent, label = dim, count = dim },
                },
            }
        end
    end
    return entries
end

--- The footer ACTION definitions — the SINGLE source for both the footer buttons and the footer
--- bar-menu hotkeys (key + action declared once). Each = { key, name, run }.
---@param state table
---@return table[]
footer_actions = function(state)
    local k = state.cfg.keys or {}
    local defs = {
        {
            key = k.jump or "<CR>",
            name = "open",
            run = function()
                do_jump(state, "edit")
            end,
        },
        {
            key = k.split or "s",
            name = "split",
            run = function()
                do_jump(state, "split")
            end,
        },
        {
            key = k.focus_preview or "<C-l>",
            name = "preview",
            run = function()
                if state.preview_win and api.nvim_win_is_valid(state.preview_win) then
                    api.nvim_set_current_win(state.preview_win)
                end
            end,
        },
    }
    if state.bar then
        -- The `menu` button TOGGLES on the same key: it opens the header menu from the list/footer and
        -- reads "menu"; while a menu is focused the key leaves it, so it reads "back".
        defs[#defs + 1] = {
            key = k.focus_menu or "m",
            name = state.menu and "back" or "menu",
            run = function()
                if state.menu then
                    leave_menu(state)
                else
                    enter_menu(state, "header")
                end
            end,
        }
    end
    defs[#defs + 1] = {
        key = k.close or "q",
        name = "close",
        run = function()
            close_all(state)
        end,
    }
    return defs
end

--- Build the FOOTER action bar's entries for `ui.bar` from `footer_actions` (` <key>  name ` buttons).
---@param state table
---@return table[]  -- ui.bar entries (action button specs)
local function build_action_buttons(state)
    -- hover keeps each part's colour and only deepens its bg tint (≈ +0.1) — a per-segment state.
    local hl = {
        normal = { key = "LvimUiPeekFooterKey", name = "LvimUiPeekFooterLabel" },
        active = { key = "LvimUiPeekFooterKey", name = "LvimUiPeekFooterLabel" },
        hover = { key = "LvimUiPeekFooterKeyHover", name = "LvimUiPeekFooterLabelHover" },
    }
    local entries = {}
    for _, d in ipairs(footer_actions(state)) do
        entries[#entries + 1] = { type = "action", key = d.key, name = d.name, run = d.run, hl = hl }
    end
    return entries
end

--- Render the container chrome buffer: the centred filter bar on content row 2 (when `state.bar`), the
--- action footer bar on the last content row, and a divider at `sep_col` on the pane rows between them.
--- Each bar is composed by `compose_bar` (centre / scroll + chevrons) and carries the menu selection +
--- hover highlights. Dimensions are remembered on `state._chrome` so a redraw needs no relayout.
---@param state table
---@param W? integer       defaults to the stored value (filter-change redraws pass nothing)
---@param H? integer
---@param sep_col? integer 0-based divider column
---@param sep_char? string
render_chrome = function(state, W, H, sep_col, sep_char)
    local c = state._chrome or {}
    W, H = W or c.W, H or c.H
    if sep_col == nil then
        sep_col = c.sep_col
    end
    sep_char = sep_char or c.sep_char
    state._chrome = { W = W, H = H, sep_col = sep_col, sep_char = sep_char }
    sep_char = (sep_col and sep_char and sep_char ~= "") and sep_char or nil

    local has_bar = state.bar ~= nil
    local function base_line(with_sep)
        if with_sep and sep_char then
            local cells = {}
            for col = 0, W - 1 do
                cells[col + 1] = (col == sep_col) and sep_char or " "
            end
            return table.concat(cells)
        end
        return string.rep(" ", W)
    end
    -- Header rows 1 (spacer) & 2 (filter bar, when present) and the LAST content row (action footer,
    -- when enabled) span the full width — no divider; the panes occupy the rows between them.
    local has_footer = state.cfg.footer ~= false
    local bar_ln = 2
    local footer_ln = has_footer and H or nil
    local lines = {}
    for i = 1, H do
        local full = (has_bar and i <= bar_ln) or i == footer_ln
        lines[i] = base_line(not full)
    end

    -- Both bars go through the shared `ui.bar` primitive (centre / scroll + chevrons + per-button
    -- state); the peek only supplies button specs and draws its own selection / hover overlays.
    state.bar_buttons, state.footer_buttons = {}, {}
    state.bar_line = has_bar and bar_ln or nil
    state.footer_line = footer_ln or nil

    --- Render `entries` through `ui.bar` into `lines[ln]`, record per-button rows into `dest`, return
    --- the placement data (hl spans + chevron ranges) for after the buffer write.
    local function lay_bar(ln, entries, off_field, where, dest)
        local sel = (state.menu and state.menu.where == where) and state.menu.sel or nil
        -- The footer keeps each part's colour for BOTH highlight kinds via its per-segment button
        -- state: the keyboard-selected button (in the footer menu) OR the mouse-hovered one render in
        -- the "hover" state, so the footer never gets a flat uniform overlay. The header still uses bg
        -- overlays (its filter buttons are fg-only, so a uniform tint is fine there).
        local hover
        if where == "footer" then
            hover = sel or (state.hover and state.hover.where == "footer" and state.hover.idx) or nil
        end
        local res = uibar.render({
            buttons = entries,
            width = W,
            align = "center",
            chevrons = state.cfg.chevrons,
            sel = sel,
            hover = hover,
            off = state[off_field],
        })
        state[off_field] = res.off
        lines[ln] = res.line
        for i, b in ipairs(res.buttons) do
            dest[i] = { row = ln, c0 = b.c0, c1 = b.c1, spec = b.spec, sep = b.sep }
        end
        return res.spans, res.chevrons
    end

    local header_spans, header_chev, footer_spans, footer_chev
    if has_bar then
        header_spans, header_chev =
            lay_bar(bar_ln, build_filter_buttons(state), "_bar_off", "header", state.bar_buttons)
    end
    if footer_ln then
        footer_spans, footer_chev =
            lay_bar(footer_ln, build_action_buttons(state), "_footer_off", "footer", state.footer_buttons)
    end

    vim.bo[state.container_buf].modifiable = true
    api.nvim_buf_set_lines(state.container_buf, 0, -1, false, lines)
    vim.bo[state.container_buf].modifiable = false
    api.nvim_buf_clear_namespace(state.container_buf, NS_CHROME, 0, -1)

    -- Place a bar's highlights: the selection bg (menu) and hover bg drawn UNDER the fg spans (lower
    -- priority, so the button keeps its colours), then the fg spans, then the overflow chevrons.
    local function place_bar(ln, where, buttons, spans, chev, chev_hl)
        -- Selection / hover bg for the HEADER (bg-only, keeps each segment's fg). Each is a TINT of the
        -- focused button's OWN accent colour, and extends ONE column past the text on each side (into
        -- the inter-button gap) so the highlight does not hug the glyphs. The footer keeps its colours
        -- via its per-segment button state (see lay_bar), so it gets no overlay here.
        local function header_bg(bb, t, out, fallback, priority)
            if not (bb and bb.c0 and not bb.sep) then
                return
            end
            local group = tint_hl(bb.spec and bb.spec.accent, t, out) or fallback
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, ln - 1, math.max(0, bb.c0 - 1), {
                end_col = bb.c1 + 1, -- 1 space of padding on each side
                hl_group = group,
                priority = priority,
            })
        end
        if where ~= "footer" and state.menu and state.menu.where == where then
            header_bg(buttons[state.menu.sel], 0.3, "LvimUiPeekHeaderSel", "LvimUiPeekFilterSelected", 250)
        end
        if where ~= "footer" and state.hover and state.hover.where == where then
            header_bg(buttons[state.hover.idx], 0.18, "LvimUiPeekHeaderHover", "LvimUiPeekHover", 240)
        end
        for _, s in ipairs(spans or {}) do
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, ln - 1, s[1], {
                end_col = s[2],
                hl_group = s[3],
                priority = 200,
            })
        end
        for _, ch in ipairs(chev or {}) do
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, ln - 1, ch[1], {
                end_col = ch[2],
                hl_group = chev_hl,
                priority = 200,
            })
        end
    end
    if has_bar then
        place_bar(bar_ln, "header", state.bar_buttons, header_spans, header_chev, "LvimUiPeekFilterChevron")
    end
    if footer_ln then
        place_bar(footer_ln, "footer", state.footer_buttons, footer_spans, footer_chev, "LvimUiPeekFooterChevron")
    end

    if sep_char then
        local from = has_bar and bar_ln or 0
        local to = footer_ln and (footer_ln - 2) or (H - 1) -- pane rows only (skip the footer row)
        for ln = from, to do
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, ln, sep_col, {
                end_col = sep_col + #sep_char,
                hl_group = "LvimUiPeekBorder",
            })
        end
    end
end

--- Pure geometry: compute every rect of the panel from the CURRENT `vim.o.columns`/`vim.o.lines`
--- (no window/buffer side effects), so both the initial open and the resize relayout share one
--- source of truth. Returns the container frame + insets, the two inner-pane rects, and the
--- optional divider column.
---@param state table
---@return table layout
local function compute_layout(state)
    local p = state.cfg
    local fl = p.float or {}

    local W, H, row, col
    if p.mode == "float" then
        W = (fl.width or 0.85) <= 1 and math.floor(vim.o.columns * (fl.width or 0.85)) or math.floor(fl.width)
        H = (fl.height or 0.8) <= 1 and math.floor(vim.o.lines * (fl.height or 0.8)) or math.floor(fl.height)
        row = math.max(1, math.floor((vim.o.lines - H) / 2 - 1))
        col = math.max(1, math.floor((vim.o.columns - W) / 2))
    else
        -- Bottom-docked, full width. `row`/`col` are the BORDER's top-left, so subtract the
        -- container's own border insets from width/height to keep the whole frame on screen
        -- (otherwise the right/bottom border falls past the last column/row and vanishes).
        local ct0, cr0, cbb0, cl0 = insets(util.resolve_border(p.border))
        W = vim.o.columns - cl0 - cr0
        H = (p.preview_height or 16)
        col = 0
        row = math.max(1, vim.o.lines - H - ct0 - cbb0 - 1)
    end

    local cbord = util.resolve_border(p.border)
    local ct, cr, cb, cl = insets(cbord)
    -- Container CONTENT area (border drawn at row/col, content inset by the top/left border).
    local cc_row, cc_col = row + ct, col + cl

    -- Each inner pane's own border insets (every side from config).
    local lb = util.resolve_border(p.list_border)
    local pb = util.resolve_border(p.preview_border)
    local lt, lr, lbm, ll = insets(lb)
    local pt, pr, pbm, pl = insets(pb)

    -- One optional divider column between the panes (drawn in the container behind the gap).
    local sep_w = (p.separator and p.separator ~= "") and 1 or 0

    -- Split the content width into the two panes after subtracting every inner border column and
    -- the divider column.
    local avail = math.max(16, W - (ll + lr + pl + pr) - sep_w)
    local list_cw = p.list_width <= 1 and math.floor(avail * p.list_width) or math.floor(p.list_width)
    list_cw = math.max(8, math.min(list_cw, avail - 8))
    local prev_cw = avail - list_cw

    -- A filter bar takes two content rows at the TOP (blank spacer + the bar); the action footer bar
    -- takes one row at the BOTTOM. The panes start below the header and lose both to height.
    local bar_h = state.bar and 2 or 0
    local footer_h = p.footer ~= false and 1 or 0
    local inner_top = cc_row + bar_h
    local list_h = math.max(1, H - bar_h - footer_h - lt - lbm)
    local prev_h = math.max(1, H - bar_h - footer_h - pt - pbm)
    local list_left = p.list_position ~= "right"
    -- Footprints lay out left→right: [first pane][divider][second pane]. Each pane's nvim col is
    -- its LEFT-BORDER position; the divider sits in the gap (a column the panes don't cover).
    local left_w = (list_left and (ll + list_cw + lr) or (pl + prev_cw + pr))
    local right_x = cc_col + left_w + sep_w
    local list_x = list_left and cc_col or right_x
    local prev_x = list_left and right_x or cc_col

    return {
        W = W,
        H = H,
        row = row,
        col = col,
        cbord = cbord,
        ct = ct,
        cb = cb,
        sep_col = sep_w > 0 and left_w or nil, -- buffer-relative divider column
        list = { width = list_cw, height = list_h, row = inner_top, col = list_x, border = lb },
        preview = { width = prev_cw, height = prev_h, row = inner_top, col = prev_x, border = pb },
    }
end

--- The container's float config from a computed layout (border, frame, brand title). The footer is a
--- content row rendered by render_chrome, not a border footer.
---@param state table
---@param L table
---@return table copts
local function container_config(state, L)
    local copts = {
        relative = "editor",
        width = L.W,
        height = L.H,
        row = L.row,
        col = L.col,
        border = L.cbord,
        style = "minimal",
        focusable = false,
        zindex = state.zindex,
    }
    -- The panel brand title rides the container's top border (when it has one).
    if L.ct > 0 then
        copts.title = { { " " .. (state.cfg.title or "LVIM LSP") .. " ", "LvimUiPeekTitle" } }
        copts.title_pos = "center"
    end
    return copts
end

--- Build the panel: a MAIN container plus two inner panes (list | preview). All THREE borders are
--- read from config (`border`, `list_border`, `preview_border`) — every side honoured. The title
--- rides the container's top border when it has one. The preview is non-focusable. "float" centres
--- the panel; "split" docks it across the bottom; an optional backdrop sits behind.
---@param state table
local function open_panel(state)
    local p = state.cfg
    local fl = p.float or {}
    state.zindex = fl.zindex or 50
    local L = compute_layout(state)

    if p.mode == "float" and fl.backdrop then
        state.backdrop_buf = api.nvim_create_buf(false, true)
        state.backdrop_win = api.nvim_open_win(state.backdrop_buf, false, {
            relative = "editor",
            width = vim.o.columns,
            height = vim.o.lines,
            row = 0,
            col = 0,
            style = "minimal",
            focusable = false,
            zindex = state.zindex - 1,
        })
        vim.wo[state.backdrop_win].winblend = fl.backdrop_blend or 40
        vim.wo[state.backdrop_win].winhighlight = "Normal:LvimUiPeekCursorLine"
    end

    state.container_buf = api.nvim_create_buf(false, true)
    local copts = container_config(state, L)
    state.container_win = api.nvim_open_win(state.container_buf, false, copts)
    vim.wo[state.container_win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"
    vim.wo[state.container_win].winbar = ""

    -- The action footer + filter bar are rendered as content rows inside the container buffer (so they
    -- are focusable / clickable), not on the border.
    render_chrome(state, L.W, L.H, L.sep_col, p.separator)

    state.list_win = api.nvim_open_win(state.list_buf, true, {
        relative = "editor",
        width = L.list.width,
        height = L.list.height,
        row = L.list.row,
        col = L.list.col,
        border = L.list.border,
        style = "minimal",
        zindex = state.zindex + 1,
    })
    -- The list winbar (kind + filtered count) is set by refresh(), so it tracks live filtering.
    local prev_buf = api.nvim_create_buf(false, true)
    state.preview_win = api.nvim_open_win(prev_buf, false, {
        relative = "editor",
        width = L.preview.width,
        height = L.preview.height,
        row = L.preview.row,
        col = L.preview.col,
        border = L.preview.border,
        style = "minimal",
        zindex = state.zindex + 1,
    })
end

--- Recompute the layout against the current screen size and re-place every window IN PLACE
--- (`nvim_win_set_config`, so window ids stay stable and the WinClosed teardown never fires).
--- Bound to VimResized; re-renders the chrome, footer and list afterwards.
---@param state table
relayout = function(state)
    if not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local p = state.cfg
    local L = compute_layout(state)
    if state.backdrop_win and api.nvim_win_is_valid(state.backdrop_win) then
        pcall(api.nvim_win_set_config, state.backdrop_win, {
            relative = "editor",
            width = vim.o.columns,
            height = vim.o.lines,
            row = 0,
            col = 0,
        })
    end
    pcall(api.nvim_win_set_config, state.container_win, container_config(state, L))
    if state.list_win and api.nvim_win_is_valid(state.list_win) then
        pcall(api.nvim_win_set_config, state.list_win, {
            relative = "editor",
            width = L.list.width,
            height = L.list.height,
            row = L.list.row,
            col = L.list.col,
            border = L.list.border,
        })
    end
    if state.preview_win and api.nvim_win_is_valid(state.preview_win) then
        pcall(api.nvim_win_set_config, state.preview_win, {
            relative = "editor",
            width = L.preview.width,
            height = L.preview.height,
            row = L.preview.row,
            col = L.preview.col,
            border = L.preview.border,
        })
    end
    render_chrome(state, L.W, L.H, L.sep_col, p.separator)
    refresh(state)
end

--- Open a peek window over `opts.items`.
---@param opts { title?: string, items: LvimUiPeekItem[], mode?: string, bar?: LvimUiPeekBar, list_match?: boolean, actions?: { key: string, desc?: string, run: fun(item: LvimUiPeekItem, close: fun()) }[], on_jump?: fun(item: LvimUiPeekItem, cmd: string) }
---@param instance_cfg? table
---@return boolean opened  false when there were no items
function M.open(opts, instance_cfg)
    opts = opts or {}
    if not opts.items or #opts.items == 0 then
        return false
    end
    local p = resolve_cfg(instance_cfg, opts)

    local state = {
        cfg = p,
        on_jump = opts.on_jump,
        mode = p.expand == "manual" and "manual" or "auto",
        all_items = opts.items, -- the full, unfiltered set; the bar filters this into the model
        bar = opts.bar, -- optional filter/subtitle bar (nil = a plain locations peek)
        -- Highlight the match range inside each list row. True when rows are SOURCE LINES (locations);
        -- diagnostics pass false because their rows are messages, where col/end_col are meaningless.
        list_match = opts.list_match ~= false,
        actions = opts.actions, -- optional caller row actions: { { key, desc, run = fun(item, close) } }
        origin = api.nvim_get_current_win(),
        list_buf = api.nvim_create_buf(false, true),
    }
    vim.bo[state.list_buf].filetype = "lvim-utils-peek"
    vim.bo[state.list_buf].bufhidden = "wipe"
    -- Enable mouse-move events for the button hover tint (restored on close).
    state.saved_mousemove = vim.o.mousemoveevent
    vim.o.mousemoveevent = true
    -- Build the (filtered) model and place the initial selection.
    apply_filter(state)

    -- `p.title` is the panel BRAND on the container border (config "LVIM LSP"); `opts.title` is the
    -- per-call KIND shown in the list winbar with the count (e.g. "References").
    p.title = p.title or "LVIM LSP"
    state.kind = opts.title or p.title
    open_panel(state)

    dress(state.list_win, true)
    dress(state.preview_win, false)

    set_keys(state)
    api.nvim_set_current_win(state.list_win)
    -- The list opens focused; hide the hardware cursor there (WinEnter won't fire for the window
    -- that is already current when the autocmd is installed).
    hide_cursor(state)
    refresh(state)
    return true
end

return M
