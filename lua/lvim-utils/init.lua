-- lua/lvim-utils/init.lua
-- Entry point for lvim-utils. Exposes all sub-modules and provides a single
-- setup() call that configures every module from one options table.

local M = {}

M.config = require("lvim-utils.config")
M.colors = require("lvim-utils.colors")
M.cursor = require("lvim-utils.cursor")
M.colorcolumn = require("lvim-utils.colorcolumn")
M.highlight = require("lvim-utils.highlight")
M.ui = require("lvim-utils.ui")
M.quit = require("lvim-utils.quit")
M.gx = require("lvim-utils.gx")
M.notify = require("lvim-utils.notify")
M.cmdline = require("lvim-utils.cmdline")
M.input = require("lvim-utils.input")
M.msgarea = require("lvim-utils.msgarea")
M.chrome = require("lvim-utils.chrome")
M.picker = require("lvim-utils.picker")
M.dashboard = require("lvim-utils.dashboard")

---Setup lvim-utils.
---@param opts? { highlights?: table<string, table>, colors?: table, ui?: table, cursor?: table, colorcolumn?: table, gx?: table, notify?: table, cmdline?: table, input?: table, msgarea?: table, chrome?: table, fuzzy?: table, picker?: table, dashboard?: table }
function M.setup(opts)
    opts = opts or {}

    -- 1. Palette overrides first — other modules read colors after this.
    if opts.colors then
        M.colors.setup(opts.colors)
    end

    -- 2. Merge module configs so each module reads updated values.
    M.config.setup({
        ui = opts.ui,
        cursor = opts.cursor,
        gx = opts.gx,
        notify = opts.notify,
        cmdline = opts.cmdline,
        input = opts.input,
        msgarea = opts.msgarea,
        chrome = opts.chrome,
        fuzzy = opts.fuzzy,
        picker = opts.picker,
        dashboard = opts.dashboard,
    })

    -- 3. Self-theme the UI/notify groups from the fully-configured palette via bind():
    --    applied with `default = true` so a non-lvim colorscheme (or the user) can override
    --    them, and re-applied automatically on palette/ColorScheme change. An explicit user
    --    `highlights` override applies hard (force). Then install the ColorScheme autocmd.
    M.highlight.bind(M.config.rebuild_highlights)
    if opts.highlights then
        M.highlight.register(opts.highlights, true)
    end
    M.highlight.setup()

    -- 4. Activate palette sync from lvim-colorscheme (idempotent).
    M.colors._activate()

    if opts.cursor then
        M.cursor.setup(opts.cursor)
    end

    -- colorcolumn: keep 'colorcolumn' meaningful under 'wrap' (drop entries that would otherwise wrap to a
    -- stray cell on a continuation row). Opt-in; `colorcolumn.enabled = false` sets up but stays inert.
    if opts.colorcolumn then
        M.colorcolumn.setup(opts.colorcolumn)
    end

    if opts.gx then
        M.gx.setup()
    end

    -- notify = false opts out entirely; any other value (including nil) activates with defaults.
    if opts.notify ~= false then
        M.notify.setup(opts.notify or {})
    end

    -- cmdline is opt-in (config default enable=false); setup() no-ops unless enabled.
    if opts.cmdline ~= false then
        M.cmdline.setup(M.config.cmdline)
    end

    -- input dispatcher (vim.ui.input → cmdline/popup); opt-in, no-ops unless enabled.
    if opts.input ~= false then
        M.input.setup(M.config.input)
    end

    -- message area (notify "msgarea" sink + docked panel); opt-in, no-ops unless enabled.
    -- Runs AFTER notify.setup so its sink/routing land on the live notify config.
    if opts.msgarea ~= false then
        M.msgarea.setup(M.config.msgarea)
    end

    -- editor chrome: statusline / winbar / tabline / statuscolumn + the folded transient finder/echo overlay.
    -- The float guard (last regular buffer while a UI float is focused) is built into the statusline now.
    if opts.chrome ~= false then
        M.chrome.setup()
    end

    -- the unified `:LvimPicker <finder> [layout]` command (one entry point for every finder).
    M.picker.setup_command()

    -- the start dashboard: `:LvimDashboard` + the empty-startup auto-open (no-op unless dashboard.enable).
    M.dashboard.setup()

    -- runtime UI-geometry settings (config.ui.size): restore persisted values from the shared store
    -- (control-center DB when present, else a JSON file) and register lvim-utils' own :LvimUtils config panel.
    -- Standalone — needs neither the control-center nor sqlite — but syncs with the control-center when both live.
    require("lvim-utils.settings").restore()
    require("lvim-utils.config_ui").setup()
end

return M
