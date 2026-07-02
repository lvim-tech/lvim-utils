-- lvim-utils.config.input: the live defaults for the input dispatcher — routes vim.ui.input to either the
-- self-rendered command-line or the popup (lvim-utils.ui). Per-call control via the `ui` field on the opts, a
-- one-shot route_next(), or this default. `setup()` merges the user's `input = {…}` into this table in place;
-- readers `require("lvim-utils.config").input`. Opt-in.
--
---@module "lvim-utils.config.input"

---@class LvimUtilsInputConfig
---@field enable  boolean  Master switch for the input dispatcher
---@field default string   Default target when neither opts.ui nor route_next() is set: "cmdline" | "popup"

---@type LvimUtilsInputConfig
return {
    enable = false,
    -- Default target when neither opts.ui nor route_next() is set: "cmdline" | "popup".
    default = "popup",
}
