-- lvim-utils.config.ui: the SHARED chrome theme spec — every tint strength and every accent the lvim-tech
-- UI paints with, in ONE place.
--
-- Why this file exists: the highlight factory (config/highlight.lua) used to carry ~50 literal blend factors
-- and ~20 hardcoded palette picks inline (`mtint(c.blue, 0.3)`, `fg = c.orange`, …). Every one of them was a
-- DESIGN decision — how loud a badge is, which hue a tab wears — and none of them could be changed without
-- editing the plugin. They are all here now, named by their ROLE rather than by their number, so a value can
-- be read ("a key badge sits at `tint.badge`") instead of decoded, and retuned in one line.
--
-- TINT = how far an accent is blended toward the panel background: 0 = plain bg, 1 = the pure accent. The
-- scale is deliberately coarse and ordered — body < strong < badge < hover — so the whole chrome keeps one
-- rhythm: a body cell only hints at its colour, a prominent cell states it, a hovered one shouts.
--
-- ACCENT = which palette colour a component wears. A palette KEY (tracks the live theme — "blue", "red",
-- "green_dark", …) or a literal "#rrggbb".
--
---@module "lvim-utils.config.ui"

---@class LvimUtilsUiTint
---@field cursorline number  the active list row's wash — the faintest tint in the set
---@field body       number  a secondary / inactive / body cell (stripes, subtitles, inactive boxes)
---@field row_odd    number  the odd list-stripe row (a completion-grid / list row)
---@field row_even   number  the even list-stripe row (a touch stronger than odd)
---@field row_sel    number  the SELECTED list row (stronger still, so it reads above the stripes)
---@field bar_fill   number  the continuous strip under a bar's buttons
---@field separator  number  a separator box between bar groups
---@field input      number  the typed-text FIELD of any input popup / prompt (its background wash)
---@field help_desc  number  the DESCRIPTION box of a cheatsheet row (`lvim-ui.help`)
---@field help_key   number  its KEY box — and the ACTIVE row's description, so the row reads as one block
---@field hover      number  a mouse-hover cell (weaker than a keyboard selection)
---@field match      number  a fuzzy-match span inside a row
---@field strong     number  a PROMINENT / ACTIVE cell (titles, active tabs, active buttons)
---@field badge      number  a key badge / icon box / counter — the "loud" cell
---@field label      number  a badge's label box (one step below the badge)
---@field selection  number  the keyboard selection drawn OVER a focused bar button
---@field bright     number  an active text box (tab text, a file name cell)
---@field icon       number  an icon box / a hovered badge — the strongest tinted cell
---@field deep       number  a chevron / separator BOX — the densest box in the chrome
---@field dim        number  how far a DISABLED fg is blended toward the bg (a fg blend, not a bg tint)
---@field row_dim    number  how far a disabled ROW's fg is blended toward the bg
---@field path_dim   number  how far a file row's leading PATH is blended (a dimmer shade of the name)
---@field filter_off number  an inactive filter button's fg (kept mostly intact — it must stay readable)

---@class LvimUtilsUiAccentInput
---@field bg   string  the accent the input FIELD's background wash is blended from (at `tint.input`)
---@field text string  the colour the typed value is drawn in

---@class LvimUtilsUiAccentTab
---@field box  string  the tab's own box (active/inactive)
---@field icon string  its icon box
---@field text string  its text box

---@class LvimUtilsUiAccentFooter
---@field key     string  the key badge
---@field label   string  the label box
---@field sep     string  the •-separator box between the panel keys and the row keys
---@field chevron string  the overflow chevrons

---@class LvimUtilsUiAccentPeek
---@field title  string
---@field icon   string
---@field kind   string  the list winbar (its "kind" cell)
---@field file   string  the preview winbar (the file cell)
---@field match  string  the match span in the preview
---@field filter string  the filter bar
---@field count  string  the counter box

---@class LvimUtilsUiAccentNotify
---@field info  string
---@field warn  string
---@field error string
---@field debug string

---@class LvimUtilsUiAccentMsgArea
---@field title    string
---@field row_odd  string  the odd completion-grid row stripe
---@field row_even string  the even stripe
---@field match    string  the typed-query match inside an item
---@field kind     string  an item's kind icon
---@field marker   string  the multi-select mark

---@class LvimUtilsUiAccentDashboard
---@field header  string
---@field footer  string
---@field icon    string
---@field key     string
---@field desc    string
---@field title   string
---@field file    string
---@field dir     string
---@field special string

---@class LvimUtilsUiAccent
---@field title     string  the panel title box
---@field subtitle  string  the subtitle / info box
---@field border    string
---@field separator string  the ────── divider row
---@field cursorline string the wash under the active row
---@field spacer    string
---@field tab       LvimUtilsUiAccentTab
---@field button    string  action-bar buttons
---@field row       string  a form/tabs row's text
---@field row_icon  string  a row's leading icon
---@field item      string  a select/multiselect item
---@field path      string  a file row's name + path
---@field input     LvimUtilsUiAccentInput
---@field help      table   { odd, even } — the cheatsheet's row striping accents
---@field footer    LvimUtilsUiAccentFooter
---@field bar_fill  string  the strip under a bar
---@field bar_sep   string  the ➤/● separator box between bar groups
---@field picker    table   { prompt, input, cursor, marker, separator, preview_dir }
---@field peek      LvimUtilsUiAccentPeek
---@field notify    LvimUtilsUiAccentNotify
---@field msgarea   LvimUtilsUiAccentMsgArea
---@field dashboard LvimUtilsUiAccentDashboard

---@class LvimUtilsUiTitle
---@field accent string  the docked panel's full-width title bar colour
---@field tint   number  how far that accent is blended onto the bg

---@class LvimUtilsUiConfig
---@field tint   LvimUtilsUiTint
---@field accent LvimUtilsUiAccent
---@field title  LvimUtilsUiTitle

---@type LvimUtilsUiConfig
return {
    -- ── The tint scale, ordered from the faintest to the densest ────────────────────────────────────────
    tint = {
        cursorline = 0.04, -- the active row's wash: must sit BELOW the section/header bands so the two never read alike
        body = 0.05, -- secondary / inactive / body
        -- The list STRIPES (LvimUiMsgAreaRow*/Sel*): both rows are the SAME accent (blue), so the zebra reads by
        -- DEPTH of tint, not by hue — odd lighter, even a touch stronger, and the selected row stronger still.
        row_odd = 0.05,
        row_even = 0.08,
        row_sel = 0.15,
        bar_fill = 0.08, -- the strip under a bar's buttons (light enough that the buttons pop above it)
        separator = 0.12, -- a bar-group separator box
        input = 0.05, -- the typed-text FIELD of every input popup / prompt (the badge before it sits at `badge`)
        help_desc = 0.05, -- the DESCRIPTION box of a cheatsheet row (`lvim-ui.help`)
        help_key = 0.1, -- its KEY box — and what the ACTIVE row's description rises to, so the row reads solid
        hover = 0.15, -- a mouse hover
        match = 0.25, -- a fuzzy-match span (must stay visible over real code in a preview)
        strong = 0.2, -- a PROMINENT / ACTIVE cell — the workhorse of the chrome
        label = 0.2, -- a badge's label box
        badge = 0.3, -- a key badge / icon box / counter
        selection = 0.35, -- the keyboard selection over a focused bar button
        bright = 0.4, -- an active text box (a tab's text, a file name)
        icon = 0.5, -- an icon box / a HOVERED badge — the strongest cell in a bar
        deep = 0.6, -- a chevron / footer-separator BOX
        -- fg blends (not backgrounds): how far a muted foreground is pulled toward the bg
        dim = 0.45, -- a disabled value (plain `comment` is too close to the inactive row text)
        row_dim = 0.5, -- a disabled ROW
        path_dim = 0.8, -- a file row's leading directory (a dimmer shade of the name's colour)
        filter_off = 0.6, -- an inactive filter button (0.45 was too washed out to read)
    },

    -- ── Which colour each component wears ──────────────────────────────────────────────────────────────
    accent = {
        title = "blue",
        subtitle = "yellow",
        border = "blue",
        separator = "red", -- the ────── divider row between groups
        cursorline = "blue",
        spacer = "magenta",

        -- The input FIELD of every input popup (lvim-ui.input and any prompt band): `bg` is the accent its
        -- background wash is blended from (at `tint.input`), `text` the colour the typed value is drawn in.
        -- Both are palette keys (or a literal "#rrggbb"), so the field tracks the live theme.
        input = { bg = "blue", text = "fg" },

        -- The keymap CHEATSHEET (`lvim-ui.help`) — every plugin's `?` window. Rows STRIPE by these two
        -- accents; the KEY box wears its accent at `tint.help_key`, the DESCRIPTION at `tint.help_desc`, and
        -- the row under the (hidden) cursor raises its description to the KEY strength, so the whole row
        -- reads as one solid block of its own colour.
        help = { odd = "blue", even = "yellow" },

        tab = { box = "red", icon = "blue", text = "yellow" },
        button = "orange", -- action-bar buttons
        row = "yellow", -- a form/tabs row's text
        row_icon = "teal", -- an item row's leading icon
        item = "yellow", -- select / multiselect items + their checkboxes
        path = "blue", -- a file row: the name (full) + its path (path_dim of the same hue)

        footer = { key = "blue", label = "yellow", sep = "red", chevron = "yellow" },
        bar_fill = "yellow",
        bar_sep = "blue",

        picker = {
            prompt = "blue", -- the icon/label badge before the typed area
            input = "blue", -- the typed text
            cursor = "blue", -- the fzf caret
            marker = "red", -- the multi-select dot
            separator = "red", -- the thin divider line between the panes
            preview_dir = "yellow",
        },

        peek = {
            title = "blue",
            icon = "blue",
            kind = "green", -- the list winbar
            file = "yellow", -- the preview winbar
            match = "blue",
            filter = "yellow",
            count = "green", -- the counter box in the border
        },

        notify = { info = "blue", warn = "orange", error = "red", debug = "purple" },

        msgarea = {
            title = "blue",
            row_odd = "yellow",
            row_even = "yellow", -- both stripes yellow: the alternation is by TINT depth, not by hue

            match = "red",
            kind = "cyan",
            marker = "red",
        },

        dashboard = {
            header = "green_dark", -- the ASCII banner
            footer = "red_dark",
            icon = "red_dark",
            key = "orange",
            desc = "cyan",
            title = "green_dark", -- a section title (Recent Files / Projects)
            file = "red_dark",
            dir = "comment",
            special = "purple", -- emphasised inline text (the startup counts)
        },
    },

    -- ── The docked panel's full-width TITLE bar (the message zone's "MESSAGES", and every bar like it) ──
    title = { accent = "blue", tint = 0.2 },
}
