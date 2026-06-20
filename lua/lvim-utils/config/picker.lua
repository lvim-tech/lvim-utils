-- lua/lvim-utils/config/picker.lua
-- Shared config for the finder (lvim-utils.picker) — applies to EVERY finder (files / grep / buffers / …)
-- so they share one look. EVERYTHING visual is configurable here: the prompt badge content and a `hl`
-- table mapping every element to a highlight group (all overridable). setup() merges user opts in place;
-- readers do `require("lvim-utils.config").picker`.
--
---@module "lvim-utils.config.picker"

return {
    -- The PROMPT badge shown before the typed query: an icon and/or label (either may be "" — icon only /
    -- text only / icon + text). A per-call `opts.prompt` string overrides it.
    prompt = {
        icon = "➤", -- the leading glyph (the canon pointer; set your own nf glyph via setup, or "" for none)
        label = "", -- optional text after the icon (e.g. "Search"); "" for none
        -- Spacing around the badge (all configurable): `pad_left` before the icon, `icon_gap` between the
        -- icon and the label (only when both are present), `pad_right` after the icon/label (all on the
        -- badge's strong tint), `input_gap` between the badge and the typed text (on the input's light tint).
        pad_left = 1,
        icon_gap = 1,
        pad_right = 1,
        input_gap = 1,
    },

    -- Highlight groups for EVERY element — all overridable (and shared by all finders). Swap any to restyle
    -- the whole finder.
    hl = {
        prompt = "LvimUiPickerPrompt", -- the icon + label badge (default: blue tint 0.3, bold)
        input = "LvimUiPickerInput", -- the typed-text area (default: blue tint 0.1)
        separator = "LvimUiPickerSeparator", -- the list↔preview divider (default: a muted grey)
        -- list rows (tint canon — odd blue / even yellow stripes, the selected row a STRONG tint)
        row_odd = "LvimUiMsgAreaRowOdd",
        row_even = "LvimUiMsgAreaRowEven",
        sel_odd = "LvimUiMsgAreaSelOdd",
        sel_even = "LvimUiMsgAreaSelEven",
        match = "LvimUiMsgAreaMatch", -- the fuzzy-matched characters
        -- panel winbars (the lvim-lsp peek look)
        list_title = "LvimUiPeekTitle", -- the list title (single-panel layout)
        list_count = "LvimUiPeekCount", -- the result count
        preview_file = "LvimUiPeekFile", -- the previewed file name
        preview_dir = "LvimUiPickerPreviewDir", -- its directory (muted fg on the winbar bg)
        bar = "LvimUiPeekFileBar", -- the winbar fill / blank prompt row
    },

    -- The preview winbar (the file title bar on the preview panel).
    preview = {
        show_icon = true, -- show the file's devicon before the name (needs nvim-web-devicons)
        dir_pad_left = 1, -- spaces before the path
        dir_pad_right = 1, -- spaces after the path
    },

    -- Shown when there are NO results — in the list body AND in the preview's winbar (where the file name
    -- would be). A per-call `opts.empty_text` overrides it.
    empty_text = "[no matches]",

    -- Soft-wrap the LIST rows (no "↳" continuation marker) so a match far to the right of a long row stays
    -- visible instead of being truncated off-screen. A per-call `opts.list_wrap` overrides it.
    list_wrap = false,
}
