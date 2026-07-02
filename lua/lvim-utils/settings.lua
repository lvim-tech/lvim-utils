-- lvim-utils.settings: the runtime-configurable UI geometry (the shared `config.ui.size` — per-layout
-- height/width + auto_max).
--
-- ONE spec list drives BOTH lvim-utils' own config panel (`config_ui`) AND lvim-control-center (the setting
-- `name`s match control-center's, so the two panels edit the same persisted keys and never drift). Values are
-- applied LIVE into `config.ui.size` and persisted via `store` (control-center sqlite when present, else a JSON
-- file — see store.lua). Each dimension is a fraction 0.1–1.0 of the available space, or "auto" (fit content up
-- to `auto_max`). Stored/edited as OPTION STRINGS ("auto", "0.8", …) so sqlite's text column round-trips cleanly;
-- `decode`/`encode` convert to/from the number the config holds.
--
---@module "lvim-utils.settings"

local store = require("lvim-utils.store")

local M = {}

-- The discrete choices for a size dimension: "auto" + 1.0 … 0.1 (strings — see the module header).
local SIZE_OPTIONS = { "auto", "1.0", "0.9", "0.8", "0.7", "0.6", "0.5", "0.4", "0.3", "0.2", "0.1" }
local AUTO_MAX_OPTIONS = { "1.0", "0.95", "0.9", "0.85", "0.8", "0.75", "0.7", "0.6", "0.5" }

--- Option string → the value the config holds ("auto" stays a string; "0.8" → 0.8).
---@param v any
---@return any
local function decode(v)
    if v == "auto" then
        return "auto"
    end
    return tonumber(v) or v
end

--- Config value → the option string the panel / store use (0.8 → "0.8"; "auto" stays "auto").
---@param v any
---@return any
local function encode(v)
    if v == "auto" or v == nil then
        return v
    end
    return type(v) == "number" and ("%.2f"):format(v):gsub("0$", ""):gsub("%.$", "") or tostring(v)
end

---@class LvimUtilsSpec
---@field name    string    persistence key (matches the control-center setting name)
---@field path    string[]  nested location under `config.ui.size`
---@field group   string    panel tab / control-center group
---@field label   string    display label
---@field type    string    "select"
---@field options string[]  choices (option strings)
---@field default any       fallback config value when nothing is persisted

---@type LvimUtilsSpec[]
M.specs = {
    {
        name = "ui_size_float_height",
        path = { "float", "height" },
        group = "Size",
        label = "Float height",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.8,
    },
    {
        name = "ui_size_float_width",
        path = { "float", "width" },
        group = "Size",
        label = "Float width",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.7,
    },
    {
        name = "ui_size_area_height",
        path = { "area", "height" },
        group = "Size",
        label = "Area height",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.6,
    },
    {
        name = "ui_size_bottom_height",
        path = { "bottom", "height" },
        group = "Size",
        label = "Bottom height",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.4,
    },
    {
        name = "ui_size_auto_max",
        path = { "auto_max" },
        group = "Size",
        label = "Auto max",
        type = "select",
        options = AUTO_MAX_OPTIONS,
        default = 0.85,
    },
}

--- The live `config.ui.size` table (created if missing).
---@return table
local function size_tbl()
    local ui = require("lvim-utils.config").ui
    ui.size = ui.size or {}
    return ui.size
end

--- Read a nested value by path.
local function read_path(t, path)
    for _, k in ipairs(path) do
        if type(t) ~= "table" then
            return nil
        end
        t = t[k]
    end
    return t
end

--- Write a nested value by path (creating intermediate tables).
local function write_path(t, path, v)
    for i = 1, #path - 1 do
        t[path[i]] = t[path[i]] or {}
        t = t[path[i]]
    end
    t[path[#path]] = v
end

--- Propagate a changed setting to the live UI. `area` height / `auto_max` feed the msgarea zone's cap, so
--- refresh an OPEN zone (the next open of any consumer reads `config.ui.size` regardless). Guarded — a missing
--- msgarea is fine.
---@param spec LvimUtilsSpec
local function apply(spec)
    if spec.path[1] == "area" or spec.path[1] == "auto_max" then
        pcall(function()
            local ma = require("lvim-utils.msgarea")
            if ma.refresh then
                ma.refresh()
            end
        end)
    end
end

--- The current value of `spec` as an OPTION STRING (for the panel / control-center to match a choice).
---@param spec LvimUtilsSpec
---@return any
function M.get(spec)
    local v = read_path(size_tbl(), spec.path)
    if v == nil then
        v = spec.default
    end
    return encode(v)
end

--- Apply a new value (an option string) LIVE into `config.ui.size` and persist it.
---@param spec LvimUtilsSpec
---@param value any    an option string ("auto" / "0.8")
---@param persist? boolean  default true; false while restoring FROM the store
function M.set(spec, value, persist)
    write_path(size_tbl(), spec.path, decode(value))
    if persist ~= false then
        store.save(spec.name, value)
    end
    apply(spec)
end

--- An lvim-control-center GROUP (LccGroup) built from the specs, so the control-center shows the SAME size
--- settings as lvim-utils' own `:LvimUtils` panel. The setting names match, so both edit the same persisted
--- keys (see store.lua) — zero drift. The control-center DELEGATES persistence to `setting.set` when it exists
--- (it does NOT also call its own DB write), so `set` MUST persist a real change — hence `M.set(spec, value,
--- not is_load)`: persist on a user change, skip re-persisting while the control-center is applying saved
--- values at startup (`is_load = true`). Both panels then write to the shared store and restore identically.
---@return table  LccGroup { name, label, icon, settings }
function M.lcc_group()
    local list = {}
    for _, spec in ipairs(M.specs) do
        list[#list + 1] = {
            name = spec.name,
            type = spec.type,
            label = spec.label,
            options = spec.options,
            default = encode(spec.default),
            get = function()
                return M.get(spec)
            end,
            set = function(value, is_load)
                M.set(spec, value, not is_load)
            end,
        }
    end
    return { name = "Utils", label = "Utils", icon = "󰒓", settings = list }
end

--- Restore persisted values into `config.ui.size`. Seeds the control-center DB from the JSON store the first
--- time they cohabit, then applies each stored value live (without re-persisting). Call once after setup.
function M.restore()
    local names = {}
    for _, s in ipairs(M.specs) do
        names[#names + 1] = s.name
    end
    store.migrate(names)
    for _, spec in ipairs(M.specs) do
        local v = store.load(spec.name)
        if v ~= nil then
            M.set(spec, v, false)
        end
    end
end

return M
