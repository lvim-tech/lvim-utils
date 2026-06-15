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

local M = {}

local NS_LIST = api.nvim_create_namespace("LvimUiPeekList")
local NS_PREV = api.nvim_create_namespace("LvimUiPeekPreview")
local NS_CHROME = api.nvim_create_namespace("LvimUiPeekChrome")

-- Forward declaration: tear the panel down (defined below; referenced by update_preview's keys).
---@type fun(state: table)
local close_all

-- Forward declaration: swap the bottom-border footer to a pane's hints (defined below open_panel;
-- referenced by the WinEnter autocmd in set_keys, which is defined earlier).
---@type fun(state: table, pane: "list"|"preview")
local set_footer

-- Forward declaration: recompute geometry and re-place the panes in place (defined after
-- open_panel; referenced by the VimResized autocmd in set_keys, which is defined earlier).
---@type fun(state: table)
local relayout

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
---@field label     string                         button caption
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
    state.bar_rows = state.bar and 1 or 0
    if state.mode == "manual" then
        state.sel = state.bar_rows + ((#state.groups > 0 and #state.groups[1].items > 0) and 2 or 1)
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
    -- Preview winbar (full width): the file name first, then its directory path.
    local rel = vim.fn.fnamemodify(it.filename, ":~:.")
    local tail = vim.fn.fnamemodify(it.filename, ":t")
    local dir = vim.fn.fnamemodify(rel, ":h")
    local wb = "%#LvimUiPeekFile# " .. tail .. " "
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
        pmap(p.keys.close, function()
            close_all(state)
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

--- Build the filter-bar subtitle row: one badge per button (`label count`), STRONG tint when
--- active, light otherwise (or the button's own `hl`/`hl_active`). Returns the line text, its
--- highlight spans, and the clickable button regions (byte ranges) for mouse hit-testing.
---@param state table
---@return string text, table spans, table buttons  buttons = { {c0, c1, group_idx, button_id} }
local function build_bar_row(state)
    local bar = state.bar
    local text, spans, buttons = "", {}, {}
    local function put(s, hl)
        if s ~= "" and hl then
            spans[#spans + 1] = { #text, #text + #s, hl }
        end
        text = text .. s
    end
    for gi, g in ipairs(bar.groups) do
        if gi > 1 then
            put("  ", nil) -- gap between groups
        end
        for bi, b in ipairs(g.buttons) do
            if bi > 1 then
                put(" ", nil) -- gap between buttons of one group
            end
            local count = 0
            for _, it in ipairs(state.all_items) do
                if passes_bar(bar, it, g) and (not b.predicate or b.predicate(it)) then
                    count = count + 1
                end
            end
            local on = b.id == g.active
            local hl = on and (b.hl_active or "LvimUiPeekFilterActive") or (b.hl or "LvimUiPeekFilterInactive")
            local badge = " " .. b.label .. " " .. count .. " "
            local c0 = #text
            put(badge, hl)
            buttons[#buttons + 1] = { c0, #text, gi, b.id }
        end
    end
    return text, spans, buttons
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
    -- Filter bar (subtitle) pinned as row 1 when present; record its clickable button regions.
    state.bar_buttons = {}
    if state.bar then
        local btext, bspans, bbtns = build_bar_row(state)
        texts[1], spans[1], rows[1] = btext, bspans, { kind = "filter" }
        for _, bb in ipairs(bbtns) do
            state.bar_buttons[#state.bar_buttons + 1] = { row = 1, c0 = bb[1], c1 = bb[2], gi = bb[3], id = bb[4] }
        end
    end
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
                -- … ) shows its match in both panes. Cols are 1-based on the ORIGINAL line, so
                -- subtract the stripped indent and add the row prefix. A same-line `end_col` gives an
                -- exact range; a multi-line match runs to the end of the shown text; a bare position
                -- (no `end_col`, as some definitions return) falls back to a single cell.
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

    -- List winbar: kind + the (filtered) count, e.g. "Diagnostics (5)".
    if api.nvim_win_is_valid(state.list_win) then
        vim.wo[state.list_win].winbar = "%#LvimUiPeekKind# "
            .. (state.kind or "Locations")
            .. " %#LvimUiPeekKindBar# ("
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
    end
    map(p.keys.close, function()
        close_all(state)
    end)

    -- Mouse: a click on the filter row toggles the button under the pointer; otherwise single click
    -- selects (or folds a header) and double click opens an item.
    map("<LeftMouse>", function()
        local m = vim.fn.getmousepos()
        if state.bar and m.winid == state.list_win and m.line == 1 then
            local col = m.column - 1 -- 0-based byte offset into the bar line
            for _, bb in ipairs(state.bar_buttons or {}) do
                if col >= bb.c0 and col < bb.c1 then
                    set_filter(state, bb.gi, bb.id)
                    return
                end
            end
            return
        end
        activate(state, m.line, false)
    end)
    map("<2-LeftMouse>", function()
        local m = vim.fn.getmousepos()
        activate(state, m.line, true)
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
            if w == state.list_win then
                -- Returning to the list re-centres the preview on the focused location (it may
                -- have been scrolled away while the preview pane was focused).
                hide_cursor(state)
                set_footer(state, "list")
                update_preview(state)
            elseif w == state.preview_win then
                show_cursor(state)
                set_footer(state, "preview")
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

--- Render the container chrome buffer: a centred title header row (only when `title` is given —
--- i.e. the container border has no top to carry it) and a full-height divider at `sep_col` (the
--- inner panes leave exactly that column visible). The rest is just the panel background.
---@param state table
---@param W integer
---@param H integer
---@param title string|nil
---@param sep_col integer|nil  0-based divider column
---@param sep_char string|nil
local function render_chrome(state, W, H, title, sep_col, sep_char)
    sep_char = (sep_col and sep_char and sep_char ~= "") and sep_char or nil
    local base
    if sep_col and sep_char then
        local cells = {}
        for c = 0, W - 1 do
            cells[c + 1] = (c == sep_col) and sep_char or " "
        end
        base = table.concat(cells)
    else
        base = string.rep(" ", W)
    end
    local lines = {}
    for _ = 1, H do
        lines[#lines + 1] = base
    end
    local t, pad
    if title then
        t = " " .. title .. " "
        pad = math.max(0, math.floor((W - vim.fn.strdisplaywidth(t)) / 2))
        lines[1] = (string.rep(" ", pad) .. t .. string.rep(" ", W)):sub(1, W + #t)
    end
    vim.bo[state.container_buf].modifiable = true
    api.nvim_buf_set_lines(state.container_buf, 0, -1, false, lines)
    vim.bo[state.container_buf].modifiable = false
    api.nvim_buf_clear_namespace(state.container_buf, NS_CHROME, 0, -1)
    if title then
        pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, 0, pad, {
            end_col = pad + #t,
            hl_group = "LvimUiPeekTitle",
        })
    end
    if sep_col and sep_char then
        local from = title and 1 or 0
        for ln = from, H - 1 do
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS_CHROME, ln, sep_col, {
                end_col = sep_col + #sep_char,
                hl_group = "LvimUiPeekBorder",
            })
        end
    end
end

--- Build the focus-aware key-hint footer for the container's bottom border. The list pane shows the
--- full set (navigate / group / open / split / focus preview / close); the preview shows just the
--- way back and close — so the border always advertises exactly what the focused pane can do.
---@param state table
---@param pane "list"|"preview"
---@return table[]  nvim border-footer chunks ({ text, hl_group })
local function footer_chunks(state, pane)
    local k = state.cfg.keys or {}
    ---@type table[]  list of { keys, label }
    local hints
    if pane == "preview" then
        hints = {
            { k.focus_list or "<C-h>", "list" },
            { k.close or "q", "close" },
        }
    else
        hints = {
            { (k.down or "j") .. "/" .. (k.up or "k"), "move" },
            { k.next_group or "<Tab>", "group" },
            { k.jump or "<CR>", "open" },
            { (k.split or "s") .. "/" .. (k.vsplit or "v") .. "/" .. (k.tabedit or "t"), "split" },
            { k.focus_preview or "<C-l>", "preview" },
            { k.close or "q", "close" },
        }
    end
    local chunks = {}
    for i, h in ipairs(hints) do
        chunks[#chunks + 1] = { " " .. h[1] .. " ", "LvimUiPeekFooterKey" }
        chunks[#chunks + 1] = { " " .. h[2] .. " ", "LvimUiPeekFooterLabel" }
        if i < #hints then
            chunks[#chunks + 1] = { " ", "LvimUiPeekNormal" }
        end
    end
    return chunks
end

--- Swap the container's bottom-border footer to the focused pane's hints. No-op when the footer is
--- disabled or the container border has no bottom side to carry it.
---@param state table
---@param pane "list"|"preview"
set_footer = function(state, pane)
    if not state.footer_ok or not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    pcall(api.nvim_win_set_config, state.container_win, {
        footer = footer_chunks(state, pane),
        footer_pos = "center",
    })
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

    local list_h = math.max(1, H - lt - lbm)
    local prev_h = math.max(1, H - pt - pbm)
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
        list = { width = list_cw, height = list_h, row = cc_row, col = list_x, border = lb },
        preview = { width = prev_cw, height = prev_h, row = cc_row, col = prev_x, border = pb },
    }
end

--- The container's float config from a computed layout (border, frame, brand title — the footer is
--- applied separately by set_footer so it can follow the focused pane).
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
    -- The key-hint footer rides the container's BOTTOM border (needs one). The list opens focused,
    -- so it starts on the list hints; WinEnter swaps it to the preview set and back.
    state.footer_ok = p.footer ~= false and L.cb > 0
    if state.footer_ok then
        copts.footer = footer_chunks(state, "list")
        copts.footer_pos = "center"
    end
    state.container_win = api.nvim_open_win(state.container_buf, false, copts)
    vim.wo[state.container_win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"
    vim.wo[state.container_win].winbar = ""

    render_chrome(state, L.W, L.H, nil, L.sep_col, p.separator)

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
    render_chrome(state, L.W, L.H, nil, L.sep_col, p.separator)
    if state.footer_ok then
        set_footer(state, api.nvim_get_current_win() == state.preview_win and "preview" or "list")
    end
    refresh(state)
end

--- Open a peek window over `opts.items`.
---@param opts { title?: string, items: LvimUiPeekItem[], mode?: string, bar?: LvimUiPeekBar, on_jump?: fun(item: LvimUiPeekItem, cmd: string) }
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
        origin = api.nvim_get_current_win(),
        list_buf = api.nvim_create_buf(false, true),
    }
    vim.bo[state.list_buf].filetype = "lvim-utils-peek"
    vim.bo[state.list_buf].bufhidden = "wipe"
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
