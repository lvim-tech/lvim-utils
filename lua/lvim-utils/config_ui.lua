-- lvim-utils.config_ui: the :LvimUtils config settings panel.
--
-- A floating `ui.tabs` panel exposing the runtime-configurable UI geometry (the shared `config.ui.size` —
-- per-layout height/width + auto_max) from `settings.specs` as select rows. Changing a row applies it live
-- (`settings.set` → `config.ui.size` + `store`) so it takes effect on the next opened surface. Standalone: it
-- needs neither lvim-control-center nor sqlite; when the control-center IS present the two panels edit the SAME
-- persisted keys (see settings.lua / store.lua), so they stay in sync.
--
---@module "lvim-utils.config_ui"

local settings = require("lvim-utils.settings")

local M = {}

-- Per-tab (group) icons, like the control-center tabs.
local GROUP_ICONS = {
    Size = "󰒓",
}

--- The ordered list of group names as they first appear in the spec list.
---@return string[]
local function group_order()
    local seen, order = {}, {}
    for _, spec in ipairs(settings.specs) do
        if not seen[spec.group] then
            seen[spec.group] = true
            order[#order + 1] = spec.group
        end
    end
    return order
end

--- Open the configuration panel.
function M.open()
    local ok, ui = pcall(require, "lvim-utils.ui")
    if not ok then
        vim.notify("lvim-utils: the config panel needs the UI module", vim.log.levels.WARN)
        return
    end

    -- One tab per group; each spec becomes a select row carrying its current value (as an option string).
    local by_name, tabs = {}, {}
    for _, group in ipairs(group_order()) do
        local rows = {}
        for _, spec in ipairs(settings.specs) do
            if spec.group == group then
                by_name[spec.name] = spec
                rows[#rows + 1] = {
                    type = spec.type,
                    name = spec.name,
                    label = spec.label,
                    value = settings.get(spec),
                    options = spec.options,
                }
            end
        end
        tabs[#tabs + 1] = { label = group, icon = GROUP_ICONS[group], rows = rows }
    end

    ui.tabs({
        title = "LVIM UTILS",
        title_icon = "󰒓",
        title_pos = "center",
        tabs = tabs,
        on_change = function(row)
            local spec = by_name[row.name]
            if spec then
                settings.set(spec, row.value)
            end
        end,
        position = "editor",
        footer_hints = true, -- bottom key-hint legend, like the control center
    })
end

--- Register the `:LvimUtils` config-panel command. Idempotent (called from lvim-utils.setup).
function M.setup()
    pcall(vim.api.nvim_create_user_command, "LvimUtils", function()
        M.open()
    end, { desc = "lvim-utils: UI geometry config panel" })
end

return M
