-- lua/lvim-utils/config/input.lua
-- Default configuration for the input dispatcher: routes vim.ui.input to either the
-- self-rendered command-line or the popup (lvim-utils.ui). Per-call control via the
-- `ui` field on the opts, a one-shot route_next(), or this default. Opt-in.

return {
    enable = false,
    -- Default target when neither opts.ui nor route_next() is set: "cmdline" | "popup".
    default = "popup",
}
