-- lua/lvim-utils/config/dashboard.lua
-- Default configuration for the START DASHBOARD (lvim-utils.dashboard): a declarative, section-based greeter
-- buffer — the same model as snacks.nvim's dashboard, reimplemented on the lvim-utils stack (own palette
-- self-theming, lvim-utils.picker for the `pick` actions, a clean single-teardown lifecycle). `setup()`
-- merges the user's `dashboard = {…}` into THIS table in place (via lvim-utils.utils.merge — LIST values like
-- `sections` / `preset.keys` REPLACE wholesale, never index-merge), and readers do
-- `require("lvim-utils.config").dashboard` to see the effective values. Opt-in via
-- `setup({ dashboard = { enable = true } })`.
--
---@module "lvim-utils.config.dashboard"

return {
    -- Master switch. false = the module does nothing (no auto-open, `:LvimDashboard` is not registered).
    enable = false,

    -- AUTO-OPEN the dashboard on startup when Neovim is launched with no file (empty buffer, single window,
    -- not piped stdin) — like the native intro screen. false = only open on demand (`:LvimDashboard`).
    auto_open = true,

    -- Optional extra gate on the auto-open: a `fun(): boolean` returning FALSE to SUPPRESS the dashboard even
    -- on an empty startup. Generic (no knowledge of any other plugin) — wire it in your config to defer to
    -- something that will own the startup screen itself, e.g. a session/project manager that will load a
    -- project for the cwd (so the greeter never flashes before it takes over). nil = no extra gate.
    ---@type (fun(): boolean)?
    should_open = nil,

    -- HIDE the hardware cursor while the dashboard is up (the active row is shown by its tinted cell instead).
    -- Driven by lvim-utils.cursor; false = keep the normal cursor.
    hide_cursor = true,

    -- The dashboard PANE width (one column's character width). Panes (see `sections[*].pane`) are laid out
    -- side by side, this wide each, centred in the window.
    width = 60,
    -- Fixed vertical / horizontal position (rows / cols); nil = centred in the window.
    row = nil,
    col = nil,
    -- Empty columns BETWEEN side-by-side panes.
    pane_gap = 4,

    -- The pool of keys auto-assigned (in order) to items that ask for one (`autokey = true`, e.g. each recent
    -- file / project row), skipping the reserved nav keys (h/j/k/l/q) and any key already taken explicitly.
    autokeys = "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",

    -- Shared building blocks the built-in sections pull from — DEFINE THESE IN YOUR CONFIG. Like the chrome
    -- components, this module ships the ENGINE only; the CONTENT (the menu, the banner) is yours, so the
    -- defaults are empty. Set them via `setup({ dashboard = { preset = { keys = {…}, header = "…" } } })`.
    preset = {
        -- The `pick(source, opts)` backend for key actions that open a finder. nil = the built-in, which uses
        -- lvim-utils.picker (`source` = a finder name: "files" / "grep" / "oldfiles" / …). Set a function
        -- `fun(source, opts)` to use your own finder.
        pick = nil,
        -- The KEY rows for the `keys` section: each `{ icon, key, desc, action, enabled? }`. `action` is a
        -- `:Cmd` string, a raw-keys string, or a `fun(self)`. EMPTY by default — define your menu in config.
        keys = {},
        -- The HEADER (ASCII banner) for the `header` section. EMPTY by default — set your own banner in config.
        header = "",
    },

    -- The SECTIONS rendered, top to bottom — DEFINE YOUR LAYOUT IN YOUR CONFIG. Each entry is an item TABLE, a
    -- generator FUNCTION `fun(self)` returning item(s), or `{ section = "<name>", … }` referencing a built-in
    -- (header / keys / recent_files / projects / startup / session). Item fields: text / icon / key / desc /
    -- title / action / pane / align / indent / padding / gap / hl / label / file / header / footer / enabled /
    -- autokey / hidden. The default just wires the built-in sections to your `preset`; REPLACE it wholesale to
    -- design your own (panes, recent files, projects, custom function items, …).
    sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1 },
        { section = "startup" },
    },

    -- Per-FIELD formatters — how `icon` / `header` / `footer` / `file` item fields become styled text. A
    -- template `{ "%s", align = … }` substitutes the field value into `%s`; a `fun(item, ctx)` returns the
    -- text chunk(s). Override to restyle.
    formats = {
        header = { "%s", align = "center" },
        footer = { "%s", align = "center" },
        -- a literal icon (width-2, the LvimUiDashboardIcon group); a `file` item with icon "file" /
        -- "directory" resolves the file's devicon instead (see the dashboard render module).
        icon = { "%s", width = 2, hl = "icon" },
        -- `file` items shorten the path (~ for $HOME, then pathshorten when too wide) — handled in render.
    },

    -- Highlight groups for every element — all overridable, all default to the self-themed LvimUiDashboard*
    -- groups (registered in config/highlight.lua, derived from the live palette).
    -- Leading glyphs the render engine falls back to for `file` items resolving to "file"/"directory"
    -- when nvim-web-devicons has no specific icon. Real Nerd glyphs.
    icons = {
        file = "", -- nf-fa-file
        directory = "", -- nf-fa-folder
    },

    hl = {
        header = "LvimUiDashboardHeader", -- the ASCII banner
        footer = "LvimUiDashboardFooter", -- a footer line
        icon = "LvimUiDashboardIcon", -- a key/file leading glyph
        key = "LvimUiDashboardKey", -- the keyboard shortcut (right side)
        desc = "LvimUiDashboardDesc", -- a key row's description
        title = "LvimUiDashboardTitle", -- a section title ("Recent Files", "Projects")
        file = "LvimUiDashboardFile", -- a file name
        dir = "LvimUiDashboardDir", -- a file's directory part
        special = "LvimUiDashboardSpecial", -- emphasised inline text (the startup counts)
        normal = "LvimUiDashboardNormal", -- the buffer background / plain text
        cursorline = "LvimUiDashboardCursorLine", -- the active item's row cell (a subtle bg tint)
    },

    -- The dashboard buffer / window options (a clean, chrome-free scratch buffer).
    bo = {
        bufhidden = "wipe",
        buftype = "nofile",
        buflisted = false,
        filetype = "lvim-dashboard",
        swapfile = false,
        undofile = false,
        modifiable = false,
    },
    wo = {
        colorcolumn = "",
        cursorcolumn = false,
        cursorline = false,
        foldmethod = "manual",
        list = false,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        spell = false,
        statuscolumn = "",
        wrap = false,
    },

    -- Trace the render/resolve passes to `:messages` (debugging only).
    debug = false,
}
