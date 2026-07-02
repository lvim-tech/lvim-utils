-- lvim-utils.config.ui: the live config for the shared windowed-UI chassis — frame borders, surface geometry
-- per layout, the popup icons / labels / keys, the tint strengths, and the two-pane peek navigator. These are
-- THE single sources of truth read live at open time by every consumer (pickers, ui.tabs, lvim-lsp peeks, …),
-- so changing one key here re-frames them all on the next open. `setup()` merges the user's `ui = {…}` into
-- this table in place (via lvim-utils.utils.merge); readers `require("lvim-utils.config").ui`.
--
---@module "lvim-utils.config.ui"

---@class LvimUtilsUiConfig
---@field border             string|string[]      Container frame border ("none" or an 8-element ring) — the single source for the outer frame
---@field content_border     string|string[]      Per-content-panel border ("none" or an 8-element ring) drawn around each data block
---@field separator          boolean|string|table Inter-panel divider between adjacent content panels ({ h, v, hl }; false to disable)
---@field group_border       string[]             Common ring around the data panels as a group (8-element; false to disable)
---@field separator_hl       string               Highlight group for the inter-panel divider
---@field size               table                Shared surface geometry per layout (float / area / bottom + auto_max)
---@field disable_completion boolean              Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
---@field position           string               Popup anchor ("editor")
---@field width              number               Default popup width (fraction of the editor)
---@field max_width          number               Maximum popup width (fraction)
---@field height             number               Default popup height (fraction)
---@field max_height         number               Maximum popup height (fraction)
---@field max_items          integer              Maximum list rows shown before scrolling
---@field filetype           string               Filetype set on the popup buffer
---@field close_keys         string[]             Keys that close the popup
---@field markview           boolean              Enable markview rendering in the popup
---@field title_line         string               Where a frame's title goes: "row" | "border" | "statusline"
---@field counter            string               Where a supplied count renders: "title" | "footer"
---@field title_pos          string               Title alignment: "left" | "center" | "right"
---@field tint               table                Background tint strengths (strong / body) for the themed chrome cells
---@field icons              table                Glyphs for the popup (booleans, select, kinds, markers, current pointer)
---@field labels             table                Footer-legend action labels (navigate / confirm / cancel / …)
---@field keys               table                Popup + chassis navigation keys (vim notation; strings or lists)
---@field peek               table                Two-pane location navigator (mode, geometry, borders, icons, keys)

---@type LvimUtilsUiConfig
return {
    -- THE single source of truth for the windowed-UI frame CONTAINER border — "none": no outer frame at all.
    -- The title + counter live in a CONTENT row at the top (`title_line = "row"`), so no border-title is needed;
    -- the panels are framed by `group_border` and divided by `separator`. `ui.surface` binds its `FRAME_BORDER`
    -- marker to this value and resolves it LIVE at open time, so changing this ONE key re-frames every consumer
    -- (pickers, ui.tabs, lvim-lsp peeks, …) on the next open — no per-consumer edits. Set an 8-element ring
    -- (e.g. { "╭","─","╮","│","╯","─","╰","│" }) to box the whole container instead.
    border = "none",
    -- THE single source of truth for the CONTENT-PANEL border — the per-panel ring drawn around EACH DATA block
    -- INSIDE the container (the picker's list + preview, lvim-space's list, the tabs content panel). The NAV
    -- bands (footer / filter / tab / search) are not content blocks and stay borderless. `ui.surface` binds its
    -- `CONTENT_BORDER` marker to this value and resolves it LIVE at open time, so changing this ONE key
    -- re-borders every content panel on the next open — independently of `border` (the container) and
    -- `group_border` (the common ring around the panel group). Set to `"none"` so the panels are BORDERLESS:
    -- the common `group_border` frames the two panels as a group and the `separator` divides them, so a second
    -- per-panel ring would just double the lines. Set to an 8-element ring to give each panel its own frame too.
    --   { topleft, top, topright, right, botright, bot, botleft, left }
    content_border = "none",
    -- THE single configurable source for the INTER-PANEL divider — the rule drawn BETWEEN adjacent content
    -- panels (a picker's list ↔ preview). The chassis reads it as the per-surface default, so changing it here
    -- re-divides every multi-panel surface on the next open. AUTO-ORIENTED: `h` is the glyph between side-by-side
    -- panels, `v` between stacked ones (a preview rotation flips it live); `hl` tints it (default the border
    -- tint, so it matches the rings). It only ever draws between panels (n-1 gaps), so a single-panel surface
    -- shows none. Set `separator = false` to disable the divider globally; a plain string is used verbatim for
    -- both axes; a surface may still override per-open (`separator = false` / a string / a { h, v } table).
    separator = { h = "│", v = "─", hl = "LvimUiPeekBorder" },
    -- THE single configurable source for the GROUP frame — a COMMON ring drawn around the DATA panels as a
    -- group (a picker's list + preview together), INSIDE the container but OUTSIDE the header / footer nav bands
    -- and air rows. It is the third, "unifying" ring: container (outer) › group (around the panels) › each
    -- panel's own `content_border`. Drawn ONLY when there are ≥2 content panels (a single panel needs no
    -- grouping). A 1-col gutter sits between the container and the group, and between the group and the panels,
    -- so no edge doubles. `hl` tints it like the other rings. Set `group_border = false` to disable it.
    --   { topleft, top, topright, right, botright, bot, botleft, left }
    group_border = { "", "", "", "", "", "", "", "", hl = "LvimUiPeekBorder" },
    -- The highlight group for that divider — default the blue-tinted peek border, so the rule matches the
    -- container / content rings. Override to restyle the divider everywhere.
    separator_hl = "LvimUiPeekBorder",
    -- Shared surface GEOMETRY per LAYOUT — the SINGLE source read by every consumer (pickers, ui.tabs,
    -- lvim-shell, lvim-space) via `require("lvim-utils.ui").size(layout)`, and edited live by lvim-utils' own
    -- config panel + lvim-control-center (persisted through the shared store, so both stay in sync).
    --   height / width — always a FRACTION 0.1–1.0 of the available space (a concrete number, never "auto").
    --   height_auto / width_auto — a boolean PER DIMENSION: false → the axis is EXACTLY the fraction (fixed);
    --                     true → the axis AUTO-FITS its content, with the fraction used as the MAX cap. Width
    --                     and height are independent (e.g. a float can fixed-width + auto-height).
    --   float  — a centred float: height AND width (each with its own `*_auto`).
    --   area   — the msgarea/cmdline dock (editor + statusline stay above it): height only (full-width).
    --   bottom — a plain bottom float dock: height only (full-width).
    -- The `area` height is the TOTAL dock height (drives the msgarea reserve cap); a STACKED preview SPLITS it
    -- (preview keeps its content-fit height, the list takes the rest) so the dock never exceeds it. Defaults are
    -- FIXED (auto off) — a full-bleed terminal / form has no content height to fit, so auto would collapse it;
    -- turn an axis's `*_auto` on for content that should shrink to fit (a short list) up to that cap.
    size = {
        float = { height = 0.85, width = 0.8, height_auto = false, width_auto = false },
        area = { height = 0.5, height_auto = false },
        bottom = { height = 0.4, height_auto = false },
    },
    -- Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
    disable_completion = true,
    position = "editor",
    width = 0.8,
    max_width = 0.8,
    height = 0.8,
    max_height = 0.8,
    max_items = 15,
    filetype = "lvim-utils-ui",
    close_keys = { "q", "<Esc>" },
    markview = false,

    -- Shared chassis title/counter placement (a single `surface.open` may override either per-open):
    --   title_line — where a frame's TITLE goes: "row" (default — a CONTENT row at the top, drawn from column
    --                0 so the tinted title block is flush-left and the counter flush-right), "border" (the
    --                native LEFT-aligned border-title, which nvim insets 1 col for the corner), or "statusline"
    --                (publish to the chrome overlay, minibuffer style, suppressing both).
    --   counter    — where a supplied count (a frame's item / match total) renders: "title" (default —
    --                RIGHT-aligned on the same row/border as the title, so it reads "NAME …………… 8/62") or
    --                "footer" (a right-aligned native bottom border-FOOTER).
    title_line = "row",
    counter = "title",
    -- Title ALIGNMENT, shared by the content-row title (`title_line="row"`) AND the native border-title:
    -- "left" (default — flush-left, counter flush-right), "center", or "right". A single `surface.open` may
    -- override per-open with its own `title_pos`. Lets a panel (e.g. LvimControlCenter) center its title
    -- consistently without needing a border.
    title_pos = "left",

    -- Background tint strengths (blend factor toward c.bg) for the themed chrome cells,
    -- matching the notify/Messages look: `strong` paints prominent/active cells (title,
    -- active tab/button, key badge, active list row), `body` the secondary/inactive ones
    -- (subtitles, inactive, labels, the rest of the list). See config/highlight.lua.
    tint = {
        strong = 0.2,
        body = 0.05,
    },

    -- tab_hl, button_hl, footer_hl, item_hl, checkbox_hl have no defaults.
    -- When absent the rendering code falls back to the named LvimUi* groups.
    -- Set any of them in setup({ ui = { tab_hl = { active = { ... } } } })
    -- only when you want an inline HlDef instead of a named group.

    icons = {
        bool_on = "󰄬",
        bool_off = "󰍴",
        select = "󰘮",
        number = "",
        string = "",
        action = "",
        spacer = "   ──────",
        multi_selected = "󰄬",
        multi_empty = "󰍴",
        current = "➤",
    },

    labels = {
        navigate = "navigate",
        confirm = "confirm",
        cancel = "cancel",
        close = "close",
        toggle = "toggle",
        cycle = "cycle",
        edit = "edit",
        execute = "execute",
        tabs = "tabs",
    },

    keys = {
        down = "j",
        up = "k",
        confirm = "<CR>",
        cancel = "<Esc>",
        close = "q",

        -- ui.surface chassis NAVIGATION (the finder, the message zone, any windowed UI). Override globally,
        -- e.g. `setup({ ui = { keys = { sector_next = "<C-Down>" } } })`; a single surface can still override
        -- via its own `keys`. Each value is a lhs string OR a list of lhs strings.
        sector_next = "<C-j>", -- DOWN the vertical stack: header · center · footer (the preview is SKIPPED)
        sector_prev = "<C-k>", -- UP
        panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview) — the only way onto the preview
        panel_next = "<C-l>", -- next center panel (right) — e.g. list → preview
        panel_prev = "<C-h>", -- previous center panel (left)
        menu_prev = { "h", "<Left>" }, -- move the selection within a focused button bar
        menu_next = { "l", "<Right>" },
        menu_confirm = { "<CR>", "<Space>" }, -- activate the focused button
        zone_escape = { "<C-k>", "<C-w>k" }, -- leave the message zone (blur back up) when focused in it

        tabs = {
            next = "l",
            prev = "h",
        },

        select = {
            confirm = "<CR>",
            cancel = "<Esc>",
        },

        multiselect = {
            toggle = "<Space>",
            confirm = "<CR>",
            cancel = "<Esc>",
        },

        list = {
            next_option = "<Tab>",
            prev_option = "<BS>",
        },
    },

    -- Two-pane location navigator (ui.peek): a grouped list of source locations on one side
    -- and a live preview of the focused location on the other. `mode` chooses the presentation
    -- ("split" = embedded splits at the bottom, "float" = a detached floating container).
    peek = {
        mode = "split",
        -- How file groups expand in the list:
        --   "auto"   — only the group holding the focused location is open; it follows the cursor
        --   "manual" — groups are toggled open/closed by click or <CR>/<Tab> on their header
        expand = "manual",
        list_position = "left", -- "left" | "right" (which side the list pane sits on)
        list_width = 0.4, -- left/right split: list pane share of the region (0.4 = 40% list / 60% preview); absolute cols if > 1. Drag the divider to adjust live.
        preview_height = 16, -- split mode: total region height (lines)
        preview_number = "normal", -- preview line numbers: "none" | "normal" | "relative"
        float = {
            width = 0.85, -- fraction of the editor (or absolute cols if > 1)
            height = 0.8,
            zindex = 50,
            backdrop = true, -- dim the editor behind the floating peek
            backdrop_blend = 40,
        },
        -- Three independent 8-element borders, each { topleft, top, topright, right, botright,
        -- bot, botleft, left } and each side fully honoured (a "" side draws nothing, a " " side
        -- adds an invisible 1-cell padding, a glyph draws a line). The layout reads each border's
        -- insets, so e.g. the preview's LEFT can be "" (flush) while the list's RIGHT is " " (gap).
        -- Default = invisible padding borders: every side is a " " (a 1-cell border that draws no
        -- glyph), highlighted with LvimUiPeekBorder (bg = the float bg), so each pane and the whole
        -- panel get clean float-bg padding with no visible lines. Put a glyph on any side to draw it.
        border = { " ", " ", " ", " ", " ", " ", " ", " " }, -- the whole panel (container)
        -- NO top/bottom edge (only the frame's 1 air row separates the panels from the title / footer —
        -- a panel top/bottom " " would double it); left/right " " keeps the horizontal padding.
        list_border = { "", "", "", " ", "", "", "", " " }, -- the list pane
        preview_border = { "", "", "", " ", "", "", "", " " }, -- the preview pane
        title = "LVIM LSP", -- centred; on the container's top border when it has one, else a header row
        footer = true, -- key-hint line on the container's bottom border (needs one); swaps per focused pane
        group_icon_open = "", -- file-group header icon when expanded
        group_icon_closed = "", -- file-group header icon when collapsed
        guide_icon = "", -- prefix before an expanded group row ("" = plain indent)
        -- Overflow chevrons for the responsive filter bar (header) and key-hint footer, shown on the
        -- side(s) whose content runs past the panel width. Glyphs configurable; coloured by
        -- LvimUiPeekFilterChevron / LvimUiPeekFooterChevron (yellow by default).
        chevrons = { left = "", right = "" },
        keys = {
            down = "j",
            up = "k",
            next_group = "<Tab>",
            prev_group = "<S-Tab>",
            toggle = "<CR>", -- on a header: expand/collapse (manual mode)
            jump = "<CR>", -- on a row: open the location
            split = "s",
            vsplit = "v",
            tabedit = "t",
            focus_preview = "<C-l>", -- from the list: move focus into the preview pane
            focus_list = "<C-h>", -- from the preview: move focus back to the list
            filter = "f", -- cycle the active button of the bar's PRIMARY group (when a bar is shown)
            -- The filter bar as a keyboard MENU: `m` (from either pane) focuses it; inside, move the
            -- selection / apply / leave. When the bar overflows the panel it scrolls with ‹ › chevrons.
            focus_menu = "m",
            menu_prev = { "h", "<Left>" },
            menu_next = { "l", "<Right>" },
            menu_confirm = { "<CR>", "<Space>" },
            menu_exit = { "<Esc>", "q" },
            -- Move focus DOWN / UP through the panel's sectors (header · center · footer). Configurable
            -- — e.g. set them to "]" / "[".
            sector_next = "<C-j>",
            sector_prev = "<C-k>",
            close = "q",
        },
    },
}
