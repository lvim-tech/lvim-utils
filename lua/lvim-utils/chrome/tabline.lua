-- lvim-utils.chrome.tabline: the top tabline GLUE — it ships NO predefined sections (like the statusline).
-- All sections live in the user's config; this module only resolves that segment list and runs it through the
-- shared engine (a `%!`-evaluated, GLOBAL `tabline`). The instance is `volatile` (the tabline is redrawn on
-- window / tab / buffer changes by the chrome autocmds via `redrawtabline`, and each redraw recomputes). The
-- sections compose from the helpers — chrome.parts (seg / icons / excluded / unique_name) — never reimplemented
-- here.
--
-- The segment list is `config.chrome.tabline.segments`: a LIST of segment specs, OR a FUNCTION returning one.
--
---@module "lvim-utils.chrome.tabline"

local api = vim.api
local engine = require("lvim-utils.chrome.engine")

local M = {}

--- This component's engine instance — `volatile` (recomputed each redraw, since the tabline is per-tab state);
--- the gap wears the bar fill (LvimUiChromeFill), like the statusline.
---@type LvimChromeEngine
local inst = engine.new({ volatile = true, fill = "LvimUiChromeFill" })

--- The configured tabline section list — a LIST of specs, or a FUNCTION returning one (resolved here). No
--- predefined sections: unset / empty / failing config yields a blank tabline.
---@return LvimChromeSegment[]
local function active_segments()
    local segs = (require("lvim-utils.config").chrome.tabline or {}).segments
    if type(segs) == "function" then
        local ok, res = pcall(segs)
        segs = ok and res or nil
    end
    return type(segs) == "table" and segs or {}
end

--- The `%!`-evaluated tabline string. The engine renders the config's sections.
---@return string
function M.render()
    local win = api.nvim_get_current_win()
    ---@type LvimChromeCtx
    local ctx = { buf = api.nvim_win_get_buf(win), win = win }
    return inst.render(active_segments(), ctx)
end

return M
