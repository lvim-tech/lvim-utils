-- lua/lvim-utils/msgarea/integrations/init.lua
-- Loader for the msgarea source integrations — the per-source glue that routes OTHER UIs (blink.cmp
-- completion, later fzf-lua, the lvim-tech plugin floats, …) INTO the message zone. Each integration
-- is its own module under `msgarea/integrations/<name>.lua` exposing `enable()` / `disable()`; this
-- loader turns them on/off from `config.msgarea.integrations` (a `<name> = true|false` map), so they
-- stay decoupled from the core panel and from each other.
--
---@module "lvim-utils.msgarea.integrations"

local M = {}

-- The integration modules we know about (each is `integrations/<name>.lua`).
---@type string[]
local KNOWN = { "blink", "native" }

---@type table<string, table>  currently-active integrations (name → module)
local active = {}

--- Reconcile the active integrations against `cfg.integrations` (enable the newly-on, disable the
--- newly-off). Safe to call repeatedly (e.g. on a live config change).
---@param cfg table  the merged config.msgarea
function M.setup(cfg)
    local want = (cfg or {}).integrations or {}
    for _, name in ipairs(KNOWN) do
        local on = want[name] == true
        if on and not active[name] then
            local ok, mod = pcall(require, "lvim-utils.msgarea.integrations." .. name)
            if ok and mod and mod.enable then
                pcall(mod.enable)
                active[name] = mod
            end
        elseif not on and active[name] then
            pcall(active[name].disable)
            active[name] = nil
        end
    end
end

--- Disable every active integration (used on msgarea teardown).
function M.teardown()
    for name, mod in pairs(active) do
        pcall(mod.disable)
        active[name] = nil
    end
end

return M
