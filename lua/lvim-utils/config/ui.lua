-- lua/lvim-utils/config/ui.lua
-- Default config for the floating UI (popup geometry, icons, keys, tint, labels).

return {
    border = { "", "", "", " ", " ", " ", " ", " " },
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
        list_border = { " ", " ", " ", " ", " ", " ", " ", " " }, -- the list pane
        preview_border = { " ", " ", " ", " ", " ", " ", " ", " " }, -- the preview pane
        title = "LVIM LSP", -- centred; on the container's top border when it has one, else a header row
        footer = true, -- key-hint line on the container's bottom border (needs one); swaps per focused pane
        group_icon_open = "", -- file-group header icon when expanded
        group_icon_closed = "", -- file-group header icon when collapsed
        guide_icon = "", -- prefix before an expanded group row ("" = plain indent)
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
            close = "q",
        },
    },
}
