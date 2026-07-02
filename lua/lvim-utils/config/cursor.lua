-- lvim-utils.config.cursor: live config for the cursor-hiding module (lvim-utils.cursor). The
-- module hides the hardware cursor whenever a buffer with a REGISTERED filetype owns the screen.
-- setup() merges user opts into this table in place; readers do `require("lvim-utils.config").cursor`.
--
---@module "lvim-utils.config.cursor"

---@class LvimUtilsCursorConfig
---@field ft              string[] Transient-popup filetypes: hide the cursor whenever such a buffer
---                                is visible in ANY window (a modal popup owns the screen).
---@field panel_ft        string[] Persistent side-panel filetypes: hide the cursor ONLY while such a
---                                panel is the CURRENT window (never globally — the cursor stays
---                                visible in the code beside an always-open panel).
---@field hide_on_cmdline boolean  Hide the hardware cursor while the command-line is active (a
---                                self-rendered cmdline draws its own caret, so the buffer cursor is
---                                redundant). Default false: with the native cmdline keep it shown.

---@type LvimUtilsCursorConfig
return {
    ft = {},
    panel_ft = {},
    hide_on_cmdline = false,
}
