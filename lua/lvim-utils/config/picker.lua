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
        icon = vim.fn.nr2char(0xf002), -- a leading glyph (nf search by default; set "" for none)
        label = "", -- optional text after the icon (e.g. "Search")
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
        preview_dir = "LvimUiPeekDir", -- its directory
        bar = "LvimUiPeekFileBar", -- the winbar fill / blank prompt row
    },
}
