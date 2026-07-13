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
-- The dock-stack manager's live config (lvim-utils.dock reads `require("lvim-utils.config").dock`).
M.dock = vim.deepcopy(require("lvim-utils.config.dock"))

-- Collapsible SECTION-HEADER tinting, GLOBAL for every lvim-tech fold (read by highlight.section_accent).
-- `tint` = how far the header's accent is blended onto the bg at rest; `tint_hover` = while the cursor hovers
-- the header. One knob for the whole set — change it here and every plugin's fold headers follow.
---@class LvimUtilsSectionConfig
---@field tint number        -- rest band blend factor toward the accent (0..1), default 0.1
---@field tint_hover number  -- hover band blend factor (0..1), default 0.2
M.section = { tint = 0.1, tint_hover = 0.2 }

-- The SHARED chrome tint scale (read by config/highlight.lua's factory) — how far an accent is blended onto
-- the background. One scale for the whole set: change it here and every panel, bar and title follows.
-- (The factory always claimed these were overridable through `ui.tint`, but `M.ui` did not exist — so the
-- literals in the factory were the only values there ever were. This is that promised seam, made real.)
-- The SHARED chrome THEME SPEC — every tint strength + every accent the UI paints with, named by ROLE
-- (`lvim-utils.config.ui`). The highlight factory reads ONLY this: no tint or colour is decided in code any
-- more, so retuning the whole set's chrome is a config edit.
M.ui = vim.deepcopy(require("lvim-utils.config.ui"))

--- Merge user-provided options into the base config tables, in place.
---@param opts? { cursor?: table, dock?: table, section?: LvimUtilsSectionConfig, ui?: LvimUtilsUiConfig }
function M.setup(opts)
    opts = opts or {}
    if opts.cursor then
        merge(M.cursor, opts.cursor)
    end
    if opts.dock then
        merge(M.dock, opts.dock)
    end
    if opts.section then
        merge(M.section, opts.section)
    end
    if opts.ui then
        merge(M.ui, opts.ui)
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
