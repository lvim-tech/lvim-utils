-- lvim-utils.chrome.tabline: the top tabline, a `%!`-evaluated expression modelled on the user's tabby setup
-- (NOT heirline): a vim logo, the current tab's windows (unique names, excluded fts skipped), a `%=` spacer,
-- then lvim-space's tabs · workspace · project.
--
-- Workspace data comes from `require("lvim-space.pub").get_tab_info()` (pcall-guarded; skipped when absent or
-- "Unknown"/""). Windows are listed via the tabpage API + the self-contained uniquifier (no tabby). Visual
-- only — window/tab switching by click is not reproduced (a small, deliberate deviation).
--
---@module "lvim-utils.chrome.tabline"

local api = vim.api
local parts = require("lvim-utils.chrome.parts")

local M = {}

--- The `%!`-evaluated tabline string.
---@return string
function M.render()
    local cfg = require("lvim-utils.config").chrome.tabline or {}
    local ic = parts.icons()
    local out = { parts.seg("TabLogo", " " .. ic.vim .. " ") }

    -- current-tab windows (skip floats + excluded fts)
    local tab = api.nvim_get_current_tabpage()
    local top = api.nvim_tabpage_get_win(tab)
    for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
        if api.nvim_win_get_config(w).relative == "" then
            local buf = api.nvim_win_get_buf(w)
            if not parts.excluded(buf) then
                local grp = (w == top) and "TabActive" or "TabInactive"
                out[#out + 1] = parts.seg(grp, "  " .. parts.unique_name(w) .. "  ")
            end
        end
    end

    out[#out + 1] = "%#LvimUiChromeFill#%="

    -- lvim-space tabs / workspace / project
    if cfg.lvim_space ~= false then
        local ok, pub = pcall(require, "lvim-space.pub")
        if ok and pub.get_tab_info then
            local info = pub.get_tab_info() or {}
            for _, t in ipairs(info.tabs or {}) do
                local grp = t.active and "TabActive" or "TabInactive"
                out[#out + 1] = parts.seg(grp, "  " .. tostring(t.name) .. "  ")
            end
            local ws = info.workspace_name
            if ws and ws ~= "Unknown" and ws ~= "" then
                out[#out + 1] = parts.seg("TabWorkspace", "  " .. ws .. "  ")
            end
            local proj = info.project_name
            if proj and proj ~= "Unknown" and proj ~= "" then
                out[#out + 1] = parts.seg("TabProject", "  " .. proj .. "  ")
            end
        end
    end

    return table.concat(out)
end

return M
