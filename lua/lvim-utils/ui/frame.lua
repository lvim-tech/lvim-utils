-- lvim-utils.ui.frame: the ONE windowed-UI chassis. A vertical stack of sectors —
--
--     header  (a STACK of bands: meta lines + ui.bar bars; PINNED, never scrolls)
--     center  (a horizontal row of 1..N panels, each a content provider; the ONLY scroll region)
--     footer  (a STACK of bands, usually one ui.bar of actions; PINNED, never scrolls)
--
-- Everything else in the UI is a `frame` config: a popup is 1 center panel, the peek is 2 (list +
-- preview), a git client is 3 (status · diff · log); the header stack carries tabs / filters / submenus
-- (Package Manager); the footer is the navigable action bar. The chrome (header bands, footer bands,
-- the divider columns between panels) is rendered into a single non-focusable CONTAINER buffer so it
-- stays pinned; the center panels are separate floating windows on top, so only they scroll.
--
-- Sizing is per axis: `auto_width`/`auto_height` fit the content (capped by `max_width`/`max_height`),
-- else the explicit `width`/`height` (fraction of the screen, or absolute) is used.
--
-- This file (Stage 1) renders a frame; sector navigation + provider key dispatch land in the next layer.
--
---@module "lvim-utils.ui.frame"

local uibar = require("lvim-utils.ui.bar")
local util = require("lvim-utils.ui.util")

local api = vim.api
local NS = api.nvim_create_namespace("lvim_utils_ui_frame")

local M = {}

-- ─── cursor hiding (bar-menu mode) ────────────────────────────────────────────
-- While a header/footer BAR sector is focused there is no text cursor to show — the selected button
-- is the cursor — so hide the hardware cursor (transparent 1-cell bar via a blend=100 group, the same
-- technique as lvim-utils.cursor) and restore it the moment focus returns to a panel.

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

-- Default keymaps for the chassis; the consumer may override via `cfg.keys`.
local DEFAULT_KEYS = {
    sector_next = "<C-j>",
    sector_prev = "<C-k>",
    menu_prev = { "h", "<Left>" },
    menu_next = { "l", "<Right>" },
    menu_confirm = { "<CR>", "<Space>" },
}

-- ─── config normalisation ─────────────────────────────────────────────────────

--- Map `{ key, name, run }` action defs to ui.button "action" specs for a footer bar band.
---@param actions table[]
---@return LvimUiButtonSpec[]
local function action_buttons(actions)
    local specs = {}
    for i, a in ipairs(actions or {}) do
        local set = { key = a.key_hl or "LvimUiFooterKey", name = a.label_hl or "LvimUiFooterLabel" }
        specs[i] = {
            type = "action",
            key = a.key,
            name = a.name or a.label or "",
            run = a.run,
            hl = { normal = set, active = set, hover = set },
        }
    end
    return specs
end

--- Build the header band stack: optional title/subtitle/info META lines, then any explicit bands.
--- A band is `{ meta = text, hl }` (a centred line) or `{ buttons = LvimUiButtonSpec[], align }` (a bar).
---@param h table|nil
---@return table[]
local function header_bands(h)
    h = h or {}
    local bands = {}
    if h.title then
        bands[#bands + 1] = { meta = h.title, hl = h.title_hl or "LvimUiPeekTitle" }
    end
    if h.subtitle then
        bands[#bands + 1] = { meta = h.subtitle, hl = h.subtitle_hl or "LvimUiSubtitle" }
    end
    if h.info then
        bands[#bands + 1] = { meta = h.info, hl = h.info_hl or "LvimUiInfo" }
    end
    for _, b in ipairs(h.bands or {}) do
        bands[#bands + 1] = b
    end
    return bands
end

--- Build the footer band stack: an `actions` shorthand becomes one bar band, then any explicit bands.
---@param f table|nil
---@return table[]
local function footer_bands(f)
    f = f or {}
    local bands = {}
    if f.actions then
        bands[#bands + 1] = { buttons = action_buttons(f.actions), align = f.align or "center" }
    end
    for _, b in ipairs(f.bands or {}) do
        bands[#bands + 1] = b
    end
    return bands
end

-- ─── geometry ─────────────────────────────────────────────────────────────────

--- Pure geometry: the container frame, the header/footer band rows, and every center-panel rect + the
--- divider columns. No window/buffer side effects. `place` overrides position/size for a SPLIT (docked)
--- frame whose container window already exists: `{ row, col, H }` (screen position + the split height).
---@param state table
---@param place? table
---@return table layout
local function compute_geom(state, place)
    local cfg = state.cfg
    -- A docked split container draws no border (its edge is the split divider); a float uses cfg.border.
    local cbord = place and util.resolve_border("none") or util.resolve_border(cfg.border)
    local ct, _, _, cl = util.insets(cbord)

    local panels = state.panels
    local n = #panels
    local sep_w = (cfg.separator and cfg.separator ~= "") and 1 or 0

    -- Per-panel border insets + natural content size (provider.size()).
    local pin = {}
    local nat_w_sum, nat_h_max, border_cols = 0, 1, 0
    for i, pan in ipairs(panels) do
        local b = util.resolve_border(pan.border or cfg.panel_border)
        local pt, pr, pbm, pl = util.insets(b)
        local sw, sh = 20, 1
        if pan.provider and pan.provider.size then
            local ok, w, h = pcall(pan.provider.size)
            if ok then
                sw, sh = w or sw, h or sh
            end
        end
        pin[i] = { b = b, t = pt, r = pr, bo = pbm, l = pl, nat_w = sw, nat_h = sh }
        nat_w_sum = nat_w_sum + pl + sw + pr
        nat_h_max = math.max(nat_h_max, sh)
        border_cols = border_cols + pl + pr
    end

    -- Widest content drives auto_width: the widest bar band vs the panels' natural footprints.
    local bars_w = 0
    for _, band in ipairs(state.header_bands) do
        bars_w = math.max(bars_w, band.buttons and uibar.width(band.buttons) or util.dw(band.meta or ""))
    end
    for _, band in ipairs(state.footer_bands) do
        bars_w = math.max(bars_w, band.buttons and uibar.width(band.buttons) or 0)
    end
    local content_w = math.max(bars_w, nat_w_sum + sep_w * (n - 1))

    -- Container CONTENT width/height (W excludes the container's own border columns). A docked split
    -- passes its window's ACTUAL width in `place.W` (full width for a below/above dock).
    local W = place and place.W or util.axis_size(cfg.auto_width, cfg.width, cfg.max_width, content_w, vim.o.columns)
    local header_h = #state.header_bands
    local footer_h = #state.footer_bands
    local content_h = header_h + footer_h + nat_h_max
    -- A split takes the full height nvim gives it (place.H); a float sizes per auto/explicit height.
    local H = place and place.H or util.axis_size(cfg.auto_height, cfg.height, cfg.max_height, content_h, vim.o.lines)
    H = math.max(H, header_h + footer_h + 1)

    -- Float: centre on screen. Split: the container window's actual screen position (passed in `place`).
    local row = place and place.row or math.max(1, math.floor((vim.o.lines - H) / 2 - 1))
    local col = place and place.col or math.max(1, math.floor((vim.o.columns - W) / 2))
    local cc_row, cc_col = row + ct, col + cl
    local center_top = cc_row + header_h
    local center_h = math.max(1, H - header_h - footer_h)

    -- Distribute the center width across panels: weighted panels take their share, weightless ones
    -- split the remainder (auto_width ⇒ each takes its natural width).
    local avail = math.max(n, W - border_cols - sep_w * (n - 1))
    local widths, fixed, flex = {}, 0, {}
    for i, pan in ipairs(panels) do
        local wgt = pan.weight
        if cfg.auto_width and not wgt then
            widths[i] = pin[i].nat_w
            fixed = fixed + widths[i]
        elseif wgt then
            widths[i] = math.max(1, wgt <= 1 and math.floor(avail * wgt) or math.floor(wgt))
            fixed = fixed + widths[i]
        else
            flex[#flex + 1] = i
        end
    end
    local rest = math.max(0, avail - fixed)
    if #flex > 0 then
        local each = math.max(1, math.floor(rest / #flex))
        for _, i in ipairs(flex) do
            widths[i] = each
        end
        widths[flex[#flex]] = widths[flex[#flex]] + (rest - each * #flex)
    elseif n > 0 then
        widths[n] = widths[n] + rest
    end

    -- Lay footprints left→right; each panel's col is its LEFT-BORDER position; dividers sit in the gaps.
    local out, dividers = {}, {}
    local x = cc_col
    for i = 1, n do
        local pi = pin[i]
        out[i] = {
            width = widths[i],
            height = math.max(1, center_h - pi.t - pi.bo),
            row = center_top,
            col = x,
            border = pi.b,
        }
        x = x + pi.l + widths[i] + pi.r
        if i < n and sep_w > 0 then
            dividers[#dividers + 1] = x - cc_col
            x = x + sep_w
        end
    end

    return {
        W = W,
        H = H,
        row = row,
        col = col,
        cbord = cbord,
        ct = ct,
        header_h = header_h,
        footer_h = footer_h,
        center_h = center_h,
        panels = out,
        dividers = dividers,
    }
end

-- ─── chrome render ────────────────────────────────────────────────────────────

--- Render the container buffer: the header band rows at the top, the footer band rows at the bottom,
--- blank center rows carrying the divider columns in between, plus all bar/meta highlights.
---@param state table
---@param L table
local function render_chrome(state, L)
    local W, H = L.W, L.H
    local sep_char = (state.cfg.separator and state.cfg.separator ~= "") and state.cfg.separator or nil
    local divider_set = {}
    for _, d in ipairs(L.dividers) do
        divider_set[d] = true
    end

    local function center_line()
        if not sep_char then
            return string.rep(" ", W)
        end
        local cells = {}
        for c = 0, W - 1 do
            cells[c + 1] = divider_set[c] and sep_char or " "
        end
        return table.concat(cells)
    end

    local lines = {}
    for i = 1, H do
        lines[i] = (i > L.header_h and i <= H - L.footer_h) and center_line() or string.rep(" ", W)
    end

    -- Place each header/footer band, recording where its bar buttons land (for the next layer's
    -- selection + hit-testing). `placements` holds post-write highlight ops { row0, c0, c1, hl, prio }.
    state.bands = {} -- flat sector list of the bar bands
    local placements = {}

    local function lay_band(ln, band, where)
        if band.meta ~= nil then
            lines[ln] = util.center(band.meta, W)
            if band.meta ~= "" and band.hl then
                local s = math.floor((W - util.dw(band.meta)) / 2)
                placements[#placements + 1] = { ln - 1, math.max(0, s), s + #band.meta, band.hl, 200 }
            end
            return
        end
        -- When this bar is the focused sector, its `_sel` button drives BOTH the scroll-follow (`sel`,
        -- keeps it visible on a narrow frame) and the visible selection (`hover`, the button's hover
        -- styling).
        local focused = state.focus and state.focus.kind == "bar" and state.focus.band == band
        local sel = focused and band._sel or nil
        local res = uibar.render({
            buttons = band.buttons or {},
            width = W,
            align = band.align or "center",
            chevrons = state.cfg.chevrons,
            sel = sel,
            hover = sel,
            off = band._off,
        })
        band._off = res.off
        lines[ln] = res.line
        local entry = { kind = where, row = ln, buttons = {}, band = band }
        for i, b in ipairs(res.buttons) do
            entry.buttons[i] = { c0 = b.c0, c1 = b.c1, spec = b.spec, sep = b.sep }
        end
        state.bands[#state.bands + 1] = entry
        for _, sp in ipairs(res.spans) do
            placements[#placements + 1] = { ln - 1, sp[1], sp[2], sp[3], 200 }
        end
        for _, ch in ipairs(res.chevrons) do
            placements[#placements + 1] = { ln - 1, ch[1], ch[2], "LvimUiFooterChevron", 200 }
        end
    end

    for i, band in ipairs(state.header_bands) do
        lay_band(i, band, "header")
    end
    for i, band in ipairs(state.footer_bands) do
        lay_band(H - L.footer_h + i, band, "footer")
    end

    vim.bo[state.container_buf].modifiable = true
    api.nvim_buf_set_lines(state.container_buf, 0, -1, false, lines)
    vim.bo[state.container_buf].modifiable = false
    api.nvim_buf_clear_namespace(state.container_buf, NS, 0, -1)

    for _, p in ipairs(placements) do
        pcall(api.nvim_buf_set_extmark, state.container_buf, NS, p[1], p[2], {
            end_col = p[3],
            hl_group = util.resolve_hl(p[4]),
            priority = p[5],
        })
    end
    if sep_char then
        for ln = L.header_h, H - L.footer_h - 1 do
            for _, d in ipairs(L.dividers) do
                pcall(api.nvim_buf_set_extmark, state.container_buf, NS, ln, d, {
                    end_col = d + #sep_char,
                    hl_group = util.resolve_hl("LvimUiPeekBorder"),
                })
            end
        end
    end
end

--- Render a panel's provider content into its buffer.
---@param state table
---@param idx integer
local function render_panel(state, idx)
    local pan = state.panels[idx]
    if not (pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        return
    end
    local L = state._geom.panels[idx]
    -- An `update` provider OWNS its window — it may swap in an external buffer (e.g. the peek preview
    -- showing the real file buffer with its own syntax). The frame does not write lines for it.
    if pan.provider and pan.provider.update then
        pcall(pan.provider.update, pan, L)
        return
    end
    local lines, hls = {}, {}
    if pan.provider and pan.provider.render then
        local ok, rl, rh = pcall(pan.provider.render, L.width, L.height)
        if ok then
            lines, hls = rl or {}, rh or {}
        end
    end
    vim.bo[pan.buf].modifiable = true
    api.nvim_buf_set_lines(pan.buf, 0, -1, false, lines)
    -- An `editable` provider (the input field) keeps its buffer writable; all others are read-only.
    vim.bo[pan.buf].modifiable = (pan.provider and pan.provider.editable) or false
    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_set_extmark, pan.buf, NS, h[1], h[2], {
            end_col = h[3],
            hl_group = util.resolve_hl(h[4]),
            priority = h[5] or 200,
        })
    end
end

-- ─── sectors / focus / navigation ─────────────────────────────────────────────

--- The ordered sector list: each header bar band, then each center panel, then each footer bar band.
--- Meta header bands (title/subtitle) are NOT sectors. `_sel`/`_off` live on the band tables so the
--- selection + scroll persist across redraws.
---@param state table
---@return table[]
local function build_sectors(state)
    local s = {}
    for _, band in ipairs(state.header_bands) do
        if band.buttons then
            s[#s + 1] = { kind = "bar", band = band, where = "header" }
        end
    end
    for i = 1, #state.panels do
        s[#s + 1] = { kind = "panel", idx = i }
    end
    for _, band in ipairs(state.footer_bands) do
        if band.buttons then
            s[#s + 1] = { kind = "bar", band = band, where = "footer" }
        end
    end
    return s
end

--- Focus sector `i`: a PANEL sector focuses its window and shows the cursor (its provider drives the
--- keys); a BAR sector focuses the (non-focusable) container, hides the cursor and selects a button.
---@param state table
---@param i integer
local function focus_sector(state, i)
    local sec = state.sectors[i]
    if not sec then
        return
    end
    state.focus_idx = i
    if sec.kind == "panel" then
        state.focus = { kind = "panel", idx = sec.idx }
        local pan = state.panels[sec.idx]
        -- A list-style provider shows its selection via cursorline, so hide the noisy hardware cursor.
        if pan.provider and pan.provider.hide_cursor then
            hide_cursor(state)
        else
            show_cursor(state)
        end
        if pan.win and api.nvim_win_is_valid(pan.win) then
            api.nvim_set_current_win(pan.win)
        end
        -- An editable panel (the input field) enters insert at the end of its line.
        if pan.provider and pan.provider.editable then
            vim.schedule(function()
                if pan.win and api.nvim_win_is_valid(pan.win) then
                    api.nvim_set_current_win(pan.win)
                    vim.cmd("startinsert!")
                end
            end)
        end
        if pan.provider and pan.provider.on_focus then
            pcall(pan.provider.on_focus)
        end
    else
        sec.band._sel = sec.band._sel or 1
        state.focus = { kind = "bar", band = sec.band, where = sec.where }
        if state.container_win and api.nvim_win_is_valid(state.container_win) then
            api.nvim_set_current_win(state.container_win)
        end
        hide_cursor(state)
    end
    render_chrome(state, state._geom)
end

--- Move focus to the next/prev sector (wraps).
---@param state table
---@param dir integer
local function sector_cycle(state, dir)
    local n = #state.sectors
    if n == 0 then
        return
    end
    focus_sector(state, ((state.focus_idx - 1 + dir) % n) + 1)
end

--- Move the focused bar's selection by `dir`, skipping non-interactive separators; redraw (which
--- scrolls the selection into view on a narrow frame).
---@param state table
---@param dir integer
local function menu_move(state, dir)
    if not (state.focus and state.focus.kind == "bar") then
        return
    end
    local btns = state.focus.band.buttons or {}
    local n = #btns
    if n == 0 then
        return
    end
    local i = state.focus.band._sel or 1
    repeat
        i = i + (dir > 0 and 1 or -1)
    until i < 1 or i > n or not btns[i].separator
    if i >= 1 and i <= n then
        state.focus.band._sel = i
        render_chrome(state, state._geom)
        -- A "live" bar (e.g. the tab bar) reacts to every selection move, not just <CR>.
        if state.focus.band.on_change then
            state.focus.band.on_change(btns[i], state)
        end
    end
end

--- Fire the focused bar's selected button: `spec.run(state)` if present, else `band.on_select(spec,
--- state)`.
---@param state table
local function menu_confirm(state)
    if not (state.focus and state.focus.kind == "bar") then
        return
    end
    local band = state.focus.band
    local spec = (band.buttons or {})[band._sel or 1]
    if not spec or spec.separator then
        return
    end
    if spec.run then
        spec.run(state)
    elseif band.on_select then
        band.on_select(spec, state)
    end
end

--- Install the chassis keymaps. Panel buffers get sector cycling + the provider's own keys; the
--- container buffer (bar-menu mode) gets selection move / confirm + sector cycling. `cfg.close_keys`
--- close a modal frame from anywhere.
---@param state table
local function set_keys(state)
    local K = vim.tbl_extend("force", DEFAULT_KEYS, state.cfg.keys or {})
    local function map(buf, lhs, fn)
        for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    for _, pan in ipairs(state.panels) do
        map(pan.buf, K.sector_next, function()
            sector_cycle(state, 1)
        end)
        map(pan.buf, K.sector_prev, function()
            sector_cycle(state, -1)
        end)
        if pan.provider and pan.provider.keys then
            pcall(pan.provider.keys, function(lhs, fn)
                map(pan.buf, lhs, fn)
            end, pan, state)
        end
        for _, ck in ipairs(state.cfg.close_keys or {}) do
            map(pan.buf, ck, state.close)
        end
    end
    map(state.container_buf, K.menu_prev, function()
        menu_move(state, -1)
    end)
    map(state.container_buf, K.menu_next, function()
        menu_move(state, 1)
    end)
    map(state.container_buf, K.menu_confirm, function()
        menu_confirm(state)
    end)
    map(state.container_buf, K.sector_next, function()
        sector_cycle(state, 1)
    end)
    map(state.container_buf, K.sector_prev, function()
        sector_cycle(state, -1)
    end)
    for _, ck in ipairs(state.cfg.close_keys or {}) do
        map(state.container_buf, ck, state.close)
    end
end

-- ─── open / close ─────────────────────────────────────────────────────────────

--- Build the container + the N panel windows from a computed layout.
---@param state table
local function open_windows(state)
    state.zindex = state.cfg.zindex or 50
    state.container_buf = api.nvim_create_buf(false, true)

    local L
    if state.cfg.mode == "split" then
        -- A docked split: `dock` left/right = a vertical split (fixed width from sizing, full height),
        -- below/above = a horizontal split (fixed height, full width). The chrome lives in this split's
        -- buffer; the panels float over its center rows at its ACTUAL screen position / size.
        local g0 = compute_geom(state)
        local dock = state.cfg.dock or "right"
        local horiz = dock == "below" or dock == "above"
        state.container_win = api.nvim_open_win(state.container_buf, false, {
            split = dock,
            win = -1,
            width = (not horiz) and g0.W or nil,
            height = horiz and g0.H or nil,
            style = "minimal",
        })
        local pos = api.nvim_win_get_position(state.container_win)
        L = compute_geom(state, {
            row = pos[1],
            col = pos[2],
            W = api.nvim_win_get_width(state.container_win),
            H = api.nvim_win_get_height(state.container_win),
        })
        if horiz then
            vim.wo[state.container_win].winfixheight = true
        else
            vim.wo[state.container_win].winfixwidth = true
        end
    else
        L = compute_geom(state)
        state.container_win = api.nvim_open_win(state.container_buf, false, {
            relative = "editor",
            width = L.W,
            height = L.H,
            row = L.row,
            col = L.col,
            border = L.cbord,
            style = "minimal",
            focusable = false,
            zindex = state.zindex,
            title = L.ct > 0 and { { " " .. (state.cfg.title or "") .. " ", "LvimUiPeekTitle" } } or nil,
            title_pos = L.ct > 0 and "center" or nil,
        })
    end
    state._geom = L
    vim.wo[state.container_win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"

    render_chrome(state, L)

    for i, pan in ipairs(state.panels) do
        local pl = L.panels[i]
        pan.buf = api.nvim_create_buf(false, true)
        -- "hide" not "wipe": an external-buffer panel (preview) swaps its window to a real file buffer,
        -- which would WIPE a `wipe` scratch buf out from under the still-pending keymaps. Deleted in close.
        vim.bo[pan.buf].bufhidden = "hide"
        pan.win = api.nvim_open_win(pan.buf, i == 1, {
            relative = "editor",
            width = pl.width,
            height = pl.height,
            row = pl.row,
            col = pl.col,
            border = pl.border,
            style = "minimal",
            zindex = state.zindex + 1,
        })
        if pan.provider and pan.provider.cursorline then
            vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiPeekCursorLine"
            vim.wo[pan.win].cursorline = true
        else
            vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal"
        end
        pan.refresh = function() -- a provider re-renders its own panel after a state change (toggle, …)
            render_panel(state, i)
        end
        pan.frame = state -- providers reach the frame (focus_panel / close / cfg) through their panel
        render_panel(state, i)
    end

    -- Wire interaction: the sector list, the keymaps, and the initial focus (the first center panel).
    state.refresh_chrome = function() -- re-render the header/footer bands (e.g. after a tab switch)
        render_chrome(state, state._geom)
    end
    state.sectors = build_sectors(state)
    --- Focus a center panel by its index (used by a panel whose window hosts an external buffer, e.g.
    --- the peek preview, to return focus to a sibling panel through the proper sector model).
    state.focus_panel = function(i)
        for si, sec in ipairs(state.sectors) do
            if sec.kind == "panel" and sec.idx == i then
                focus_sector(state, si)
                return
            end
        end
    end
    set_keys(state)
    local first_panel = 1
    for idx, sec in ipairs(state.sectors) do
        if sec.kind == "panel" then
            first_panel = idx
            break
        end
    end
    focus_sector(state, first_panel)

    -- Closing any frame window externally (`:q`, a programmatic close) tears the whole frame down once.
    state.augroup = api.nvim_create_augroup("LvimUiFrame_" .. tostring(state.container_win), { clear = true })
    local watch = { state.container_win }
    for _, pan in ipairs(state.panels) do
        watch[#watch + 1] = pan.win
    end
    api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        callback = function(ev)
            local w = tonumber(ev.match)
            for _, ww in ipairs(watch) do
                if ww == w then
                    state.close()
                    return
                end
            end
        end,
    })
end

--- Tear the frame down: close every window, restore the cursor + focus, fire `cfg.on_close` once.
---@param state table
local function close(state)
    if state._closed then
        return
    end
    state._closed = true
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    show_cursor(state)
    for _, pan in ipairs(state.panels or {}) do
        if pan.win and api.nvim_win_is_valid(pan.win) then
            pcall(api.nvim_win_close, pan.win, true)
        end
        if pan.buf and api.nvim_buf_is_valid(pan.buf) then
            pcall(api.nvim_buf_delete, pan.buf, { force = true })
        end
    end
    if state.container_win and api.nvim_win_is_valid(state.container_win) then
        pcall(api.nvim_win_close, state.container_win, true)
    end
    if state.origin and api.nvim_win_is_valid(state.origin) then
        pcall(api.nvim_set_current_win, state.origin)
    end
    if state.cfg.on_close then
        pcall(state.cfg.on_close)
    end
end

--- Open a frame.
---@param cfg table  the frame config (see the module header)
---@return table state
function M.open(cfg)
    cfg = cfg or {}
    cfg.mode = cfg.mode or "float"
    -- Modal frames close on q / <Esc> from anywhere; a `persistent` frame (e.g. a docked outline) sets
    -- its own close_keys (or none) and is never auto-closed.
    if cfg.close_keys == nil and not cfg.persistent then
        cfg.close_keys = { "q", "<Esc>" }
    end
    local state = {
        cfg = cfg,
        origin = api.nvim_get_current_win(),
        panels = cfg.panels or {},
        header_bands = header_bands(cfg.header),
        footer_bands = footer_bands(cfg.footer),
    }
    state.close = function()
        close(state)
    end
    open_windows(state)
    return state
end

return M
