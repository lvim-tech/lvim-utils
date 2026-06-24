-- lua/lvim-utils/config/init.lua
-- Central configuration hub. Loads each module's default config from its
-- own file (config/ui.lua, config/cursor.lua, config/gx.lua) and exposes
-- them as live tables that modules read at call time.
-- setup() deep-merges user overrides into the live tables.

local M = {}

-- Load defaults as independent deep copies so modules can mutate them freely.
local _hl_factory = require("lvim-utils.config.highlight")
M.colors = vim.deepcopy(_hl_factory())
M.ui = vim.deepcopy(require("lvim-utils.config.ui"))
M.cursor = vim.deepcopy(require("lvim-utils.config.cursor"))
M.gx = vim.deepcopy(require("lvim-utils.config.gx"))
M.notify = vim.deepcopy(require("lvim-utils.config.notify"))
M.cmdline = vim.deepcopy(require("lvim-utils.config.cmdline"))
M.input = vim.deepcopy(require("lvim-utils.config.input"))
M.msgarea = vim.deepcopy(require("lvim-utils.config.msgarea"))
M.chrome = vim.deepcopy(require("lvim-utils.config.chrome"))
M.fuzzy = vim.deepcopy(require("lvim-utils.config.fuzzy"))
M.picker = vim.deepcopy(require("lvim-utils.config.picker"))
M.dashboard = vim.deepcopy(require("lvim-utils.config.dashboard"))

---Merge user-provided options into each module's config.
---@param opts? { ui?: table, cursor?: table, gx?: table, notify?: table, cmdline?: table, input?: table, msgarea?: table, chrome?: table, fuzzy?: table, picker?: table, dashboard?: table }
function M.setup(opts)
    opts = opts or {}
    if opts.ui then
        M.ui = vim.tbl_deep_extend("force", M.ui, opts.ui)
    end
    if opts.cursor then
        M.cursor = vim.tbl_deep_extend("force", M.cursor, opts.cursor)
    end
    if opts.gx then
        M.gx = vim.tbl_deep_extend("force", M.gx, opts.gx)
    end
    if opts.notify then
        M.notify = vim.tbl_deep_extend("force", M.notify, opts.notify)
    end
    if opts.cmdline then
        M.cmdline = vim.tbl_deep_extend("force", M.cmdline, opts.cmdline)
    end
    if opts.input then
        M.input = vim.tbl_deep_extend("force", M.input, opts.input)
    end
    if opts.msgarea then
        M.msgarea = vim.tbl_deep_extend("force", M.msgarea, opts.msgarea)
    end
    if opts.chrome then
        -- utils.merge replaces LIST values wholesale (so a user `exclude.filetype` overrides, not index-merges).
        require("lvim-utils.utils").merge(M.chrome, opts.chrome)
    end
    if opts.fuzzy then
        -- `sort` may be a string OR a list OR a function — replace it wholesale (deep_extend would merge a
        -- list element-wise). Merge the rest, then overwrite sort if the user gave one.
        M.fuzzy = vim.tbl_deep_extend("force", M.fuzzy, opts.fuzzy)
        if opts.fuzzy.sort ~= nil then
            M.fuzzy.sort = opts.fuzzy.sort
        end
    end
    if opts.picker then
        M.picker = vim.tbl_deep_extend("force", M.picker, opts.picker)
    end
    if opts.dashboard then
        -- utils.merge replaces LIST values wholesale (so a user `sections` / `preset.keys` overrides, not
        -- index-merges into the defaults).
        require("lvim-utils.utils").merge(M.dashboard, opts.dashboard)
    end
end

--- Rebuild the UI/notify highlight group map from the live palette and publish it as
--- `M.colors` for readers. Bound via `highlight.bind` in setup() so the groups self-theme:
--- applied with `default = true` and re-applied automatically on palette change.
---@param colors? table  the live palette (passed by highlight.bind)
---@return table<string, table>
function M.rebuild_highlights(colors)
    M.colors = _hl_factory(colors)
    return M.colors
end

return M
