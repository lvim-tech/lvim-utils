-- lvim-utils.ui.surface: the ONE windowed-UI chassis. A vertical stack of sectors —
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
-- A `position = "cmdline"` float OWNS the command-line region (grows `cmdheight` so heirline / a global
-- statusline stay above it, floats over those rows). Optionally HOSTED: pass `host = fn(height) -> rect` and
-- the surface, instead of growing cmdheight itself, reserves `height` rows in that host zone (the msgarea,
-- which owns cmdheight) and lays out over the returned rect — so the host composes other content (messages)
-- BELOW it in the same region. Wire the host segment's reflow to `st.reposition(rect)` so the surface follows.
--
---@module "lvim-utils.ui.surface"

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
    sector_next = "<C-j>", -- header · center · footer (down), from anywhere (the PREVIEW is skipped)
    sector_prev = "<C-k>", -- (up)
    panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview) — the ONLY way onto the preview
    panel_next = "<C-l>", -- next center panel (right) — only while a center panel is focused
    panel_prev = "<C-h>", -- previous center panel (left)
    menu_prev = { "h", "<Left>" },
    menu_next = { "l", "<Right>" },
    menu_confirm = { "<CR>", "<Space>" },
    -- OPEN the focused selection (the chassis default `open(mode)` — opens the focused panel provider's
    -- `selection()` item by `path`/`lnum`/`col`, or `cfg.on_open(mode, item)` when the consumer overrides):
    open = "<CR>", -- in the window the frame was opened from
    open_split = "<C-x>", -- in a horizontal split
    open_vsplit = "<C-v>", -- in a vertical split
    open_tab = "<C-t>", -- in a new tab
    -- ROTATE the preview through five positions (right → below → left → above → dynamic → …), live:
    preview_next = "<C-n>",
    preview_prev = "<C-p>",
    toggle_preview = "<C-e>", -- HIDE ↔ show the preview (no-op while the preview is `dynamic`)
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
                no_hotkey = it.no_hotkey, -- carry the display-only flag so map_hotkeys skips it (no keymap)
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
local function build_bands(spec, footer, add_air)
    spec = spec or {}
    local bands = {}
    for _, bar in ipairs(spec.bars or {}) do
        if bar.title_counter then
            -- A title + right-aligned counter CONTENT row (title left, count right) — a dynamic `count`
            -- function is re-evaluated on every chrome render. Passed through with its fields intact.
            bands[#bands + 1] = bar
        elseif bar.text ~= nil then
            bands[#bands + 1] = { meta = bar.text, hl = bar.hl or (footer and "LvimUiSubtitle" or "LvimUiPeekTitle") }
        elseif bar.input then
            -- An editable INPUT band — a focusable 1-row editable window the frame creates over this row
            -- (see open_windows). It reserves a row like a meta line; the consumer drives it via
            -- `on_change(query)` (fired live on type) and the band's own insert-mode `keys(buf, st)`.
            bands[#bands + 1] = {
                input = true,
                prompt = bar.prompt,
                prompt_hl = bar.prompt_hl, -- the prompt badge highlight (else a neutral default)
                input_hl = bar.input_hl, -- the typed-area Normal highlight (else the peek normal)
                on_change = bar.on_change,
                keys = bar.keys,
                filetype = bar.filetype,
                scope_panel = bar.scope_panel, -- narrow the prompt to a single panel's columns (else full width)
                scope_id = bar.scope_id, -- … or to the panel with this id (rotation-safe — tracks it as it moves)
            }
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
    elseif add_air ~= false then
        table.insert(bands, 1, { meta = "" }) -- 1 air row under the (border-)title (skip when add_air=false)
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
    -- titles render UPPERCASE everywhere (the canon — matches the ui.bar title bars); the icon glyph is left
    if type(title) == "string" then
        return title ~= "" and { box(title:upper(), {}, "LvimUiPeekTitle") } or nil
    end
    if type(title) ~= "table" then
        return nil
    end
    local st = title.style or {}
    local chunks = {}
    local ic = box(title.icon, st.icon or {}, "LvimUiPeekTitleIcon")
    local tc = box(title.text and tostring(title.text):upper() or nil, st.text or {}, "LvimUiPeekTitle")
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

--- The largest `cmdheight` the current window layout can give up without "E36: Not enough room": the
--- non-floating windows must keep their minimum rows. Walks `winlayout()` — a "col" stacks rows (heights
--- ADD), a "row" sits side by side (heights are the MAX); each leaf needs `winminheight` + its statusline
--- (per-window when `laststatus` 1/2) + its winbar. Plus the global chrome (tabline, the `laststatus=3`
--- global statusline). The cmdline region can take everything left over.
---@return integer
local function max_cmdheight()
    local ls = vim.o.laststatus
    local per_win_status = (ls == 1 or ls == 2) and 1 or 0 -- a statusline on each window
    local wmh = math.max(1, vim.o.winminheight)
    local function need(node)
        if not node then
            return wmh + per_win_status
        end
        local kind, items = node[1], node[2]
        if kind == "leaf" then
            local win = items
            local wb = (api.nvim_win_is_valid(win) and vim.wo[win].winbar ~= "") and 1 or 0
            return wmh + per_win_status + wb
        end
        local n = 0
        for _, child in ipairs(items or {}) do
            local c = need(child)
            n = (kind == "col") and (n + c) or math.max(n, c)
        end
        return n
    end
    local tabs = vim.api.nvim_list_tabpages()
    local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #tabs > 1)) and 1 or 0
    local global_status = (ls == 3) and 1 or 0
    local reserve = need(vim.fn.winlayout()) + tabline + global_status
    return math.max(1, vim.o.lines - reserve)
end

--- Set `cmdheight` to `h`, clamped to what the layout allows (`max_cmdheight`), then DECREMENT on the rare
--- "E36: Not enough room" (the estimate is conservative but window minima can be quirky) until it sticks.
--- Returns the value actually applied — the geometry uses THAT so the container float matches the region.
---@param h integer
---@return integer
local function set_cmdheight(h)
    h = math.max(1, math.min(h, max_cmdheight()))
    vim.o.cmdheight = h
    return vim.o.cmdheight
end

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
    -- Panels stack VERTICALLY (top→bottom, full width, height grows) when direction == "vertical"; else
    -- they sit side-by-side (the default). Used for the navigator's above/below preview.
    local vertical = cfg.direction == "vertical"

    -- Per-panel border insets + natural content size (provider.size()). Track BOTH axes so either layout
    -- direction can auto-size: sum along the stacking axis, max across it.
    local pin = {}
    local nat_w_sum, nat_w_max, nat_h_sum, nat_h_max = 0, 1, 0, 1
    local border_cols, border_rows, max_vborder, max_hborder = 0, 0, 0, 0
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
        nat_w_max = math.max(nat_w_max, pl + sw + pr)
        nat_h_sum = nat_h_sum + pt + sh + pbm
        nat_h_max = math.max(nat_h_max, sh)
        border_cols = border_cols + pl + pr
        border_rows = border_rows + pt + pbm
        max_vborder = math.max(max_vborder, pt + pbm) -- so min_content counts VISIBLE rows, not the border
        max_hborder = math.max(max_hborder, pl + pr)
    end

    -- Widest content drives auto_width: the widest bar band vs the panels' natural footprints.
    local bars_w = 0
    for _, band in ipairs(state.header_bands) do
        bars_w = math.max(bars_w, band.buttons and uibar.width(band.buttons) or util.dw(band.meta or ""))
    end
    local footer_w = 0
    for _, band in ipairs(state.footer_bands) do
        local bw = band.buttons and uibar.width(band.buttons) or 0
        bars_w = math.max(bars_w, bw)
        footer_w = math.max(footer_w, bw) -- the action footer must FIT (never scroll under the auto-width cap)
    end
    -- Stacking axis sums; cross axis is the max. Horizontal: width sums (+ column separators), height = the
    -- tallest panel. Vertical: width = the widest panel, height sums (+ row separators).
    local content_w = vertical and math.max(bars_w, nat_w_max) or math.max(bars_w, nat_w_sum + sep_w * (n - 1))

    -- Container CONTENT width/height (W excludes the container's own border columns). A docked split
    -- passes its window's ACTUAL width in `place.W` (full width for a below/above dock).
    local W = place and place.W or util.axis_size(cfg.auto_width, cfg.width, cfg.max_width, content_w, vim.o.columns)
    if not place and cfg.min_width then
        local mw = cfg.min_width <= 1 and math.floor(vim.o.columns * cfg.min_width) or cfg.min_width
        W = math.max(W, math.floor(mw))
    end
    -- The footer action bar must fit: its buttons should never scroll just because the auto-width cap is
    -- tighter than them. Widen to the footer, up to the screen.
    if not place and footer_w > 0 then
        W = math.max(W, math.min(footer_w, vim.o.columns - 4))
    end
    -- A `scope_panel` / `scope_id` input band does NOT take its own header row — it overlays its panel's top
    -- (winbar) row instead, so it doesn't count toward the header height.
    local header_h = 0
    for _, b in ipairs(state.header_bands) do
        if not b.scope_panel and not b.scope_id then
            header_h = header_h + 1
        end
    end
    local footer_h = #state.footer_bands
    local content_h = header_h + footer_h + (vertical and (nat_h_sum + sep_w * (n - 1)) or nat_h_max)
    -- A split takes the full height nvim gives it (place.H); a float sizes per auto/explicit height. The
    -- center never shrinks below `min_content_height` VISIBLE rows — counted on the panel content, so the
    -- panel borders are added on top (the header/footer bands are fixed-height). Stacked panels need room
    -- for ALL of them. `min_h` is the resulting minimum container height, exported for the resize clamp.
    local min_center = vertical and (n * math.max(1, cfg.min_content_height or 1) + border_rows + sep_w * (n - 1))
        or (math.max(1, cfg.min_content_height or 1) + max_vborder)
    local min_h = header_h + footer_h + min_center
    local H = place and place.H or util.axis_size(cfg.auto_height, cfg.height, cfg.max_height, content_h, vim.o.lines)
    H = math.max(H, min_h)

    -- Float placement. Split: the container's actual screen position (passed in `place`). Otherwise by
    -- `cfg.position`: "cursor"/"win" via util.calc_pos (cursor = below the cursor when it fits, else above;
    -- win = centred in the current window), "bottom"/"top" docked to that edge (full width), else centred
    -- on the whole editor. calc_pos takes the TOTAL footprint (content + the container's border insets).
    local row, col
    if place then
        row, col = place.row, place.col
    elseif cfg.position == "cursor" or cfg.position == "win" then
        row, col = util.calc_pos(H + ct + cb, W + cl + cr, cfg.position)
    elseif cfg.position == "bottom" or cfg.position == "top" then
        W = vim.o.columns - cl - cr
        col = 0
        row = cfg.position == "bottom" and math.max(0, vim.o.lines - H - ct - cb - 1) or 0
    elseif cfg.position == "left" or cfg.position == "right" then
        -- Dock to a side: full editor height (minus the cmdline row), fixed width (`size.width`) on that edge.
        H = math.max(min_h, vim.o.lines - ct - cb - 1)
        row = 0
        col = cfg.position == "right" and math.max(0, vim.o.columns - W - cl - cr) or 0
    elseif cfg.position == "cmdline" then
        -- The CMDHEIGHT region: full width, docked over the bottom `cmdheight` rows (grown to H in
        -- open_windows). Unlike "bottom" (which leaves the cmdline row free), the surface IS the cmdline
        -- area, so a global statusline / heirline stays above it — hence no `- 1`.
        W = vim.o.columns - cl - cr
        col = 0
        -- Clamp to the largest cmdheight the window layout can give up without "E36: Not enough room": the
        -- non-floating windows must keep their minimum rows. (A tall preview must not grow the area past the
        -- room available between the splits above it.)
        H = math.min(H, max_cmdheight())
        H = math.max(H, min_h)
        row = math.max(0, vim.o.lines - H - ct - cb)
    else
        row = math.max(1, math.floor((vim.o.lines - H) / 2 - 1))
        col = math.max(1, math.floor((vim.o.columns - W) / 2))
    end
    local cc_row, cc_col = row + ct, col + cl
    local center_top = cc_row + header_h
    local center_h = math.max(min_center, H - header_h - footer_h)

    -- Distribute the center across panels along the STACKING axis (width when horizontal, height when
    -- vertical): weighted panels take their share, weightless ones split the remainder (auto ⇒ each takes
    -- its natural size); the cross axis is the full center extent. `dividers` are column offsets when
    -- horizontal, row offsets when vertical (render_chrome draws them per `L.vertical`).
    local out, dividers = {}, {}
    --- Share `avail` across the panels by weight / auto-natural / flex (the common allocation for both axes).
    ---@param avail integer
    ---@param natural fun(i: integer): integer
    ---@param auto boolean
    ---@return integer[]
    local function allocate(avail, natural, auto)
        local sizes, fixed, flex, auto_idx = {}, 0, {}, {}
        for i, pan in ipairs(panels) do
            local wgt = pan.weight
            if auto and not wgt then
                sizes[i] = natural(i)
                fixed = fixed + sizes[i]
                auto_idx[#auto_idx + 1] = i
            elseif wgt then
                sizes[i] = math.max(1, wgt <= 1 and math.floor(avail * wgt) or math.floor(wgt))
                fixed = fixed + sizes[i]
            else
                flex[#flex + 1] = i
            end
        end
        -- OVERFLOW: the natural (auto) panels together exceed `avail` — the area hit its height cap (e.g. a long
        -- list + a preview both wanting `max_rows`). Shrink the auto panels PROPORTIONALLY so the stack fits
        -- exactly, instead of spilling past the container (which pushed the divider + the scoped input band down
        -- into the list, and the last panel off-screen).
        if fixed > avail and #flex == 0 and #auto_idx > 0 then
            -- The auto panels together exceed `avail` (the stack hit the area cap / the room left between the
            -- splits). Shrink them to fit EXACTLY. `shrink_first` panels (the preview) give up their rows BEFORE
            -- the rest, so a PROTECTED panel (the list) keeps its own content and its height never jumps as you
            -- navigate files of different lengths; within a group the shrink is proportional. Every panel keeps
            -- at least 1 row. (No marks ⇒ one proportional shrink over all of them, the old behaviour.)
            local first, rest = {}, {}
            for _, i in ipairs(auto_idx) do
                local g = panels[i].shrink_first and first or rest
                g[#g + 1] = i
            end
            -- Remove `amount` rows from `group`, proportional to each panel's room above 1; return the remainder.
            local function shrink(group, amount)
                local pool = 0
                for _, i in ipairs(group) do
                    pool = pool + (sizes[i] - 1)
                end
                local take = math.min(amount, math.max(0, pool))
                local acc = 0
                for k, i in ipairs(group) do
                    local share = (k < #group) and math.floor(take * (sizes[i] - 1) / math.max(1, pool)) or (take - acc) -- the last panel takes the remainder (no rounding gap)
                    sizes[i] = math.max(1, sizes[i] - share)
                    acc = acc + share
                end
                return amount - take
            end
            local over = shrink(first, fixed - avail)
            over = shrink(rest, over)
            fixed = avail + math.max(0, over)
        end
        local rest = math.max(0, avail - fixed)
        if #flex > 0 then
            local each = math.max(1, math.floor(rest / #flex))
            for _, i in ipairs(flex) do
                sizes[i] = each
            end
            sizes[flex[#flex]] = sizes[flex[#flex]] + (rest - each * #flex)
        elseif n > 0 then
            sizes[n] = sizes[n] + rest
        end
        return sizes
    end

    if vertical then
        local heights = allocate(math.max(n, center_h - border_rows - sep_w * (n - 1)), function(i)
            return pin[i].nat_h
        end, cfg.auto_height)
        -- Lay footprints top→bottom; each panel is full center width; dividers sit in the row gaps.
        local y = center_top
        for i = 1, n do
            local pi = pin[i]
            out[i] = {
                width = math.max(1, W - pi.l - pi.r),
                height = heights[i],
                row = y,
                col = cc_col,
                border = pi.b,
            }
            y = y + pi.t + heights[i] + pi.bo
            if i < n and sep_w > 0 then
                dividers[#dividers + 1] = y - center_top
                y = y + sep_w
            end
        end
    else
        local widths = allocate(math.max(n, W - border_cols - sep_w * (n - 1)), function(i)
            return pin[i].nat_w
        end, cfg.auto_width)
        -- Lay footprints left→right; each panel's col is its LEFT-BORDER position; dividers sit in the gaps.
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
        vertical = vertical, -- dividers are ROW offsets (a horizontal rule) when true, else column offsets
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

    -- A center row. Horizontal layout: vertical separator glyphs at the divider COLUMNS (the 1-col gaps
    -- between side-by-side panels). Vertical layout: the whole row is a separator rule when it IS a divider
    -- ROW (the 1-row gap between stacked panels), else blank. The panels (floats) overlay the rest.
    local function center_line(center_off)
        if not sep_char then
            return string.rep(" ", W)
        end
        if L.vertical then
            return divider_set[center_off] and string.rep(sep_char, W) or string.rep(" ", W)
        end
        local cells = {}
        for c = 0, W - 1 do
            cells[c + 1] = divider_set[c] and sep_char or " "
        end
        return table.concat(cells)
    end

    local lines = {}
    for i = 1, H do
        lines[i] = (i > L.header_h and i <= H - L.footer_h) and center_line(i - L.header_h - 1) or string.rep(" ", W)
    end

    -- Place each header/footer band, recording where its bar buttons land (for the next layer's
    -- selection + hit-testing). `placements` holds post-write highlight ops { row0, c0, c1, hl, prio }.
    state.bands = {} -- flat sector list of the bar bands
    local placements = {}

    local function lay_band(ln, band, where)
        if band.input then -- an editable input band — its overlay window draws the row; leave it blank
            return
        end
        if band.title_counter then
            -- A title (left) + a re-evaluated COUNTER (right) — rendered THROUGH ui.bar (the title is its
            -- left prefix, the counter a right-aligned item), so it matches the message bar exactly.
            local cnt = band.count and tostring((type(band.count) == "function" and band.count()) or band.count) or ""
            local items = {}
            if cnt ~= "" then
                items[1] = {
                    type = "button",
                    text = cnt,
                    style = { text = { padding = { 1, 1 }, normal = band.count_hl or "LvimUiSubtitle" } },
                }
            end
            local res = uibar.render({
                items = items,
                width = W,
                align = "right",
                title = band.text,
                title_hl = band.hl or "LvimUiPeekTitle",
            })
            lines[ln] = res.line
            placements[#placements + 1] = { ln - 1, 0, #res.line, "LvimUiBarFill", 150 } -- the continuous row strip
            for _, sp in ipairs(res.spans) do
                placements[#placements + 1] = { ln - 1, sp[1], sp[2], sp[3], 200 }
            end
            return
        end
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
        -- A `_follow` band keeps its `_sel` in view even when UNFOCUSED — the TAB bar scrolls to the active tab
        -- when it's switched from the body (h/l), so an off-screen tab doesn't go active-but-hidden. The hover
        -- styling still only shows when focused (`hover = sel`); the active tab carries its own `active` styling.
        local scroll = sel or (band._follow and band._sel) or nil
        local res = uibar.render({
            items = band.buttons or {},
            width = W,
            align = band.align or "center",
            chevrons = band.chevrons or state.cfg.chevrons,
            sel = scroll,
            hover = sel,
            off = band._off,
        })
        band._off = res.off
        lines[ln] = res.line
        -- A continuous full-width bg STRIP under the buttons, so the whole bar row reads as one tinted bar
        -- (the buttons + chevrons sit ON it). Priority below the button/chevron spans (200) so they show through.
        -- `band.fill = false` drops the strip (the buttons then float on the bare panel bg).
        if band.fill ~= false then
            placements[#placements + 1] = { ln - 1, 0, #res.line, "LvimUiBarFill", 150 }
        end
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
        local sep_hl = util.resolve_hl(state.cfg.separator_hl or "LvimUiPeekBorder")
        if L.vertical then
            -- VERTICAL stack: each divider is a full-width ROW ("─") at `header_h + d` — highlight the WHOLE line
            -- (a `d` here is a ROW offset, not a column), so the rule reads with `sep_hl` exactly like the
            -- horizontal "│" instead of the default fg.
            for _, d in ipairs(L.dividers) do
                pcall(api.nvim_buf_set_extmark, state.container_buf, NS, L.header_h + d, 0, {
                    end_col = W * #sep_char,
                    hl_group = sep_hl,
                })
            end
        else
            -- HORIZONTAL: each divider is a COLUMN ("│") — highlight it on every center row.
            for ln = L.header_h, H - L.footer_h - 1 do
                for _, d in ipairs(L.dividers) do
                    pcall(api.nvim_buf_set_extmark, state.container_buf, NS, ln, d, {
                        end_col = d + #sep_char,
                        hl_group = sep_hl,
                    })
                end
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
        if h[3] == -1 then -- a FULL-ROW span: the bg reaches the window edge (hl_eol), for row striping
            pcall(api.nvim_buf_set_extmark, pan.buf, NS, h[1], 0, {
                end_row = h[1] + 1,
                hl_group = util.resolve_hl(h[4]),
                hl_eol = true,
                priority = h[5] or 200,
            })
        else
            pcall(api.nvim_buf_set_extmark, pan.buf, NS, h[1], h[2], {
                end_col = h[3],
                hl_group = util.resolve_hl(h[4]),
                priority = h[5] or 200,
            })
        end
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
    -- DYNAMIC peek: the float sits ABOVE everything, so `<C-k>` enters it only from the TOP sector — from the
    -- list you first reach the header (the filter bar), then one more `<C-k>` steps up into the float to edit.
    if
        state.preview_side == "dynamic"
        and dir < 0
        and cur == 1
        and state.dyn
        and state.dyn.win
        and api.nvim_win_is_valid(state.dyn.win)
    then
        api.nvim_set_current_win(state.dyn.win)
        return
    end
    -- VERTICAL stack: the center panels are stacked top↔bottom, so `<C-j>`/`<C-k>` step THROUGH them (the
    -- preview is reachable up/down, not only via panel-nav) before continuing to the next sector.
    if state.cfg.direction == "vertical" and state.sectors[cur] and state.sectors[cur].kind == "center" then
        local np = #state.panels
        local cp = state.center_panel or 1
        if (dir > 0 and cp < np) or (dir < 0 and cp > 1) then
            state.center_panel = cp + dir
            focus_sector(state, cur)
            return
        end
    end
    if (dir < 0 and cur == 1) or (dir > 0 and cur == n) then
        -- Top/bottom edge of a docked split → step VERTICALLY out to the editor (matches a below/above dock).
        if escape_to_neighbor(state, dir < 0 and "k" or "j") then
            return
        end
        -- Bottom edge of a HOSTED float → hand focus DOWN to the host zone below it (the messages composed
        -- under a finder). Remember THIS sector (the footer) so when focus returns, we land back on it (not on
        -- the header, the WinEnter default) — symmetric up/down navigation.
        if dir > 0 and state.cfg.on_escape_below then
            state._return_sector = cur
            if state.cfg.on_escape_below() then
                return
            end
            state._return_sector = nil
        end
        -- Top edge → hand focus UP to the editor above (the mirror of on_escape_below): stop here instead of
        -- WRAPPING down to the footer. Without a handler we still stop (no wrap) rather than jump to the bottom.
        if dir < 0 and state.cfg.on_escape_above then
            state.cfg.on_escape_above()
            return
        end
        return -- at an edge with no escape handler → STOP (never WRAP around to the opposite end)
    end
    local target = ((cur - 1 + dir) % n) + 1
    -- Entering the CENTER: horizontal lands on the PRIMARY panel (1; the preview is reached by panel-nav). A
    -- VERTICAL stack lands on the panel at the edge we entered from — top (1) coming DOWN, bottom (last) coming
    -- UP — so the next `<C-j>`/`<C-k>` keeps walking through the stack.
    if state.sectors[target] and state.sectors[target].kind == "center" then
        state.center_panel = (state.cfg.direction == "vertical" and dir < 0) and #state.panels or 1
    end
    focus_sector(state, target)
end

--- Toggle the focused CENTER panel (list ⇄ preview, cycling when there are more) — `panel_toggle` (Tab). The
--- vertical sector nav always lands on panel 1, so this is the ONLY way onto the preview.
---@param state table
local function panel_toggle(state)
    local np = #state.panels
    if np <= 1 then
        return
    end
    state.center_panel = ((state.center_panel or 1) % np) + 1
    for si, sec in ipairs(state.sectors) do
        if sec.kind == "center" then
            focus_sector(state, si) -- focus_sector reads center_panel
            return
        end
    end
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

--- The item the focused selection points at — the first center panel whose provider exposes `selection()`
--- (the list; the preview has none). Drives the default `open`.
---@param state table
---@return table? item
local function focused_selection(state)
    for _, pan in ipairs(state.panels) do
        if pan.provider and pan.provider.selection then
            local ok, it = pcall(pan.provider.selection)
            if ok and it then
                return it
            end
        end
    end
    return nil
end

--- Default OPEN action — open the focused selection in `mode` ("window"|"split"|"vsplit"|"tab"). A consumer
--- overrides the whole behaviour with `cfg.on_open(mode, item)`; otherwise an item carrying `path` (+ optional
--- `lnum`/`col`) is opened with `nvim_win_set_buf` (NOT `:edit`, so an unsaved editable preview can't block it
--- with E37) in the origin window, or a fresh split/vsplit/tab. The frame closes first either way.
---@param state table
---@param mode string
local function default_open(state, mode)
    local item = focused_selection(state)
    local origin = state.origin
    if state.cfg.on_open then
        state.close()
        state.cfg.on_open(mode, item)
        return
    end
    if not (item and item.path) then
        return
    end
    state.close()
    if origin and api.nvim_win_is_valid(origin) then
        api.nvim_set_current_win(origin)
    end
    if mode == "split" then
        vim.cmd("split")
    elseif mode == "vsplit" then
        vim.cmd("vsplit")
    elseif mode == "tab" then
        vim.cmd("tabnew")
    end
    local buf = vim.fn.bufadd(item.path)
    vim.fn.bufload(buf)
    api.nvim_win_set_buf(0, buf)
    pcall(api.nvim_win_set_cursor, 0, { item.lnum or 1, math.max(0, (item.col or 1) - 1) })
    pcall(vim.cmd, "normal! zz")
end

--- Set the DOCKED container height from `cfg.preview_heights` ( `{ horizontal, vertical }` — a value ≤ 1 is a
--- fraction of the screen, > 1 an absolute row count) for the side's stack direction: `horizontal` when the
--- preview sits left/right, `vertical` when it sits above/below. No-op for a float or when the consumer didn't
--- ask for managed heights.
---@param state table
---@param side string
local function apply_dock_height(state, side)
    if not (state.cfg.host or state.cfg.mode == "split") then
        return -- only the DOCKED layouts (hosted msgarea zone, or a non-hosted bottom/area split) have a height
    end
    local hs = state.cfg.preview_heights
    local v = hs and ((side == "above" or side == "below") and hs.vertical or hs.horizontal)
    if type(v) ~= "number" then
        return
    end
    local rows = math.max(1, v <= 1 and math.floor(vim.o.lines * v) or math.floor(v))
    -- AUTO-fit the docked area to its content (each panel fits ITS OWN content, capped at `max_rows`), bounded
    -- by the configured value. When the room (or this cap) can't hold the stack, the overflow shrink in
    -- compute_geom keeps the LIST at its content and shrinks the PREVIEW first (it scrolls) — so the list height
    -- never jumps as you navigate files of different lengths. (cfg.size is only normalised once at open, so we
    -- set the fields compute_geom reads directly; relayout re-reserves the host.)
    state.cfg.auto_height = true
    state.cfg.height = nil
    state.cfg.max_height = rows
end

--- Install the chassis keymaps. Panel buffers get sector cycling + the provider's own keys; the
--- container buffer (bar-menu mode) gets selection move / confirm + sector cycling. `cfg.close_keys`
--- close a modal frame from anywhere.
---@param state table
local function set_keys(state)
    -- Precedence: the hardcoded fallback < the GLOBAL `ui.keys` config < this surface's own `cfg.keys`.
    local ok_cfg, cfg = pcall(require, "lvim-utils.config")
    local global_keys = (ok_cfg and cfg.ui and cfg.ui.keys) or {}
    local K = vim.tbl_extend("force", DEFAULT_KEYS, global_keys, state.cfg.keys or {})
    local used = {} -- used[buf][lhs] = true — the keys we actually bind, so `lock_keys` can <Nop> the rest
    local function map(buf, lhs, fn)
        used[buf] = used[buf] or {}
        for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, silent = true })
            used[buf][l] = true
        end
    end
    -- `cfg.lock_keys`: a MODAL panel — only the keys we bound act; every other normal-mode key (motions,
    -- scrolls, edits, search) is `<Nop>`-ed so a stray press can't move the cursor / scroll / edit the panel.
    -- The cmdline `:` is kept as an escape hatch. Run AFTER the panel binds (so `used` is populated) and BEFORE
    -- map_hotkeys (so a button hotkey re-maps OVER the `<Nop>`).
    local function lock_panel(buf)
        local u = used[buf] or {}
        local function nop(lhs)
            if not u[lhs] then
                pcall(vim.keymap.set, "n", lhs, "<Nop>", { buffer = buf, nowait = true, silent = true })
            end
        end
        for i = 33, 126 do
            local ch = string.char(i)
            if ch ~= ":" then -- single printable keys (a stray `g`/`z` prefix is killed too → no `gg`/`zz`)
                nop(ch)
            end
        end
        for i = string.byte("a"), string.byte("z") do
            nop("<C-" .. string.char(i) .. ">") -- the Ctrl-letter combos (scroll, etc.)
        end
        for _, sk in ipairs({ "<Up>", "<Down>", "<Left>", "<Right>", "<PageUp>", "<PageDown>", "<Home>", "<End>" }) do
            nop(sk)
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
        map(pan.buf, K.panel_toggle, function()
            panel_toggle(state)
        end)
        -- OPEN the focused selection (a provider's own `keys` below may still override these, e.g. <CR>)
        map(pan.buf, K.open, function()
            default_open(state, "window")
        end)
        map(pan.buf, K.open_split, function()
            default_open(state, "split")
        end)
        map(pan.buf, K.open_vsplit, function()
            default_open(state, "vsplit")
        end)
        map(pan.buf, K.open_tab, function()
            default_open(state, "tab")
        end)
        -- ROTATE the preview position (live reflow of the floats)
        map(pan.buf, K.preview_next, function()
            state.rotate_preview(1)
        end)
        map(pan.buf, K.preview_prev, function()
            state.rotate_preview(-1)
        end)
        -- HIDE ↔ show the preview (no-op while `dynamic`)
        map(pan.buf, K.toggle_preview, function()
            if state.toggle_preview then
                state.toggle_preview()
            end
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

    if state.cfg.lock_keys then -- modal: every unbound key is a no-op — the PANELS and the chrome CONTAINER
        for _, pan in ipairs(state.panels) do
            local editable = pan.provider and pan.provider.editable
            if not editable and vim.bo[pan.buf].buftype ~= "terminal" then
                lock_panel(pan.buf)
            end
        end
        -- the container is the chrome buffer (bar-menu mode) — a stray `<C-f>`/`<C-d>` on a focused bar scrolled
        -- it, pushing the header (title + bar) off the top and the footer up into its place
        lock_panel(state.container_buf)
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

--- Move the center panels + editable input bands to a computed layout `L`, then repaint the chrome. NO
--- container/cmdheight side effects — the caller has already placed the container — so it is safe to call on
--- a host-zone reflow (`reposition`) without re-reserving (which would loop).
---@param state table
---@param L table
local function place_panels(state, L)
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
    -- Re-fit the editable input bands so they follow the moved panels / header (else a resize leaves the
    -- prompt stranded). A `scope_panel` band tracks its panel's top row; a plain header band its header row.
    local _, _, _, rcl = util.insets(L.cbord)
    local hbi = 0
    for _, band in ipairs(state.header_bands) do
        -- a `scope_id` band tracks the CURRENT index of the panel with that id (rotation-safe — the input
        -- always sits over the LIST panel however the preview is rotated); else the fixed `scope_panel` index.
        local scope = band.scope_panel
        if band.scope_id then
            for i, pan in ipairs(state.panels) do
                if pan.id == band.scope_id then
                    scope = i
                    break
                end
            end
        end
        if band.input and band.win and api.nvim_win_is_valid(band.win) then
            local iw, icol, irow = L.W, L.col + rcl, L.row + L.ct + hbi
            if scope and L.panels[scope] then
                local sp = L.panels[scope]
                iw, icol, irow = sp.width, sp.col, sp.row
            end
            pcall(api.nvim_win_set_config, band.win, {
                relative = "editor",
                row = irow,
                col = icol,
                width = iw,
                height = 1,
            })
        end
        if not scope then
            hbi = hbi + 1
        end
    end
    render_chrome(state, L)
end

--- Resolve the geometry of a `cmdline`-position surface, growing the command-line region to fit it. Two
--- modes: UNHOSTED grows OUR `cmdheight` (saving the user's once, to restore on close) and floats over those
--- rows. HOSTED (`cfg.host`) instead reserves `L.H` rows in a host zone (the msgarea, which owns cmdheight)
--- and re-lays-out over the rect it hands back — so the host can compose messages BELOW us in the same
--- region. Returns the (possibly re-placed) layout.
---@param state table
---@param L table
---@return table
local function host_geom(state, L)
    if state.cfg.host then
        local rect = state.cfg.host(L.H) -- reserve L.H rows; the host grows ITS cmdheight + returns our rect
        if rect then
            return compute_geom(state, { row = rect.row, col = rect.col, W = rect.width, H = L.H })
        end
        return L
    end
    if state.base_cmdheight == nil then
        state.base_cmdheight = vim.o.cmdheight -- save the user's cmdheight once, to restore on close
    end
    -- Grow the cmdline region to the content; the helper clamps to the room the splits leave + steps down on
    -- a stray E36 (`L.H` is already clamped in compute_geom, so it normally sets as-is).
    set_cmdheight(L.H)
    return L
end

--- (HOSTED) Re-place the surface over a NEW host-zone rect (the msgarea handed us a fresh one because it
--- reflowed — a message appeared / cleared below us). Lays out over the rect WITHOUT re-reserving, so it
--- cannot trigger another reflow (which would loop). No-op unless the surface is open.
---@param state table
---@param rect table?  { win, row, col, width, height }
local function reposition(state, rect)
    if state._closed or not rect or not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local L = compute_geom(state, { row = rect.row, col = rect.col, W = rect.width, H = rect.height })
    pcall(api.nvim_win_set_config, state.container_win, {
        relative = "editor",
        width = L.W,
        height = L.H,
        row = L.row,
        col = L.col,
    })
    place_panels(state, L)
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
        if state.cfg.position == "cmdline" then
            L = host_geom(state, L) -- HOSTED: reserve our rows in the host zone (it owns cmdheight); else grow it
        end
        pcall(api.nvim_win_set_config, state.container_win, {
            relative = "editor",
            width = L.W,
            height = L.H,
            row = L.row,
            col = L.col,
        })
    end
    place_panels(state, L)
    -- place_panels re-rendered only the chrome bands; a width change must ALSO re-flow each content panel
    -- provider (e.g. a toolbar `ui.bar` recomputing its overflow chevrons), so re-render them too.
    for i = 1, #state.panels do
        render_panel(state, i)
    end
end

-- ─── open / close ─────────────────────────────────────────────────────────────

-- forward declarations: `open_panel_win`'s `pan.refresh` and the state methods inside `open_windows` reference
-- these (the dynamic peek / restack helpers); their definitions follow below.
local dyn_geom, dyn_update, dyn_show, dyn_hide, dyn_enable, dyn_disable, restack_panels, apply_preview_side, refocus_list

--- Open (or re-open) ONE center panel's window over its computed rect + apply the window-local chrome. Used
--- both at open and when a panel is re-docked at runtime (the preview returning from a `hide`/`dynamic` state).
--- The scratch buffer persists across hide/show (`bufhidden = "hide"`), so its keymaps survive a close+reopen.
---@param state table
---@param pan table
---@param i integer  its index in `state.panels` (drives render_panel)
---@param pl table   the panel rect from compute_geom (`L.panels[i]`)
---@param has_input boolean
---@param docked boolean
local function open_panel_win(state, pan, i, pl, has_input, docked)
    if not (pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        pan.buf = api.nvim_create_buf(false, true)
        vim.bo[pan.buf].bufhidden = "hide" -- keep the scratch buffer alive while hidden; deleted in close()
        if pan.provider and pan.provider.hide_cursor then
            vim.bo[pan.buf].filetype = FRAME_FT
        end
    end
    -- Open the panel UNFOCUSED, then focus it AFTER the `w:lvim_frame` mark below. Entering it inside
    -- `nvim_open_win` (enter=true) fires WinEnter WHILE the mark is still unset — a foreign WinEnter hook (e.g.
    -- lvim-space's auto-close, which tears down every window it doesn't recognise) would then treat the panel as
    -- a stray and close it mid-open → "Window was closed immediately". Mark first, focus second, so by the time
    -- WinEnter fires those hooks already see it's a managed frame.
    local want_focus = i == 1 and state.cfg.enter ~= false and not has_input
    pan.win = api.nvim_open_win(pan.buf, false, {
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
    -- Mark EVERY panel window (float-mode too, not just docked) as managed UI — same as the container — so a
    -- generic "close all floating windows" / "focus next float" helper skips it instead of tearing the panel
    -- out from under the frame.
    vim.w[pan.win].lvim_frame = true
    if want_focus then
        pcall(api.nvim_set_current_win, pan.win)
    end
    vim.wo[pan.win].wrap = false
    if pan.provider and pan.provider.cursorline then
        local cl = (type(pan.provider.cursorline) == "string" and pan.provider.cursorline)
            or ((#state.panels > 1) and "LvimUiCursorLine" or "LvimUiPeekCursorLine")
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:" .. cl
        vim.wo[pan.win].cursorline = true
    else
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal"
    end
    pan.refresh = function() -- a provider re-renders its own panel after a state change (toggle, …)
        -- find the panel's CURRENT index by identity — `state.panels` is reordered/shrunk by the preview
        -- rotation / hide / dynamic, so the open-time `i` goes stale (a parked panel drops out entirely).
        for idx, p in ipairs(state.panels) do
            if p == pan then
                render_panel(state, idx)
                return
            end
        end
        -- PARKED preview in `dynamic`: the consumer's selection-change refresh re-renders the peek FLOAT
        -- instead (so it follows the list — its cursor lands on the new entry's location), since the picker
        -- moves a Sel stripe, not the window cursor, so the float's own CursorMoved trigger never fires.
        if pan == state.preview_panel and state.preview_side == "dynamic" then
            dyn_show(state)
        end
    end
    pan.frame = state -- providers reach the frame (focus_panel / close / cfg) through their panel
    render_panel(state, i)
end

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
        -- A `cmdline` surface OWNS the command-line region: UNHOSTED grows `cmdheight` to its height so the
        -- editor (and heirline / a global statusline) reflow ABOVE it, then floats over those rows; HOSTED
        -- reserves its rows in the host zone (which owns the cmdheight) so messages compose below it.
        if state.cfg.position == "cmdline" then
            L = host_geom(state, L)
        end
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

    -- An editable input band (see below) takes the initial focus instead of a panel.
    local has_input = false
    for _, band in ipairs(state.header_bands) do
        if band.input then
            has_input = true
            break
        end
    end

    for i, pan in ipairs(state.panels) do
        open_panel_win(state, pan, i, L.panels[i], has_input, docked)
    end

    -- Editable INPUT bands: a focusable 1-row editable window over each input band's header row. The frame
    -- creates it + wires a live on_change; the consumer drives the panels from on_change + the band's keys
    -- (insert-mode), like a fuzzy-finder prompt. Not part of the normal-mode sector nav — it is always
    -- focused (insert) while open, so there is no mode clash with the chassis keymaps.
    do
        local _, _, _, cl = util.insets(L.cbord)
        for bi, band in ipairs(state.header_bands) do
            if band.input then
                band.buf = api.nvim_create_buf(false, true)
                vim.bo[band.buf].bufhidden = "hide"
                vim.bo[band.buf].modifiable = true -- it is a typed field
                if band.filetype then
                    vim.bo[band.buf].filetype = band.filetype
                end
                -- `scope_panel` narrows the input to a single panel and overlays that panel's TOP (winbar)
                -- row — a finder whose prompt sits over its LIST, level with the other panels' titles, not on
                -- a separate full-width header row. Otherwise it spans the full container width on its header
                -- row.
                local iw, icol, irow = L.W, L.col + cl, L.row + L.ct + (bi - 1)
                if band.scope_panel and L.panels[band.scope_panel] then
                    local sp = L.panels[band.scope_panel]
                    iw, icol, irow = sp.width, sp.col, sp.row
                end
                band.win = api.nvim_open_win(band.buf, false, {
                    relative = "editor",
                    row = irow,
                    col = icol,
                    width = iw,
                    height = 1,
                    style = "minimal",
                    focusable = true,
                    zindex = state.zindex + 2, -- above the container (z) and the panels (z+1)
                })
                -- The typed area uses `input_hl` (the row's Normal bg); the prompt badge uses `prompt_hl`.
                vim.wo[band.win].winhighlight = "Normal:" .. (band.input_hl or "LvimUiPeekNormal")
                -- No wrap/continuation chrome on the 1-row prompt (a long query scrolls horizontally; a
                -- 'showbreak' / wrap continuation marker must never leak into the field).
                vim.wo[band.win].wrap = false
                vim.wo[band.win].list = false
                vim.wo[band.win].showbreak = ""
                if band.prompt and band.prompt ~= "" then
                    -- `prompt` is a STRING (one badge chunk) or a LIST of `{ text, hl }` chunks (e.g. a badge
                    -- + a gap on a different tint).
                    local vt = type(band.prompt) == "table" and band.prompt
                        or { { band.prompt, band.prompt_hl or "LvimUiMsgAreaItemKind" } }
                    pcall(api.nvim_buf_set_extmark, band.buf, NS, 0, 0, {
                        virt_text = vt,
                        virt_text_pos = "inline",
                        right_gravity = false,
                    })
                end
                if band.on_change then
                    api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
                        buffer = band.buf,
                        callback = function()
                            band.on_change(api.nvim_buf_get_lines(band.buf, 0, 1, false)[1] or "")
                        end,
                    })
                end
                if band.keys then
                    pcall(band.keys, band.buf, state)
                end
            end
        end
        -- Enter the FIRST input band on open (insert), unless the consumer opted out of focusing.
        if state.cfg.enter ~= false then
            for _, band in ipairs(state.header_bands) do
                if band.input and band.win and api.nvim_win_is_valid(band.win) then
                    api.nvim_set_current_win(band.win)
                    vim.cmd("startinsert!")
                    break
                end
            end
        end
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
    state.preview_side = state.cfg.preview_side -- the live preview position (rotate_preview cycles it)
    -- Capture the persistent list + preview panel refs, so the preview can be DROPPED (hide / dynamic) and
    -- RE-DOCKED at runtime without losing them (the scratch buffers outlive their windows).
    for _, pan in ipairs(state.panels) do
        if pan.id == "preview" then
            state.preview_panel = pan
        else
            state.list_panel = state.list_panel or pan
        end
    end
    apply_dock_height(state, state.preview_side) -- the configured docked height for the INITIAL stack direction
    --- Rotate the preview through FIVE positions (right → below → left → above → dynamic → …), LIVE. The four
    --- docked sides reflow the floats in place; `dynamic` drops the docked preview to a full-width list + a
    --- transient peek float (`apply_preview_side` handles both). No-op without a "preview" panel.
    ---@param dir integer  +1 next position, -1 previous
    state.rotate_preview = function(dir)
        if not state.preview_panel then
            return
        end
        local order = { "right", "below", "left", "above", "dynamic" }
        local ci = 1
        for i, s in ipairs(order) do
            if s == (state.preview_side or "right") then
                ci = i
            end
        end
        state.preview_side = order[((ci - 1 + dir) % #order) + 1]
        state.preview_hidden = false -- rotating always un-hides
        apply_preview_side(state)
        refocus_list(state)
    end
    --- Toggle the preview HIDDEN ↔ shown (the `hide` position). A no-op while `dynamic` (its peek owns the
    --- preview); only the docked sides hide. The last docked side returns on un-hide.
    state.toggle_preview = function()
        if not state.preview_panel or state.preview_side == "dynamic" then
            return
        end
        state.preview_hidden = not state.preview_hidden
        apply_preview_side(state)
        refocus_list(state)
    end
    -- Opened directly into a non-docked preview state (open_windows built BOTH panels): drop the docked preview
    -- now. `hide` as an initial side = start hidden on the default side.
    if state.preview_panel and (state.preview_side == "dynamic" or state.preview_side == "hide") then
        if state.preview_side == "hide" then
            state.preview_side = "right"
            state.preview_hidden = true
        end
        apply_preview_side(state)
    end
    --- Swap the HEADER bands at runtime — a tabbed surface changing a tab's toolbar bars (each becomes its own
    --- C-j/C-k sector). Regular bar bands are container LINES (not windows), so this just re-derives the band +
    --- sector lists and relayouts (recomputes the header height, repositions the content, re-renders). When a
    --- BAR sector is focused, it is re-established on the rebuilt band (its `_sel` lands on the active button,
    --- so a just-applied filter reads as hover_active); a center focus needs nothing (the center persists).
    ---@param spec table  the new `header` spec ({ bars = { … } })
    state.set_header = function(spec)
        local on_bar = state.focus and state.focus.kind == "bar"
        state.header_bands = build_bands(spec, false, state.cfg.header_air)
        state.sectors = build_sectors(state)
        if on_bar then
            local fi = math.max(1, math.min(state.focus_idx or 1, #state.sectors))
            local sec = state.sectors[fi]
            if sec and sec.kind == "bar" then
                local as = 1
                for bi, b in ipairs(sec.band.buttons or {}) do
                    if b.active then
                        as = bi
                    end
                end
                sec.band._sel = as
                state.focus_idx = fi
                state.focus = { kind = "bar", band = sec.band, where = sec.where }
            end
        end
        relayout(state)
    end
    --- Rebuild the FOOTER band(s) in place — for a live key-hint legend that tracks the focused row. The legend
    --- is a constant-height bar, so it just re-paints the chrome (render_chrome re-derives the footer line from
    --- the new bands and writes the CONTAINER buffer); the body float is untouched.
    ---@param spec table
    state.set_footer = function(spec)
        state.cfg.footer = spec
        state.footer_bands = build_bands(spec, true)
        state.sectors = build_sectors(state)
        if state._geom then
            render_chrome(state, state._geom)
        end
    end
    -- (HOSTED) Re-place over a fresh host-zone rect WITHOUT re-reserving (the host called us because it
    -- reflowed). Wired by the caller as the host segment's `on_rect`, so the surface follows the zone.
    state.reposition = function(rect)
        reposition(state, rect)
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
    --- Focus a SECTOR by index (1 = the first header bar / the filter bar, … the center, … the footer). Lets a
    --- consumer land focus on the TOP bar on a descend from above, instead of skipping into the center.
    ---@param i integer
    state.focus_sector = function(i)
        focus_sector(state, i)
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
        if state.cfg.direction == "vertical" then
            return -- vertical stack: panels are top↔bottom, walked with the sector nav (<C-j>/<C-k>), not <C-l>/<C-h>
        end
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
                    -- `no_hotkey` marks a DISPLAY button (e.g. a key-hint LEGEND like "j/k", "h/l") — it is shown
                    -- and mouse-clickable, but its `key` is a label, NOT a real keymap: registering a multi-char
                    -- label ("j/k") would make its first char ("j") a mapping PREFIX → nvim waits `timeoutlen` on
                    -- every "j" press. The real keys are already mapped by the content/frame.
                    if
                        spec.key
                        and spec.run
                        and spec.type ~= "separator"
                        and not spec.no_hotkey
                        and not skip[spec.key]
                    then
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
    -- A non-focusing float (`enter == false`) leaves the cursor in the editor — record the center panel but
    -- do NOT focus it; the consumer focuses later (e.g. a hover entered on the 2nd keypress).
    if state.cfg.enter == false then
        state.center_panel = center_idx() or 1
    elseif has_input then
        state.center_panel = center_idx() or 1 -- the input band (focused above, in insert) owns the keyboard
    else
        focus_sector(state, center_idx() or 1)
    end

    -- Closing any frame window externally (`:q`, a programmatic close) tears the whole frame down once.
    state.augroup = api.nvim_create_augroup("LvimUiFrame_" .. tostring(state.container_win), { clear = true })
    local watch = { state.container_win }
    for _, pan in ipairs(state.panels) do
        watch[#watch + 1] = pan.win
    end
    for _, band in ipairs(state.header_bands) do
        if band.input and band.win then
            watch[#watch + 1] = band.win
        end
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
            -- A `cmdline` surface grows `cmdheight` itself, which RESIZES the container float and so fires
            -- WinResized on it — but it already re-fits via its own content refresh (refresh_surface →
            -- relayout), so this WinResized relayout is redundant; skip it.
            if state._closed or state.cfg.position == "cmdline" then
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
                -- EXCEPT when focus is RETURNING from the host zone below (`_return_sector` set by sector_cycle):
                -- land back on the footer it descended from, so up/down nav is symmetric. A frame-driven bar
                -- focus sets `_focusing_bar`, so it stays on the chrome as intended.
                if not state._focusing_bar then
                    vim.schedule(function()
                        if not state._closed and api.nvim_get_current_win() == state.container_win then
                            focus_sector(state, state._return_sector or 1)
                            state._return_sector = nil
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

-- ─── preview side: hide + dynamic ─────────────────────────────────────────────
-- Two preview states beyond the four docked sides: `hide` (no preview — list full-width, toggled by a key)
-- and `dynamic` (list full-width + a TRANSIENT preview FLOAT above it, shown only while the picker is focused
-- and following the list cursor — the native-qf peek). Both drop the docked preview panel; `dynamic` then
-- drives its own float.

-- A single BOTTOM rule (no top/side border) — the SAME look as the docked `above` preview: the file winbar
-- marks the top, a red rule (`LvimUiPickerSeparator`) divides it from what's below. Full container width.
local DYN_BORDER = { "", "", "", "", "", "─", "", "" }

--- The dynamic float's column/width, the container top, and the CONTENT-height cap. The float floats over the
--- editor, so it is capped to LEAVE the top of the editor + its statusline VISIBLE (so you can still navigate to
--- the real buffer): its bottom rule sits 1 row above the statusline (`top - 2`), and the top stays below a
--- `keep_top` margin.
---@param state table
---@return table
function dyn_geom(state)
    local L = state._geom or compute_geom(state)
    local hs = state.cfg.preview_heights
    local capf = (hs and hs.vertical) or 0.5
    local cfgcap = math.max(3, capf <= 1 and math.floor(vim.o.lines * capf) or math.floor(capf))
    local top = L.row -- the container's top screen row (the editor statusline sits at top-1)
    local keep_top = math.floor(vim.o.lines * 0.4) -- leave the top ~40% of the editor visible
    return { col = L.col, width = L.W, top = top, cap = math.max(1, math.min(cfgcap, top - 2 - keep_top)) }
end

--- Render the preview provider into the dynamic float for the current list selection (no-op while the float
--- itself is focused — the provider leaves an in-progress edit alone).
---@param state table
function dyn_update(state)
    local d = state.dyn
    if not (d and d.win and api.nvim_win_is_valid(d.win)) then
        return
    end
    local prov = state.preview_panel and state.preview_panel.provider
    if prov and prov.update then
        pcall(prov.update, { win = d.win, buf = api.nvim_win_get_buf(d.win), frame = state })
    end
end

--- Show (or reposition) the dynamic float + refresh its content.
---@param state table
function dyn_show(state)
    local d = state.dyn
    if not d or state._closed or d._positioning then
        return
    end
    local g = dyn_geom(state)
    if not (d.win and api.nvim_win_is_valid(d.win)) then
        if not (d.buf and api.nvim_buf_is_valid(d.buf)) then
            d.buf = api.nvim_create_buf(false, true)
            vim.bo[d.buf].bufhidden = "hide"
        end
        d.win = api.nvim_open_win(d.buf, false, {
            relative = "editor",
            row = g.top - g.cap - 2, -- bottom rule lands at top-2 (editor statusline at top-1 stays visible)
            col = g.col,
            width = g.width,
            height = g.cap,
            style = "minimal",
            border = DYN_BORDER,
            focusable = true,
            zindex = (state.zindex or 50) + 1,
        })
        vim.wo[d.win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPickerSeparator"
        vim.wo[d.win].wrap = false
        -- a FRESH window has no winbar; make the provider re-assert the file title bar on the next update
        local prov = state.preview_panel and state.preview_panel.provider
        if prov and prov.reset then
            prov.reset()
        end
    end
    dyn_update(state)
    -- AUTO-FIT the float to the file (a peek), capped at `g.cap`; the bottom rule lands at top-2 (above the
    -- editor statusline), and the cap keeps the top of the editor visible.
    if d.win and api.nvim_win_is_valid(d.win) then
        local lines = api.nvim_buf_line_count(api.nvim_win_get_buf(d.win))
        local wb = vim.wo[d.win].winbar
        local h = math.max(1, math.min(lines + ((wb and wb ~= "") and 1 or 0), g.cap))
        pcall(api.nvim_win_set_config, d.win, {
            relative = "editor",
            row = g.top - h - 2,
            col = g.col,
            width = g.width,
            height = h,
            border = DYN_BORDER,
        })
    end
    -- A non-current FLOAT ignores cursor positioning (it always shows from line 1). Briefly FOCUS the float to
    -- place its cursor on the entry, then restore focus — synchronous, so nothing redraws in between.
    -- `_positioning` makes the focus-change autocmds' dyn_show re-entry a no-op (so it can't reset what we set).
    local prov = state.preview_panel and state.preview_panel.provider
    local it = prov and prov.item and prov.item()
    if it and it.filename and it.lnum and d.win and api.nvim_win_is_valid(d.win) then
        local prev = api.nvim_get_current_win()
        if prev ~= d.win then
            d._positioning = true
            pcall(api.nvim_set_current_win, d.win)
            local cnt = api.nvim_buf_line_count(api.nvim_win_get_buf(d.win))
            pcall(
                api.nvim_win_set_cursor,
                d.win,
                { math.max(1, math.min(it.lnum, cnt)), math.max(0, (it.col or 1) - 1) }
            )
            pcall(vim.cmd, "normal! zz")
            if api.nvim_win_is_valid(prev) then
                pcall(api.nvim_set_current_win, prev)
            end
            d._positioning = false
        end
    end
end

--- Hide the dynamic float (its buffer + the editable file stay alive; only the window closes).
---@param state table
function dyn_hide(state)
    local d = state.dyn
    if d and d.win and api.nvim_win_is_valid(d.win) then
        pcall(api.nvim_win_close, d.win, true)
    end
    if d then
        d.win = nil
    end
end

--- Turn the dynamic peek ON: a `CursorMoved` on the list follows the selection; a global `WinEnter` shows the
--- float while any picker window is focused and hides it when focus leaves the picker. Entering the float binds
--- `<C-j>` (on the editable file buffer, while focused) to drop back to the list.
---@param state table
function dyn_enable(state)
    state.dyn = state.dyn or {}
    if state.dyn.aug then
        return -- already on
    end
    local list = state.list_panel
    local aug = api.nvim_create_augroup("LvimUiSurfaceDyn_" .. tostring(state.container_win), { clear = true })
    state.dyn.aug = aug
    if list and list.buf and api.nvim_buf_is_valid(list.buf) then
        api.nvim_create_autocmd("CursorMoved", {
            group = aug,
            buffer = list.buf,
            callback = function()
                dyn_show(state)
            end,
        })
    end
    api.nvim_create_autocmd("WinEnter", {
        group = aug,
        callback = function()
            if state._closed then
                return
            end
            local w = api.nvim_get_current_win()
            local on_float = state.dyn.win and w == state.dyn.win
            local mine = on_float or (list and w == list.win) or (w == state.container_win)
            for _, b in ipairs(state.header_bands or {}) do
                if b.win == w then
                    mine = true
                end
            end
            if on_float then
                -- editing the peek → `<C-j>` drops back to the list, `<C-k>` steps UP out to the editor (the
                -- opener) — bound on the real file buffer only while the float is focused.
                local fb = api.nvim_win_get_buf(w)
                state.dyn._navbuf = fb
                pcall(vim.keymap.set, "n", "<C-j>", function()
                    if list and list.win and api.nvim_win_is_valid(list.win) then
                        api.nvim_set_current_win(list.win)
                    end
                end, { buffer = fb, nowait = true, silent = true })
                pcall(vim.keymap.set, "n", "<C-k>", function()
                    if state.cfg.on_escape_above then
                        state.cfg.on_escape_above()
                    end
                end, { buffer = fb, nowait = true, silent = true })
            else
                if state.dyn._navbuf and api.nvim_buf_is_valid(state.dyn._navbuf) then
                    pcall(vim.keymap.del, "n", "<C-j>", { buffer = state.dyn._navbuf })
                    pcall(vim.keymap.del, "n", "<C-k>", { buffer = state.dyn._navbuf })
                end
                state.dyn._navbuf = nil
                if mine then
                    dyn_show(state)
                else
                    dyn_hide(state)
                end
            end
        end,
    })
    dyn_show(state)
end

--- Turn the dynamic peek OFF: drop the autocmds + close the float.
---@param state table
function dyn_disable(state)
    local d = state.dyn
    if not d then
        return
    end
    if d.aug then
        pcall(api.nvim_del_augroup_by_id, d.aug)
        d.aug = nil
    end
    if d._navbuf and api.nvim_buf_is_valid(d._navbuf) then
        pcall(vim.keymap.del, "n", "<C-j>", { buffer = d._navbuf })
        pcall(vim.keymap.del, "n", "<C-k>", { buffer = d._navbuf })
        d._navbuf = nil
    end
    dyn_hide(state)
end

--- Re-derive the DOCKED center panels from the live preview state (side / hidden / dynamic) and reflow: a
--- single full-width list for `hide`/`dynamic`, the re-docked list+preview otherwise. The dropped preview is
--- PARKED behind the list (never closed — a WinClosed would bounce focus to the editor via the user's window
--- managers); re-docking just returns it to `state.panels`. No-op on a surface without a "preview" panel.
---@param state table
function restack_panels(state)
    local pv, list = state.preview_panel, state.list_panel
    if not (pv and list) then
        return
    end
    local undocked = state.preview_hidden or state.preview_side == "dynamic"
    local vert = (state.preview_side == "above" or state.preview_side == "below") and not undocked
    local preview_first = state.preview_side == "above" or state.preview_side == "left"
    local docked = undocked and { list } or (preview_first and { pv, list } or { list, pv })
    state.panels = docked
    state.cfg.direction = vert and "vertical" or nil
    if state.cfg.separator and state.cfg.separator ~= "" then
        state.cfg.separator = vert and "─" or "│"
    end
    local stack_axis = vert and "height" or "width"
    for _, pan in ipairs(docked) do
        pan.weight = pan.size and (pan.size[stack_axis] or {}).fixed or nil
    end
    apply_dock_height(state, state.preview_side)
    state.sectors = build_sectors(state)
    relayout(state) -- positions the docked panels (place_panels)
    -- The DROPPED preview is PARKED (not closed) behind the list: a WinClosed would fire the user's window
    -- managers (BufSurf, …) and bounce focus to the editor. Re-docking just returns it to `state.panels`, so the
    -- next relayout repositions it. (The list float — higher zindex + opaque — fully covers the parked one.)
    if undocked and pv.win and api.nvim_win_is_valid(pv.win) then
        local lp = state._geom and state._geom.panels and state._geom.panels[1]
        if lp then
            pcall(api.nvim_win_set_config, pv.win, {
                relative = "editor",
                row = lp.row,
                col = lp.col,
                width = math.max(1, lp.width),
                height = math.max(1, lp.height),
                zindex = state.zindex or 50,
            })
        end
    end
end

--- Pull focus back to the list AFTER the event loop (closing a preview float bounces focus to the editor on a
--- DEFERRED tick, so a synchronous re-focus is undone). Used by the runtime rotate / hide toggle — never at
--- open, where the input band should keep focus.
---@param state table
function refocus_list(state)
    vim.schedule(function()
        if state._closed then
            return
        end
        local w = state.list_panel and state.list_panel.win
        if w and api.nvim_win_is_valid(w) then
            pcall(api.nvim_set_current_win, w)
        end
    end)
end

--- Apply the live `preview_side` (+ `preview_hidden`): reflow the docked panels, then arm/disarm the dynamic
--- peek. The single entry point for both the rotation and the hide toggle.
---@param state table
function apply_preview_side(state)
    restack_panels(state)
    if state.preview_side == "dynamic" then
        dyn_enable(state)
    else
        dyn_disable(state)
    end
    -- re-render the preview next tick: a just re-docked panel (un-hide / rotate back) can read empty until the
    -- next selection change, and the dynamic float needs its content after the windows settle.
    vim.schedule(function()
        if state._closed then
            return
        end
        local pv = state.preview_panel
        if pv and pv.provider and pv.provider.reset then
            pv.provider.reset()
        end
        if pv and pv.refresh then
            pv.refresh()
        end
    end)
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
    dyn_disable(state) -- close the dynamic peek float + its autocmds, if armed
    -- Let providers release any external state before we drop the windows (the frame's own scratch panel
    -- buffers are deleted below, taking their keymaps/extmarks with them, but a provider may hold things
    -- outside them — e.g. autocommands, or keymaps on a real buffer).
    for _, pan in ipairs(state.panels or {}) do
        if pan.provider and pan.provider.on_close then
            pcall(pan.provider.on_close, pan)
        end
    end
    -- A PARKED preview (hidden / dynamic) is not in `state.panels`, so close it explicitly too.
    if state.preview_panel and state.preview_panel.win and api.nvim_win_is_valid(state.preview_panel.win) then
        local docked = false
        for _, p in ipairs(state.panels or {}) do
            if p == state.preview_panel then
                docked = true
            end
        end
        if not docked then
            pcall(api.nvim_win_close, state.preview_panel.win, true)
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
    if state.preview_panel and state.preview_panel.buf and api.nvim_buf_is_valid(state.preview_panel.buf) then
        pcall(api.nvim_buf_delete, state.preview_panel.buf, { force = true })
    end
    for _, band in ipairs(state.header_bands or {}) do -- editable input bands' overlay windows
        if band.input then
            if band.win and api.nvim_win_is_valid(band.win) then
                pcall(api.nvim_win_close, band.win, true)
            end
            if band.buf and api.nvim_buf_is_valid(band.buf) then
                pcall(api.nvim_buf_delete, band.buf, { force = true })
            end
        end
    end
    if state.container_win and api.nvim_win_is_valid(state.container_win) then
        pcall(api.nvim_win_close, state.container_win, true)
    end
    if state.base_cmdheight ~= nil then -- a `cmdline` surface grew cmdheight; restore the user's value
        vim.o.cmdheight = state.base_cmdheight
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
    state.focus_sector = function()
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
    -- `nvim_open_win` is forbidden in the command-line window (q: / q/ / q?), so a frame opened from there
    -- (e.g. an installer prompt that fires while `q:` is open) would raise E11. Defer the whole open until
    -- the cmdwin closes and return a no-op stub, so the caller never crashes on the missing handle.
    if vim.fn.getcmdwintype() ~= "" then
        vim.api.nvim_create_autocmd("CmdwinLeave", {
            once = true,
            callback = function()
                vim.schedule(function()
                    M.open(cfg)
                end)
            end,
        })
        return setmetatable({ deferred = true }, {
            __index = function()
                return function() end
            end,
        })
    end
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

    -- content.blocks → panels: each block carries an `id`, a `provider`, its share along the STACKING axis
    -- (`size.width.fixed` when horizontal / `size.height.fixed` when vertical = a weight; absent = flex/
    -- auto), and an optional `border`.
    local panels = {}
    local stack_axis = cfg.direction == "vertical" and "height" or "width"
    for i, blk in ipairs((cfg.content or {}).blocks or {}) do
        local bw = (blk.size or {})[stack_axis] or {}
        panels[i] = {
            id = blk.id,
            provider = blk.provider,
            size = blk.size,
            weight = bw.fixed,
            border = blk.border,
            shrink_first = blk.shrink_first, -- give up rows before protected panels when the stack overflows
        }
    end

    -- A FLOAT carries the brand as its border title (built in open_windows). A SPLIT has no border, so the
    -- title becomes the top CONTENT row of the chrome instead (the icon + text, flattened).
    local hbands = build_bands(cfg.header, false, cfg.header_air)
    if cfg.mode == "split" then
        local t = cfg.title
        -- UPPERCASE the title text (the canon), keep the icon glyph
        local s
        if type(t) == "table" then
            s = (t.icon and t.icon .. " " or "") .. (t.text and tostring(t.text):upper() or "")
        else
            s = t and tostring(t):upper() or ""
        end
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
