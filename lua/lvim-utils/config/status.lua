-- lua/lvim-utils/config/status.lua
-- Default configuration for lvim-utils.status — the shared "echo/info" publisher that drives the bottom
-- statusline while a transient action (the navigator, the command-line) is active. Spacing here styles
-- those segments; the colours come from the tint-canon highlight groups (or a caller-supplied hl).

return {
    -- MASTER switch for the whole "echo / info on the bottom statusline" model: when true (default) every
    -- transient action (the command-line, the navigator) publishes its title/counter/action to the
    -- statusline; when false NOTHING uses it (each falls back to drawing its own badge/title in place). The
    -- per-caller flags (cmdline.statusline, the picker `statusline` opt) only fine-tune WITHIN this.
    enabled = true,
    -- Show the typed STRING (search pattern / command / navigator query) as the left action segment.
    -- DEFAULT OFF — the string lives only where you type it (the float / navigator input), the truer
    -- Emacs-minibuffer model where the mode-line does not echo the input. Set true to also echo it here.
    show_action = false,
    -- Show the match / completion COUNTER (current/total) on the right (DEFAULT ON — the anzu-style count).
    show_counter = true,
    -- The ICON badge padding (independent left / right). ` icon  ` by default.
    icon_pad_left = 1,
    icon_pad_right = 2,
    -- The TITLE text padding (independent left / right). ` title ` by default.
    title_pad_left = 1,
    title_pad_right = 1,
    -- Padding on each side of the counter / action segments.
    segment_pad = 1,
}
