-- lua/lvim-utils/config/msgarea.lua
-- Live config for the persistent, toggleable message area (lvim-utils.msgarea). A docked split
-- under (or over) the editor that ACCUMULATES messages routed to it by the notify hub, so they
-- stay readable instead of vanishing. setup() merges user opts into this table IN PLACE; readers
-- do `require("lvim-utils.config").msgarea` and see the effective values.
--
---@module "lvim-utils.config.msgarea"

return {
    enable = false, -- master switch (live-toggleable via :LvimMessages / M.toggle)

    -- ── Height — `max_height` is the ONLY hard rule ─────────────────────────────────────────────
    -- Units (both heights): a value >= 1 is an ABSOLUTE line count; a value < 1 is a FRACTION of
    -- `vim.o.lines`. Resolved fresh on every (re)size so it tracks window resizes.
    max_height = 10, -- the panel is NEVER taller than this
    auto_resize = true, -- true: fit content up to the cap (5 rows -> 5 tall); false: always max_height
    min_height = 1, -- floor while auto-resizing (ignored when auto_resize = false)

    -- ── Placement / lifecycle ───────────────────────────────────────────────────────────────────
    -- The zone is BOTTOM-docked by design: it lays a float over the `cmdheight` region (so heirline /
    -- a global statusline stays above it and the unified cmdline is hosted at the very bottom). It opens
    -- automatically when a segment has content and hides when the whole stack is empty — there is no
    -- top placement or auto-open/close toggle (they would contradict the cmdheight-float model).
    focusable = true, -- can be focused (to scroll / interact) — but NEVER auto-focused

    -- ── Unified minibuffer (cmdline `:` `/` `?` rendered IN the zone) ─────────────────────────────
    -- When true (and lvim-utils.cmdline is active), the command-line / search input is drawn at the
    -- BOTTOM of THIS zone instead of its own float — an Emacs-style minibuffer. The panel is kept
    -- open (persistent) so the cmdline always has its place; with auto_resize it shrinks to ~the
    -- winbar + 1 row when idle. The cmdline reserves its rows ON TOP of `max_height` (so input is
    -- always fully visible, never hidden by the scrollback cap).
    unified = false,

    -- ── Content ─────────────────────────────────────────────────────────────────────────────────
    scrollback = 500, -- max retained message lines (ring buffer; oldest dropped)
    completion_max = 12, -- max intercepted completion ROWS shown at once (windowed around the selection)
    completion_columns = 1, -- grid columns: 1 = a list; 2/3/4… = a row-major grid (navigated by the grid)
    wrap = true, -- soft-wrap long lines
    follow = true, -- tail: keep the newest line in view on append
    dedup = true, -- collapse a repeated consecutive message into "message  (xN)"
    icons = true, -- a per-level icon badge (reuses notify's level icons)
    timestamps = false, -- prefix each message with its capture time
    time_format = "%H:%M:%S",

    -- ── Chrome ──────────────────────────────────────────────────────────────────────────────────
    winbar = false, -- a thin title / summary row at the top of the panel (off: a compact minibuffer)
    title = "Messages",

    -- ── Routing ─────────────────────────────────────────────────────────────────────────────────
    -- Which message KINDS land in the zone. Folded into notify's `ext_kinds` when enabled (and
    -- restored on disable). A kind set to "msgarea" is rendered here instead of toast/cmdline.
    kinds = {
        lua_error = "msgarea",
        emsg = "msgarea",
        echoerr = "msgarea",
        echomsg = "msgarea",
        echo = "msgarea",
        wmsg = "msgarea",
        shell_out = "msgarea",
        shell_err = "msgarea",
    },

    -- ── Integrations ─────────────────────────────────────────────────────────────────────────────
    -- Per-source opt-in glue that routes other UIs INTO the zone. Each is its own module under
    -- `msgarea/integrations/` with `enable()` / `disable()`; only the enabled ones load.
    integrations = {
        blink = false, -- blink.cmp completion menu docks at the zone (above the command line)
    },

    -- ── Keys (active only while the panel is FOCUSED) ────────────────────────────────────────────
    keys = {
        close = "q", -- hide the panel (the model is kept)
        clear = "C", -- wipe the scrollback
        scroll_up = "<C-u>",
        scroll_down = "<C-d>",
        top = "gg",
        bottom = "G",
    },
}
