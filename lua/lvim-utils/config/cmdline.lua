-- lua/lvim-utils/config/cmdline.lua
-- Default configuration for the cmdline module: a self-rendered command-line
-- (own float + buffer) driven by Neovim's ext_cmdline UI events. Owning the buffer
-- lets us reserve real space for a padded icon badge — impossible when decorating
-- the built-in cmdline. Opt-in via setup({ cmdline = { enable = true } }).

return {
    enable = false,
    -- Messages routed here (via notify ext_kinds -> "cmdline") are shown in the float.
    -- Configure which kinds in the host's notify.ext_kinds (e.g. lua_print = "cmdline").
    message = {
        enable = true,
        glyph = "",
        hl = "LvimUiCmdlineInput",
        timeout = 0, -- 0 = persist until a dismiss key; >0 = auto-hide after N ms
        -- Keys that clear a persistent message (Vim notation; "esc" accepted). List.
        dismiss_keys = { "<Esc>" },
    },
    -- Statusline integration (default on): publish the cmdline MODE (label + glyph) and the completion
    -- match counter to the bottom statusline (lvim-utils.status), so the line shows the current action like
    -- the navigator. The float then keeps only the glyph as a compact prompt prefix (the static label moves
    -- to the statusline). false = keep the full mode label badge in the float, nothing in the statusline.
    statusline = true,
    -- The float's mode badge padding (when the badge is shown in the float — i.e. `statusline = false`, or
    -- an input() prompt). Independent spaces left of / right of the glyph (the gap to the label / text).
    badge_pad_left = 2,
    badge_pad_right = 2,
    -- Rows of extra offset above the cmdheight area.
    row_offset = 0,
    -- Max float height; false = auto (≈ half the screen). Long input wraps + grows up.
    max_height = false,
    -- Cmdline-mode keys that insert a literal newline (multi-line command input).
    -- Set to {} to disable.
    newline_keys = { "<M-CR>" },
    -- firstc -> { glyph, label, hl }. The left panel shows " <glyph> <label> "; for the
    -- input mode (@) the live prompt (e.g. "New name: ") is used instead of the label.
    modes = {
        [":"] = { glyph = "", label = "Command", hl = "LvimUiCmdlineCommand" },
        ["/"] = { glyph = "", label = "Search ↓ down", hl = "LvimUiCmdlineSearch" },
        ["?"] = { glyph = "", label = "Search ↑ up", hl = "LvimUiCmdlineSearch" },
        ["="] = { glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
        ["@"] = { glyph = "", label = "", hl = "LvimUiCmdlineInput" },
    },
    fallback = { glyph = "", label = "", hl = "LvimUiCmdlineCommand" },
    -- Content sub-modes for ":" commands (first match wins). Each is like a mode
    -- entry plus a Lua-pattern `match` tested against the typed command text.
    patterns = {
        { match = "^lua[ =]", strip = "^lua%s*=?%s*", glyph = "", label = "Lua", hl = "LvimUiCmdlineLua" },
        { match = "^=", strip = "^=%s*", glyph = "", label = "Expr", hl = "LvimUiCmdlineEval" },
        { match = "^!", strip = "^!%s*", glyph = "", label = "Shell", hl = "LvimUiCmdlineShell" },
        { match = "^%S*s/", glyph = "", label = "Substitute", hl = "LvimUiCmdlineSubstitute" },
        { match = "^setl?%a* ", strip = "^set%a*%s+", glyph = "", label = "Set", hl = "LvimUiCmdlineSet" },
    },
}
