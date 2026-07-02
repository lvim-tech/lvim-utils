-- lvim-utils.config: the central configuration hub for every lvim-utils module.
-- Loads each module's default config from its own file (config/ui.lua, config/cursor.lua,
-- config/gx.lua, …) into ONE live table per module, and exposes them as tables that modules
-- read at call time. setup() merges user overrides into those live tables IN PLACE via
-- lvim-utils.utils.merge — never reassigning them — so a module that hoisted a `local cfg =
-- config.<mod>` alias at load keeps seeing the effective values, and a shorter override LIST
-- cleanly REPLACES the default (not an index-merge that leaves stale tail elements).
--
---@module "lvim-utils.config"

local merge = require("lvim-utils.utils").merge

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

--- Merge user-provided options into each module's LIVE config table, in place. Every module
--- config is merged with the same `utils.merge` (deep-merge maps, REPLACE lists/scalars whole),
--- so the merge is uniform and a user's shorter list (e.g. `cmdline.newline_keys = {}`,
--- `picker.source.exclude = {...}`, `fuzzy.sort = {...}`) truly replaces the default instead of
--- leaving stale trailing entries.
---@param opts? { ui?: table, cursor?: table, gx?: table, notify?: table, cmdline?: table, input?: table, msgarea?: table, chrome?: table, fuzzy?: table, picker?: table, dashboard?: table }
function M.setup(opts)
    opts = opts or {}
    if opts.ui then
        merge(M.ui, opts.ui)
    end
    if opts.cursor then
        merge(M.cursor, opts.cursor)
    end
    if opts.gx then
        merge(M.gx, opts.gx)
    end
    if opts.notify then
        merge(M.notify, opts.notify)
    end
    if opts.cmdline then
        merge(M.cmdline, opts.cmdline)
    end
    if opts.input then
        merge(M.input, opts.input)
    end
    if opts.msgarea then
        merge(M.msgarea, opts.msgarea)
    end
    if opts.chrome then
        merge(M.chrome, opts.chrome)
    end
    if opts.fuzzy then
        -- `sort` may be a string OR a list OR a function — merge REPLACES each wholesale, so all
        -- three forms land correctly without a special case.
        merge(M.fuzzy, opts.fuzzy)
    end
    if opts.picker then
        merge(M.picker, opts.picker)
    end
    if opts.dashboard then
        merge(M.dashboard, opts.dashboard)
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
