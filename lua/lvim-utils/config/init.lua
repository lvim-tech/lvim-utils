-- lvim-utils.config: the base configuration hub. After the split, lvim-utils is the BASE plugin — it owns only
-- the palette-derived highlight group map (the central factory every lvim-tech plugin reads BY NAME) and the
-- cursor config. Every other module's config now lives in its own plugin (`lvim-<plugin>.config`). setup()
-- merges user overrides into the live tables IN PLACE via lvim-utils.utils.merge — never reassigning them — so
-- a module that hoisted a `local cfg = config.<mod>` alias at load keeps seeing the effective values.
--
---@module "lvim-utils.config"

local merge = require("lvim-utils.utils").merge

local M = {}

-- The central highlight factory: builds the full LvimUi* / LvimNotify* / LvimUiMsgArea* / LvimUiDashboard* /
-- LvimUiChrome* group map from the live palette. It STAYS in the base because every split plugin references
-- those groups BY NAME (they don't redefine them) — this is the one theming source of truth. Loaded as an
-- independent deep copy so readers can mutate it freely.
local _hl_factory = require("lvim-utils.config.highlight")
M.colors = vim.deepcopy(_hl_factory())
M.cursor = vim.deepcopy(require("lvim-utils.config.cursor"))

--- Merge user-provided options into the base config tables, in place.
---@param opts? { cursor?: table }
function M.setup(opts)
    opts = opts or {}
    if opts.cursor then
        merge(M.cursor, opts.cursor)
    end
end

--- Rebuild the highlight group map from the live palette and publish it as `M.colors` for readers. Bound via
--- `highlight.bind` in setup() so the groups self-theme: applied with `default = true` and re-applied
--- automatically on palette change.
---@param colors? table  the live palette (passed by highlight.bind)
---@return table<string, table>
function M.rebuild_highlights(colors)
    M.colors = _hl_factory(colors)
    return M.colors
end

return M
