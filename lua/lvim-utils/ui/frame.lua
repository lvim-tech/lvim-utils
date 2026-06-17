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
-- The whole config is a nested tree:
--   { title (box), border, size = { width/height = { auto, min, max, fixed } },
--     header = { bars = { { items, align?, chevrons?, on_change? } | { text } } },
--     content = { blocks = { { id, provider, size = { width }, border } } },   -- 1..N
--     footer = { bars = { … } } }
-- Each bar holds `items` (button / separator boxes) and owns its overflow chevrons; each block hosts a
-- content provider, addressed by `id` (`st.focus_block`). Sizing is per axis — `auto` fits the content
-- within `[min, max]`, else `fixed` (a screen fraction ≤1 or an absolute count). Only the center scrolls.
--
-- Modes: `mode = "float"` (centred modal) · `mode = "split"` (docked-modal, e.g. the bottom peek — panels
-- still FLOAT over a container) · `mode = "split", native = true` (a single block as a REAL split window,
-- NOT a float — for a persistent NAVIGABLE side panel like the lsp outline, so `<C-w>` nav and buffer
-- redraw behave natively; title = winbar, no bars).
--
---@module "lvim-utils.ui.frame"

local uibar = require("lvim-utils.ui.bar")
local util = require("lvim-utils.ui.util")
local cursor = require("lvim-utils.cursor")

local api = vim.api
local NS = api.nvim_create_namespace("lvim_utils_ui_frame")

local M = {}

-- ─── cursor hiding ────────────────────────────────────────────────────────────
-- Hiding the hardware cursor is delegated to lvim-utils.cursor (the ONE cursor system): the chrome
-- container and every panel whose provider sets `hide_cursor` carry the `lvim-ui-frame` filetype,
-- registered as a CURRENT-ONLY panel ft. So the module hides the cursor only while one of those is the
-- focused window (a list panel, or the container while a bar sector is selected) and shows it in
-- editable panels (the input field, the real preview buffer) and outside the frame. `cursor.update()`
-- is called right after a programmatic focus change so it applies without a one-frame flash.
local FRAME_FT = "lvim-ui-frame"
local cursor_registered = false
local function register_frame_ft()
    if not cursor_registered then
        cursor_registered = true
        pcall(cursor.setup, { panel_ft = { FRAME_FT } })
    end
end

-- Default keymaps for the chassis; the consumer may override via `cfg.keys`.
local DEFAULT_KEYS = {
    sector_next = "<C-j>", -- header · center · footer (down), from anywhere
    sector_prev = "<C-k>", -- (up)
    panel_next = "<C-l>", -- next center panel (right) — only while a center panel is focused
    panel_prev = "<C-h>", -- previous center panel (left)
    menu_prev = { "h", "<Left>" },
    menu_next = { "l", "<Right>" },
    menu_confirm = { "<CR>", "<Space>" },
}

-- ─── config normalisation ─────────────────────────────────────────────────────

--- Default style for a footer action button: a blue key BADGE + a yellow name, padded 1 each side.
local FOOTER_STYLE = {
    icon = {
        padding = { 1, 1 },
        normal = "LvimUiFooterKey",
        active = "LvimUiFooterKey",
        hover = "LvimUiFooterKeyHover",
    },
    text = {
        padding = { 1, 1 },
        normal = "LvimUiFooterLabel",
        active = "LvimUiFooterLabel",
        hover = "LvimUiFooterLabelHover",
    },
}

--- Normalise a bar's `items` into button/separator specs. A FOOTER action shorthand `{ key, name|text,
--- run }` (no `type`) becomes a footer-styled key-badge button; everything else (full button / separator
--- specs, e.g. header tab buttons that carry their own style) passes through unchanged.
---@param items table[]|nil
---@param footer boolean
---@return LvimUiButtonSpec[]
local function bar_items(items, footer)
    local out = {}
    for i, it in ipairs(items or {}) do
        if it.type or not footer then
            out[i] = it
        else
            out[i] = {
                type = "button",
                key = it.key,
                key_badge = true,
                text = it.name or it.text or "",
                run = it.run,
                active = it.active,
                style = it.style or FOOTER_STYLE,
            }
        end
    end
    return out
end

--- Build a band stack from `cfg.header` / `cfg.footer`. Each `bar` is a ui.bar `{ items, align, chevrons,
--- on_change, on_select }` OR a meta line `{ text = "...", hl }`. Internally a bar band keeps its element
--- list in `band.buttons` (the field name the machinery uses — it already holds buttons + separators).
--- The header leads with 1 blank "air" row (under the border-title); the footer with 1 blank row above
--- its content — per the UI canon.
---@param spec table|nil
---@param footer boolean
---@return table[]
local function build_bands(spec, footer)
    spec = spec or {}
    local bands = {}
    for _, bar in ipairs(spec.bars or {}) do
        if bar.text ~= nil then
            bands[#bands + 1] = { meta = bar.text, hl = bar.hl or (footer and "LvimUiSubtitle" or "LvimUiPeekTitle") }
        else
            -- Mutate the bar spec INTO its band (the machinery reads the element list as `band.buttons`),
            -- so a consumer that keeps a reference to the bar can drive its `_sel` / button `active` flags
            -- live (e.g. the project panel switching tabs from the content body).
            bar.buttons = bar_items(bar.items, footer)
            bar.align = bar.align or "center"
            bands[#bands + 1] = bar
        end
    end
    if footer then
        if #bands > 0 then
            table.insert(bands, 1, { meta = "" })
        end
    else
        table.insert(bands, 1, { meta = "" }) -- 1 air row under the (border-)title
    end
    return bands
end

--- Build the float border-title chunks (`{ { text, hl }, … }`) from the `title` box: an optional icon box
--- + a text box, each with its own padding + colour (static — one hl per box). A plain string is accepted
--- too (→ a single padded text chunk).
---@param title table|string|nil
---@return table[]|nil
local function title_chunks(title)
    local function box(content, bs, default_hl)
        if not content or content == "" then
            return nil
        end
        local f, b = 1, 1
        local pad = bs.padding
        if type(pad) == "number" then
            f, b = pad, pad
        elseif type(pad) == "table" then
            f, b = pad[1] or 1, pad[2] or 1
        end
        return { string.rep(" ", f) .. content .. string.rep(" ", b), util.resolve_hl(bs.hl or default_hl) }
    end
    if type(title) == "string" then
        return title ~= "" and { box(title, {}, "LvimUiPeekTitle") } or nil
    end
    if type(title) ~= "table" then
        return nil
    end
    local st = title.style or {}
    local chunks = {}
    local ic = box(title.icon, st.icon or {}, "LvimUiPeekTitleIcon")
    local tc = box(title.text, st.text or {}, "LvimUiPeekTitle")
    if ic then
        chunks[#chunks + 1] = ic
    end
    if tc then
        chunks[#chunks + 1] = tc
    end
    return #chunks > 0 and chunks or nil
end

--- Flatten a `title` box (or string) to a plain string (icon + text) — for a winbar / split content row.
---@param title table|string|nil
---@return string
local function title_text(title)
    if type(title) == "string" then
        return title
    end
    if type(title) ~= "table" then
        return ""
    end
    return ((title.icon and title.icon .. " ") or "") .. (title.text or "")
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
    local ct, cr, cb, cl = util.insets(cbord)

    local panels = state.panels
    local n = #panels
    local sep_w = (cfg.separator and cfg.separator ~= "") and 1 or 0

    -- Per-panel border insets + natural content size (provider.size()).
    local pin = {}
    local nat_w_sum, nat_h_max, border_cols, max_vborder = 0, 1, 0, 0
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
        max_vborder = math.max(max_vborder, pt + pbm) -- so min_content counts VISIBLE rows, not the border
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
    if not place and cfg.min_width then
        local mw = cfg.min_width <= 1 and math.floor(vim.o.columns * cfg.min_width) or cfg.min_width
        W = math.max(W, math.floor(mw))
    end
    local header_h = #state.header_bands
    local footer_h = #state.footer_bands
    local content_h = header_h + footer_h + nat_h_max
    -- A split takes the full height nvim gives it (place.H); a float sizes per auto/explicit height. The
    -- center never shrinks below `min_content_height` VISIBLE rows — counted on the panel content, so the
    -- panel borders are added on top (the header/footer bands are fixed-height). `min_h` is the resulting
    -- minimum container height, exported for the resize clamp.
    local min_center = math.max(1, cfg.min_content_height or 1) + max_vborder
    local min_h = header_h + footer_h + min_center
    local H = place and place.H or util.axis_size(cfg.auto_height, cfg.height, cfg.max_height, content_h, vim.o.lines)
    H = math.max(H, min_h)

    -- Float: centre on screen. Split: the container window's actual screen position (passed in `place`).
    local row = place and place.row or math.max(1, math.floor((vim.o.lines - H) / 2 - 1))
    local col = place and place.col or math.max(1, math.floor((vim.o.columns - W) / 2))
    -- A bottom/top-docked FLOAT spans the full width and anchors to that edge — a docked panel WITHOUT a
    -- real window split, so there is NO native separator / statusline boundary above it.
    if not place and (cfg.position == "bottom" or cfg.position == "top") then
        W = vim.o.columns - cl - cr
        col = 0
        row = cfg.position == "bottom" and math.max(0, vim.o.lines - H - ct - cb - 1) or 0
    end
    local cc_row, cc_col = row + ct, col + cl
    local center_top = cc_row + header_h
    local center_h = math.max(min_center, H - header_h - footer_h)

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
        min_h = min_h,
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
                -- 1 space of padding on each side, so a title's bg chrome reads " LVIM LSP " not hugging.
                local s = math.floor((W - util.dw(band.meta)) / 2)
                placements[#placements + 1] =
                    { ln - 1, math.max(0, s - 1), math.min(W, s + #band.meta + 1), band.hl, 200 }
            end
            return
        end
        -- When this bar is the focused sector, its `_sel` button drives BOTH the scroll-follow (`sel`,
        -- keeps it visible on a narrow frame) and the visible selection (`hover`, the button's hover
        -- styling). `_blurred` (focus left the whole frame) drops the selection so no button looks hovered
        -- while the user is back in a normal buffer.
        local focused = not state._blurred and state.focus and state.focus.kind == "bar" and state.focus.band == band
        local sel = focused and band._sel or nil
        local res = uibar.render({
            items = band.buttons or {},
            width = W,
            align = band.align or "center",
            chevrons = band.chevrons or state.cfg.chevrons,
            sel = sel,
            hover = sel,
            off = band._off,
        })
        band._off = res.off
        lines[ln] = res.line
        local entry = { kind = where, row = ln, buttons = {}, band = band }
        for i, b in ipairs(res.items) do
            entry.buttons[i] = { c0 = b.c0, c1 = b.c1, spec = b.spec, sep = b.sep }
        end
        state.bands[#state.bands + 1] = entry
        -- The visible selection is the button's OWN `hover` style (each box's bg, stronger) — NO extra
        -- frame overlay (it bled a 1-col blue tint past the button on each side).
        -- res.spans already carry the chevron boxes' OWN colours (the bar renders them as boxes), so the
        -- frame no longer colourises chevron ranges separately.
        for _, sp in ipairs(res.spans) do
            placements[#placements + 1] = { ln - 1, sp[1], sp[2], sp[3], 200 }
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
    -- The whole center (all N panels) is ONE vertical sector — `<C-j>`/`<C-k>` step header · center ·
    -- footer; `<C-l>`/`<C-h>` move between the panels INSIDE the center.
    if #state.panels > 0 then
        s[#s + 1] = { kind = "center" }
    end
    for _, band in ipairs(state.footer_bands) do
        if band.buttons then
            s[#s + 1] = { kind = "bar", band = band, where = "footer" }
        end
    end
    return s
end

--- Focus center panel `i`: pick the cursor mode, focus its window, start insert for an editable panel,
--- fire on_focus. Records it as the current center panel.
---@param state table
---@param i integer
local function focus_panel_win(state, i)
    local pan = state.panels[i]
    if not pan then
        return
    end
    state.center_panel = i
    if pan.win and api.nvim_win_is_valid(pan.win) then
        api.nvim_set_current_win(pan.win)
    end
    -- The panel's filetype drives cursor visibility (hide-cursor panels carry FRAME_FT) — apply it now to
    -- avoid a one-frame flash.
    cursor.update()
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
end

--- Focus sector `i`: the CENTER sector focuses its current panel (the panels are ONE vertical sector;
--- `<C-l>`/`<C-h>` move between them); a BAR sector focuses the container, hides the cursor + selects.
---@param state table
---@param i integer
local function focus_sector(state, i)
    local sec = state.sectors[i]
    if not sec then
        return
    end
    state.focus_idx = i
    if sec.kind == "center" then
        state.focus = { kind = "center", panel = state.center_panel or 1 }
        focus_panel_win(state, state.center_panel or 1)
    else
        sec.band._sel = sec.band._sel or 1
        state.focus = { kind = "bar", band = sec.band, where = sec.where }
        if state.container_win and api.nvim_win_is_valid(state.container_win) then
            -- Mark this as a frame-driven focus so the container's WinEnter hook does NOT bounce us into
            -- the center (that bounce is only for a NATIVE `<C-w>j` entry). WinEnter fires synchronously
            -- inside nvim_set_current_win, so the flag is up while it runs.
            state._focusing_bar = true
            api.nvim_set_current_win(state.container_win)
            state._focusing_bar = false
        end
        cursor.update() -- container is current (FRAME_FT) → cursor hidden in bar-menu mode
    end
    render_chrome(state, state._geom)
end

--- The sector index of the CURRENTLY focused window — a panel by its window, else the tracked bar.
--- Reading the real window keeps `<C-j>`/`<C-k>` correct even if focus changed outside the frame.
---@param state table
---@return integer
local function current_sector(state)
    local w = api.nvim_get_current_win()
    -- Any center panel window maps to the single center sector.
    for _, pan in ipairs(state.panels) do
        if pan.win == w then
            for si, sec in ipairs(state.sectors) do
                if sec.kind == "center" then
                    return si
                end
            end
        end
    end
    return state.focus_idx or 1
end

--- At a vertical EDGE of a docked split, hand focus OUT to the neighbouring real window instead of
--- wrapping inside the frame: step OUT toward the editor in the given wincmd direction. The caller picks
--- the direction to MATCH the dock — currently only the VERTICAL sector escape uses it (`<C-k>` from the
--- top sector steps up to the editor above a bottom-docked peek). The function stays direction-generic, so
--- a future float side-dock could pass `h`/`l`. The frame stays open — in split mode it is non-modal;
--- float frames are modal, so they never escape (they keep wrapping). Returns true when focus moved out.
---@param state table
---@param nav string  "h"|"j"|"k"|"l" — the wincmd direction to the neighbouring editor window
---@return boolean
local function escape_to_neighbor(state, nav)
    if state.cfg.mode ~= "split" then
        return false
    end
    if not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return false
    end
    -- The panels are floats (off the window layout), so resolve the neighbour from the container split.
    -- `winnr(nav)` returns the container's OWN number when there is no window in that direction.
    local target = api.nvim_win_call(state.container_win, function()
        return vim.fn.win_getid(vim.fn.winnr(nav))
    end)
    if target == 0 or target == state.container_win or not api.nvim_win_is_valid(target) then
        return false
    end
    api.nvim_set_current_win(target)
    cursor.update() -- the editor (normal ft) is current now → cursor visible again
    return true
end

--- Move focus to the next/prev sector, starting from the actually-focused window. At the top/bottom edge
--- of a docked split it steps OUT to the neighbouring editor window (see `escape_to_neighbor`); otherwise
--- it wraps around the frame.
---@param state table
---@param dir integer
local function sector_cycle(state, dir)
    local n = #state.sectors
    if n == 0 then
        return
    end
    local cur = current_sector(state)
    if (dir < 0 and cur == 1) or (dir > 0 and cur == n) then
        -- Top/bottom edge of a docked split → step VERTICALLY out to the editor (matches a below/above dock).
        if escape_to_neighbor(state, dir < 0 and "k" or "j") then
            return
        end
    end
    focus_sector(state, ((cur - 1 + dir) % n) + 1)
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
    until i < 1 or i > n or btns[i].type ~= "separator"
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
    if not spec or spec.type == "separator" then
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
        -- Panels: vertical sector cycling (header·center·footer) AND horizontal panel nav (left/right);
        -- the panel keys are ONLY here (not on the container), so `<C-l>`/`<C-h>` are inert in a bar.
        map(pan.buf, K.sector_next, function()
            sector_cycle(state, 1)
        end)
        map(pan.buf, K.sector_prev, function()
            sector_cycle(state, -1)
        end)
        map(pan.buf, K.panel_next, function()
            state.panel(1)
        end)
        map(pan.buf, K.panel_prev, function()
            state.panel(-1)
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

    -- Extra consumer keymaps that fire from ANYWHERE in the frame (every panel + the container), each a
    -- `{ key = lhs|lhs[], run = fn(state) }` — e.g. the Quit dialog's `q` = quit without saving.
    for _, km in ipairs(state.cfg.keymaps or {}) do
        local fn = function()
            km.run(state)
        end
        for _, pan in ipairs(state.panels) do
            map(pan.buf, km.key, fn)
        end
        map(state.container_buf, km.key, fn)
    end

    -- Header button hotkeys work from EVERYWHERE: on every panel (all keys) and the container (all but
    -- the menu nav keys, so `h`/`l` still move the selection while a bar is focused).
    for _, pan in ipairs(state.panels) do
        state.map_hotkeys(pan.buf, {})
    end
    local reserved = {}
    for _, group in ipairs({ K.menu_prev, K.menu_next, K.menu_confirm }) do
        for _, l in ipairs(type(group) == "table" and group or { group }) do
            reserved[#reserved + 1] = l
        end
    end
    state.map_hotkeys(state.container_buf, reserved)
end

--- Re-fit the floating panels to the container's CURRENT size and re-render the chrome. Called when the
--- docked split is resized (or the editor on `VimResized`): the header/footer bands keep their fixed
--- heights, so the CENTER absorbs the change, and the panel floats follow instead of staying put.
---@param state table
local function relayout(state)
    if state._closed or not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local L
    if state.cfg.mode == "split" then
        -- The split was resized by the user. `compute_geom` floors the center at `min_content_height`
        -- VISIBLE rows and reports the matching minimum container height — if the user shrank below it,
        -- snap the split back up so the center keeps its rows, then re-fit.
        local function geom()
            local pos = api.nvim_win_get_position(state.container_win)
            return compute_geom(state, {
                row = pos[1],
                col = pos[2],
                W = api.nvim_win_get_width(state.container_win),
                H = api.nvim_win_get_height(state.container_win),
            })
        end
        L = geom()
        if api.nvim_win_get_height(state.container_win) < L.min_h then
            pcall(api.nvim_win_set_height, state.container_win, L.min_h)
            L = geom()
        end
    else
        -- A float reflows to the (possibly resized) screen; move the container float too.
        L = compute_geom(state)
        pcall(api.nvim_win_set_config, state.container_win, {
            relative = "editor",
            width = L.W,
            height = L.H,
            row = L.row,
            col = L.col,
        })
    end
    state._geom = L
    for i, pan in ipairs(state.panels) do
        local pl = L.panels[i]
        if pan.win and api.nvim_win_is_valid(pan.win) then
            pcall(api.nvim_win_set_config, pan.win, {
                relative = "editor",
                width = pl.width,
                height = pl.height,
                row = pl.row,
                col = pl.col,
                border = pl.border,
            })
        end
    end
    render_chrome(state, L)
end

-- ─── open / close ─────────────────────────────────────────────────────────────

--- Build the container + the N panel windows from a computed layout.
---@param state table
local function open_windows(state)
    register_frame_ft() -- ensure lvim-utils.cursor knows FRAME_FT (current-only) for cursor hiding
    state.zindex = state.cfg.zindex or 50
    state.container_buf = api.nvim_create_buf(false, true)
    -- The chrome container hides the hardware cursor while a bar sector is focused (it becomes current).
    vim.bo[state.container_buf].filetype = FRAME_FT

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
            -- Focusable so native window nav can ENTER the docked peek: the panels are floats off the
            -- layout, but this chrome split IS in the layout, so `<C-w>j`/`<C-w>k` from the surrounding
            -- editor land here — a WinEnter hook then bounces focus into the content panel. (Horizontal
            -- `<C-w>l`/`<C-w>h` between the editor splits is unaffected: the split is below them, not beside.)
            focusable = true,
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
        -- The brand is the window's TOP-border title (needs a top border, ct > 0), built from the `title`
        -- box (icon box + text box, each its own padding + colour). `title_pos` must only be set WITH a
        -- title — nvim errors otherwise.
        local brand = L.ct > 0 and title_chunks(state.cfg.title) or nil
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
            title = brand,
            title_pos = brand and "center" or nil,
        })
    end
    state._geom = L
    local docked = state.cfg.mode == "split"
    -- The CONTAINER holds only chrome and is never directly interacted with — always mark it so generic
    -- float helpers ("close all floats" / "focus next float") skip it and land on the content panel.
    vim.w[state.container_win].lvim_frame = true
    vim.wo[state.container_win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"

    render_chrome(state, L)

    for i, pan in ipairs(state.panels) do
        local pl = L.panels[i]
        pan.buf = api.nvim_create_buf(false, true)
        vim.bo[pan.buf].bufhidden = "hide" -- keep the scratch buffer alive while hidden; deleted in close()
        -- A list-style provider shows its selection via cursorline → give its buffer FRAME_FT so the cursor
        -- module hides the hardware cursor while it is focused. Editable panels (input / the real preview
        -- buffer) keep their normal filetype, so the cursor stays visible there.
        if pan.provider and pan.provider.hide_cursor then
            vim.bo[pan.buf].filetype = FRAME_FT
        end
        -- DOCKED (split): `focusable = false` — the panels are NOT part of native window nav (`<C-w>`/
        -- `<C-l>` must reach the surrounding editor splits, not land inside the peek); the frame focuses
        -- them programmatically. FLOAT (modal): `focusable = true` so mouse / "focus next float" helpers
        -- can reach the content panel. zindex: in SPLIT the container is a REAL window, so the floats sit
        -- above it at the default (else they'd stack over unrelated floats like lvim-space); in FLOAT the
        -- container IS a float, so the panels need `zindex + 1` to stay above it.
        pan.win = api.nvim_open_win(pan.buf, i == 1, {
            relative = "editor",
            width = pl.width,
            height = pl.height,
            row = pl.row,
            col = pl.col,
            border = pl.border,
            style = "minimal",
            focusable = not docked,
            zindex = not docked and (state.zindex + 1) or nil,
        })
        -- Mark the panel ONLY when docked (a persistent peek to protect). A FLOAT-mode panel is left
        -- unmarked so "close all floats" dismisses it and "focus next float" lands on it.
        if docked then
            vim.w[pan.win].lvim_frame = true
        end
        if pan.provider and pan.provider.cursorline then
            -- MULTI-panel frames (the list+preview peek) use the NEUTRAL cursorline in BOTH panels; only a
            -- single-panel popup (a pick list) uses the yellow "list hover" cursorline (matches the row icon).
            local cl = (#state.panels > 1) and "LvimUiCursorLine" or "LvimUiPeekCursorLine"
            vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:" .. cl
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
    -- Re-fit the frame to its providers' CURRENT content size (auto width/height) and re-centre — for an
    -- auto-sized frame whose content changed at runtime (e.g. a tab switch swapping the form's row count).
    state.relayout = function()
        relayout(state)
    end
    state.sectors = build_sectors(state)
    state.center_panel = 1
    local function center_idx()
        for si, sec in ipairs(state.sectors) do
            if sec.kind == "center" then
                return si
            end
        end
    end
    --- Focus center panel `i` (used by a panel hosting an external buffer — the preview — and the
    --- "preview" footer action) through the proper sector model.
    state.focus_panel = function(i)
        state.center_panel = math.max(1, math.min(i, #state.panels))
        local ci = center_idx()
        if ci then
            focus_sector(state, ci)
        end
    end
    --- Focus a center BLOCK by its `id` (`content.blocks[i].id`) — order-independent (no numeric index).
    ---@param id any
    state.focus_block = function(id)
        for i, pan in ipairs(state.panels) do
            if pan.id == id then
                state.focus_panel(i)
                return
            end
        end
    end
    --- Move LEFT/RIGHT between the center panels (`dir` = +1 / -1). Only meaningful inside the center.
    --- Reads the REAL focused window (not just the tracked `center_panel`), so it works even when the
    --- preview was focused without going through `focus_panel` (e.g. its own buffer keymaps).
    state.panel = function(dir)
        local w = api.nvim_get_current_win()
        local base = state.center_panel or 1
        for i, pan in ipairs(state.panels) do
            if pan.win == w then
                base = i
                break
            end
        end
        local i = math.max(1, math.min(base + dir, #state.panels))
        if i ~= base then
            focus_panel_win(state, i)
        end
    end
    --- Cycle the focused sector header · center · footer (exposed so an external-buffer panel can drive
    --- the same navigation from its own keymaps).
    state.sector = function(dir)
        sector_cycle(state, dir)
    end
    --- Focus the window the frame was opened from (the editor), keeping the frame open. The WinEnter
    --- hook restores the cursor there.
    state.to_origin = function()
        if state.origin and api.nvim_win_is_valid(state.origin) then
            api.nvim_set_current_win(state.origin)
        end
    end
    --- Map every BAR button's hotkey (header AND footer) on `buf` (firing its `run`), so filter keys and
    --- footer actions (e.g. the per-server form's `a`/`A`/`b`) work from anywhere — not only by navigating
    --- to the bar. `reserved` lists extra keys to SKIP (the container's menu nav, so `h`/`l` still move the
    --- selection there); `<CR>`/`<Space>` are ALWAYS skipped — a content provider owns them (e.g. the list
    --- `<CR>` jump). Called on each panel buffer, the container, and the preview's file buffer.
    state.map_hotkeys = function(buf, reserved)
        local skip = { ["<CR>"] = true, ["<Space>"] = true }
        for _, r in ipairs(reserved or {}) do
            skip[r] = true
        end
        for _, sec in ipairs(state.sectors) do
            if sec.kind == "bar" then
                for _, spec in ipairs(sec.band.buttons or {}) do
                    if spec.key and spec.run and spec.type ~= "separator" and not skip[spec.key] then
                        vim.keymap.set("n", spec.key, function()
                            spec.run(state)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                end
            end
        end
    end
    --- Toggle the first header bar sector (the "menu" shortcut): focus it, or return to the center if it
    --- is already focused. Returns true when it lands ON the header bar.
    state.toggle_header = function()
        for si, sec in ipairs(state.sectors) do
            if sec.kind == "bar" and sec.where == "header" then
                if state.focus and state.focus.kind == "bar" and state.focus_idx == si then
                    local ci = center_idx()
                    if ci then
                        focus_sector(state, ci)
                    end
                    return false
                end
                focus_sector(state, si)
                return true
            end
        end
        return false
    end
    set_keys(state)
    focus_sector(state, center_idx() or 1)

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
    -- Re-fit on resize. Only relayout when the CONTAINER itself was resized (the user dragging the split):
    -- relayout then resizes the floats, whose own WinResized events DON'T include the container, so there
    -- is no feedback loop. VimResized (terminal size change) always reflows.
    api.nvim_create_autocmd("WinResized", {
        group = state.augroup,
        callback = function()
            if state._closed then
                return
            end
            for _, w in ipairs(vim.v.event.windows or {}) do
                if w == state.container_win then
                    relayout(state)
                    return
                end
            end
        end,
    })
    api.nvim_create_autocmd("VimResized", {
        group = state.augroup,
        callback = function()
            if not state._closed then
                relayout(state)
            end
        end,
    })
    -- Drop / restore the focused-bar selection highlight as focus leaves / re-enters the frame, so a
    -- header button never looks hovered while the user is back in a normal buffer.
    local function set_blur(b)
        if state._blurred ~= b then
            state._blurred = b
            render_chrome(state, state._geom)
        end
    end
    -- Cursor hygiene: the frame hides the hardware cursor while a list panel is focused, so when focus
    -- moves OUT of the frame (e.g. `<C-w>w` to the editor above a docked split) the cursor must come
    -- back, and re-hide on return. A list-style panel hides it; any other window shows it; the bar-menu
    -- container manages its own.
    api.nvim_create_autocmd("WinEnter", {
        group = state.augroup,
        callback = function()
            if state._closed then
                return
            end
            local w = api.nvim_get_current_win()
            if w == state.container_win then
                set_blur(false)
                -- Native window nav landed on the chrome split (e.g. `<C-w>j` from the editor above) — the
                -- user means "step into the panel". Land on the FIRST sector (the top header bar) so entry
                -- is step-by-step (header → center → footer via `<C-j>`), not a jump straight to the center.
                -- A frame-driven bar focus sets `_focusing_bar`, so it stays on the chrome as intended.
                if not state._focusing_bar then
                    vim.schedule(function()
                        if not state._closed and api.nvim_get_current_win() == state.container_win then
                            focus_sector(state, 1)
                        end
                    end)
                end
                return
            end
            for _, pan in ipairs(state.panels) do
                if pan.win == w then
                    set_blur(false)
                    cursor.update() -- panel ft decides (hide-cursor list vs editable preview)
                    return
                end
            end
            -- Focus left the frame entirely → clear the selection highlight; the cursor module shows the
            -- cursor again (the editor's normal-ft buffer is current now).
            set_blur(true)
            cursor.update()
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
    -- Let providers release any external state before we drop the windows (the frame's own scratch panel
    -- buffers are deleted below, taking their keymaps/extmarks with them, but a provider may hold things
    -- outside them — e.g. autocommands, or keymaps on a real buffer).
    for _, pan in ipairs(state.panels or {}) do
        if pan.provider and pan.provider.on_close then
            pcall(pan.provider.on_close, pan)
        end
    end
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
    cursor.update() -- the frame's hide-cursor buffers are gone → show the cursor in the editor again
    if state.cfg.on_close then
        pcall(state.cfg.on_close)
    end
end

--- NATIVE split panel: a single block as a REAL split window (NOT a float over a container). For a
--- persistent, navigable side tree (e.g. the lsp outline) this keeps the panel IN the native window
--- layout, so `<C-w>h/j/k/l/w` moves in and out of it AND buffer changes redraw like any window (a float
--- panel reflects neither reliably). 1 block only — the title is a centred winbar; there are no header/
--- footer bars in this mode. The provider interface (render / update / keys / cursorline / filetype /
--- on_close) is reused verbatim, only the WINDOW is real instead of a float.
---@param state table
local function open_native_split(state)
    register_frame_ft()
    local cfg = state.cfg
    local pan = state.panels[1]
    if not pan then
        return
    end
    local dock = cfg.dock or "right"
    local horiz = dock == "below" or dock == "above"

    -- Size from the provider's natural size ⊕ the explicit cfg.width/height (fraction ≤1 or a count).
    local sw, sh = 20, 1
    if pan.provider and pan.provider.size then
        local ok, w, h = pcall(pan.provider.size)
        if ok then
            sw, sh = w or sw, h or sh
        end
    end
    local function dim(fixed, nat, total)
        if not fixed then
            return nat
        end
        return fixed <= 1 and math.floor(total * fixed) or math.floor(fixed)
    end
    local width = math.max(1, dim(cfg.width, sw, vim.o.columns))
    local height = math.max(1, dim(cfg.height, sh, vim.o.lines))

    pan.buf = api.nvim_create_buf(false, true)
    vim.bo[pan.buf].bufhidden = "wipe"
    -- The provider names its filetype (drives cursor hiding via the user's panel_ft + filetype detection);
    -- else a hide_cursor provider gets FRAME_FT so the cursor module hides while it is current.
    if pan.provider and pan.provider.filetype then
        vim.bo[pan.buf].filetype = pan.provider.filetype
    elseif pan.provider and pan.provider.hide_cursor then
        vim.bo[pan.buf].filetype = FRAME_FT
    end

    pan.win = api.nvim_open_win(pan.buf, cfg.enter == true, {
        split = dock,
        win = -1, -- pin to the far edge of the tabpage
        width = (not horiz) and width or nil,
        height = horiz and height or nil,
        style = "minimal",
    })
    if horiz then
        vim.wo[pan.win].winfixheight = true
    else
        vim.wo[pan.win].winfixwidth = true
    end
    vim.wo[pan.win].wrap = false
    if pan.provider and pan.provider.cursorline then
        -- A native docked panel (the outline) uses the NEUTRAL cursorline, not the popup-list yellow.
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiCursorLine"
        vim.wo[pan.win].cursorline = true
    else
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal"
    end
    -- Title → a centred winbar (the whole bar carries the blue peek-title tint).
    local tt = title_text(cfg.title)
    if tt ~= "" then
        vim.wo[pan.win].winhighlight = vim.wo[pan.win].winhighlight
            .. ",WinBar:LvimUiPeekTitle,WinBarNC:LvimUiPeekTitle"
        vim.wo[pan.win].winbar = "%=" .. tt .. "%="
    end

    state._geom =
        { panels = { { width = api.nvim_win_get_width(pan.win), height = api.nvim_win_get_height(pan.win) } } }
    pan.refresh = function()
        render_panel(state, 1)
    end
    pan.frame = state
    render_panel(state, 1)

    -- Focus / block accessors. Navigation is NATIVE (`<C-w>`) — no sectors, bars or chrome to drive.
    state.center_panel = 1
    state.focus_panel = function()
        if pan.win and api.nvim_win_is_valid(pan.win) then
            api.nvim_set_current_win(pan.win)
            cursor.update()
        end
    end
    state.focus_block = function()
        state.focus_panel()
    end
    state.panel = function() end
    state.sector = function() end
    state.refresh_chrome = function() end
    state.map_hotkeys = function() end
    state.toggle_header = function()
        return false
    end
    state.to_origin = function()
        if state.origin and api.nvim_win_is_valid(state.origin) then
            api.nvim_set_current_win(state.origin)
        end
    end

    -- Keys: the provider's own keys + close_keys + consumer keymaps on the panel buffer. No sector/menu
    -- nav keys — the panel is a real window, so `<C-w>` already moves in and out of it.
    local function map(lhs, fn)
        for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            vim.keymap.set("n", l, fn, { buffer = pan.buf, nowait = true, silent = true })
        end
    end
    if pan.provider and pan.provider.keys then
        pcall(pan.provider.keys, map, pan, state)
    end
    for _, ck in ipairs(cfg.close_keys or {}) do
        map(ck, state.close)
    end
    for _, km in ipairs(cfg.keymaps or {}) do
        map(km.key, function()
            km.run(state)
        end)
    end

    -- Tear down when the window closes; re-render content on resize (the window itself resizes natively).
    state.augroup = api.nvim_create_augroup("LvimUiFrameNative_" .. pan.win, { clear = true })
    api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        pattern = tostring(pan.win),
        callback = function()
            state.close()
        end,
    })
    api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = state.augroup,
        callback = function()
            if not state._closed and pan.win and api.nvim_win_is_valid(pan.win) then
                state._geom.panels[1] =
                    { width = api.nvim_win_get_width(pan.win), height = api.nvim_win_get_height(pan.win) }
                render_panel(state, 1)
            end
        end,
    })
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

    -- Sizing: `cfg.size = { width/height = { auto, min, max, fixed } }` → the per-axis fields the geometry
    -- uses. `auto` fits the content (within max); else `fixed`; each a screen fraction ≤1 or an absolute
    -- count. `height.min` = minimum VISIBLE content rows; `width.min` clamps the float width.
    local size = cfg.size or {}
    local sw, sh = size.width or {}, size.height or {}
    cfg.auto_width, cfg.width, cfg.max_width, cfg.min_width = sw.auto, sw.fixed, sw.max, sw.min
    cfg.auto_height, cfg.height, cfg.max_height, cfg.min_content_height = sh.auto, sh.fixed, sh.max, sh.min

    -- content.blocks → panels: each block carries an `id`, a `provider`, its own width (`size.width.fixed`
    -- = a weight; absent = flex/auto), and an optional `border`.
    local panels = {}
    for i, blk in ipairs((cfg.content or {}).blocks or {}) do
        local bw = (blk.size or {}).width or {}
        panels[i] = { id = blk.id, provider = blk.provider, weight = bw.fixed, border = blk.border }
    end

    -- A FLOAT carries the brand as its border title (built in open_windows). A SPLIT has no border, so the
    -- title becomes the top CONTENT row of the chrome instead (the icon + text, flattened).
    local hbands = build_bands(cfg.header, false)
    if cfg.mode == "split" then
        local t = cfg.title
        local s = (type(t) == "table" and ((t.icon and t.icon .. " " or "") .. (t.text or ""))) or (t or "")
        if s ~= "" then
            table.insert(hbands, 1, { meta = s, hl = "LvimUiPeekTitle" })
        end
    end

    local state = {
        cfg = cfg,
        origin = api.nvim_get_current_win(),
        panels = panels,
        header_bands = hbands,
        footer_bands = build_bands(cfg.footer, true),
    }
    state.close = function()
        close(state)
    end
    -- A `native` split is a REAL window (not a float over a container) — for a navigable persistent side
    -- panel; everything else (modal float, docked-modal peek) uses the float chassis.
    if cfg.mode == "split" and cfg.native then
        open_native_split(state)
    else
        open_windows(state)
    end
    return state
end

return M
