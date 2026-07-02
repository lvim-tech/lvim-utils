-- lvim-utils.config.notify: the live defaults for the notify module — the toast/history model, the panel
-- geometry + separators, print()/message interception (ext_messages), per-kind routing, level icons/names,
-- and the :Messages history zone with its filter bar. `setup()` merges the user's `notify = {…}` into this
-- table in place; readers `require("lvim-utils.config").notify`.
--
---@module "lvim-utils.config.notify"

---@class LvimUtilsNotifyConfig
---@field max_history       integer  Ring-buffer size for M.history()
---@field timeout           integer  Auto-dismiss delay in ms; 0 = sticky
---@field dedup             boolean  Collapse identical consecutive toasts into one with a ×N badge
---@field min_width         integer  Panel minimum width
---@field max_width         integer  Panel maximum width
---@field padding           integer  Horizontal padding inside the panel
---@field bottom_margin     integer  Gap (rows) above the statusline
---@field panel_gap         integer  Rows between stacked level panels
---@field border            string   Floating window border (passed to nvim_open_win)
---@field zindex            integer  Floating window z-index
---@field separator         string   Character repeated across the panel width as entry separator
---@field show_separator    boolean  Show a separator line between individual messages in the same panel
---@field override_print    boolean  Replace global print() as well
---@field ext_messages      boolean  Intercept all Neovim messages via vim.ui_attach (ext_messages)
---@field ext_echo_timeout  integer  Timeout (ms) for echo/info-level ext messages
---@field ext_kinds         table<string, string> Per-kind behaviour: "toast" | "history" | "ignore"
---@field printers          table    Active printers on load ("toast" / "history" / { name, fn } / fn)
---@field progress_width    integer|nil Width of the progress panel (nil = max_width)
---@field icons             table<string, string> Level icons
---@field level_names       table<string, string> Singular/plural level names shown in the header bar
---@field history           table    The :Messages history zone + its filter bar

---@type LvimUtilsNotifyConfig
return {
    -- Ring-buffer size for M.history()
    max_history = 100,
    -- Auto-dismiss delay in ms; 0 = sticky
    timeout = 5000,
    -- Collapse identical consecutive toasts into one with a ×N badge (refreshes timeout)
    dedup = true,
    -- Panel width bounds
    min_width = 50,
    max_width = 100,
    -- Horizontal padding inside the panel
    padding = 1,
    -- Gap (rows) ABOVE the statusline: the toast stack is anchored over `cmdheight` + the statusline, so it
    -- sits above the statusline and rides up when the msgarea / cmdline area grows `cmdheight`. 0 = adjacent.
    bottom_margin = 0,
    -- Rows between stacked level panels
    panel_gap = 0,
    -- Floating window border (passed to nvim_open_win)
    border = "none",
    -- Floating window z-index
    zindex = 1000,
    -- Character repeated across the panel width as entry separator
    separator = "─",
    -- Show separator line between individual messages in the same panel
    show_separator = false,
    -- Replace global print() as well
    override_print = true,
    -- Intercept all Neovim messages via vim.ui_attach (ext_messages)
    ext_messages = true,
    -- Timeout (ms) for echo/info-level ext messages
    ext_echo_timeout = 3000,
    -- Per-kind behaviour: "toast" = panel + history, "history" = history only, "ignore" = drop
    ext_kinds = {
        emsg = "toast",
        echoerr = "toast",
        lua_error = "toast",
        rpc_error = "toast",
        shell_err = "toast",
        wmsg = "toast",
        echomsg = "toast",
        echo = "toast",
        bufwrite = "toast",
        undo = "toast",
        shell_out = "history",
        lua_print = "history",
        verbose = "history",
        [""] = "history",
        search_count = "ignore",
        search_cmd = "ignore",
        wildlist = "ignore",
        completion = "ignore",
    },
    -- Active printers on load: "toast", "history", or { name, fn } / fn
    printers = { "toast", "history" },
    -- Width of the progress panel (defaults to max_width when nil)
    progress_width = nil,
    -- Level icons
    icons = {
        trace = "",
        debug = "",
        error = "",
        warn = "",
        info = "",
        hint = "",
        progress = "",
    },
    -- Singular/plural level names shown in the header bar
    level_names = {
        trace = "Trace",
        debug = "Debug",
        info = "Info",
        warn = "Warn",
        error = "Error",
    },

    -- ── Message history / :Messages zone ─────────────────────────────────────────────────────────────
    -- The styled message panel (lvim-utils.msgarea) + its filter bar. Fully customisable here.
    history = {
        target = "cmdline", -- fallback pager when the zone is off: "cmdline" | "split"
        title = "Messages", -- the panel label
        statusline = true, -- true: publish the title + count to the statusline; false: show the title at the LEFT of the bar
        -- The focused filter bar (rendered through ui.bar — navigable buttons + overflow chevrons).
        bar = {
            key_pad = { 1, 1 }, -- the hotkey BADGE padding { front, back }
            label_pad = { 1, 1 }, -- the NAME padding { front, back }
            gap = 0, -- extra spacing inserted between buttons
            -- Background-tint strength (blend toward the bg) per part + state. The two parts brighten together
            -- when a button is HOVERED or is the ACTIVE filter.
            tints = {
                badge = { normal = 0.2, active = 0.4 }, -- the hotkey letter
                name = { normal = 0.1, active = 0.3 }, -- the name
            },
            -- Per-button label override (keyed by id: all/error/warn/info/debug/refresh/close). nil = default.
            labels = {
                all = "All",
                error = "Error",
                warn = "Warn",
                info = "Info",
                debug = "Debug",
                refresh = "Refresh",
                close = "Close",
            },
        },
    },
}
