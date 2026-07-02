-- lvim-utils.settings: the runtime-configurable UI geometry — the shared `config.ui.size`, per layout a size
-- fraction (height, + width for float) PLUS an `auto` boolean (fit content up to the size vs a fixed size).
--
-- ONE spec list drives BOTH lvim-utils' own config panel (`config_ui`) AND lvim-control-center (the setting
-- `name`s match control-center's, so the two panels edit the same persisted keys and never drift). Values are
-- applied LIVE into `config.ui.size` and persisted via `store` (control-center sqlite when present, else a JSON
-- file — see store.lua). Size fractions are `select` specs stored as OPTION STRINGS ("0.8"), converted to/from
-- numbers by `decode`/`encode`; the `auto` toggles are `bool` specs that round-trip as booleans. `restore()`
-- migrates the pre-boolean model (a height persisted as "auto" → that layout's `auto` on + a default height).
--
---@module "lvim-utils.settings"

local store = require("lvim-utils.store")

local M = {}

-- The discrete size fractions, ASCENDING (strings): the form engine cycles <CR> FORWARD / <BS> backward, so
-- ascending means <CR> INCREASES the size. No "auto" here — the fit toggle is a SEPARATE per-layout boolean
-- (`<layout> auto`), and the height/width is always a concrete fraction (used as the fixed size, or the cap
-- when auto is on).
local SIZE_OPTIONS = { "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.9", "1.0" }

--- Option string → the numeric fraction the config holds ("0.8" → 0.8). Booleans (the `auto` rows) round-trip
--- as-is via the `bool` specs, which skip encode/decode.
---@param v any
---@return any
local function decode(v)
    return tonumber(v) or v
end

--- Numeric fraction → the option string the panel / store use (0.8 → "0.8").
---@param v any
---@return any
local function encode(v)
    if v == nil then
        return v
    end
    return type(v) == "number" and ("%.2f"):format(v):gsub("0$", ""):gsub("%.$", "") or tostring(v)
end

---@class LvimUtilsSpec
---@field name    string     persistence key (matches the control-center setting name)
---@field path    string[]   nested location under `config.ui.size`
---@field group   string     panel tab / control-center group
---@field label   string     display label
---@field type    string     "select" (a size fraction) | "bool" (an auto toggle)
---@field options? string[]  choices (select only)
---@field default any        fallback config value when nothing is persisted

-- Auto (fit vs fixed) is PER AXIS. Only `float` has a width, so only it gets a `width_auto` toggle — `area`
-- and `bottom` are full-width docks with a height only. Each `*_auto` boolean precedes its fraction so a layout
-- reads top-down "fit this axis? then how big".
---@type LvimUtilsSpec[]
M.specs = {
    {
        name = "ui_size_float_height_auto",
        path = { "float", "height_auto" },
        group = "Size",
        label = "Float height auto (fit)",
        type = "bool",
        default = false,
    },
    {
        name = "ui_size_float_height",
        path = { "float", "height" },
        group = "Size",
        label = "Float height",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.85,
    },
    {
        name = "ui_size_float_width_auto",
        path = { "float", "width_auto" },
        group = "Size",
        label = "Float width auto (fit)",
        type = "bool",
        default = false,
    },
    {
        name = "ui_size_float_width",
        path = { "float", "width" },
        group = "Size",
        label = "Float width",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.8,
    },
    {
        name = "ui_size_area_height_auto",
        path = { "area", "height_auto" },
        group = "Size",
        label = "Area height auto (fit)",
        type = "bool",
        default = false,
    },
    {
        name = "ui_size_area_height",
        path = { "area", "height" },
        group = "Size",
        label = "Area height",
        type = "select",
        options = SIZE_OPTIONS,
        default = 0.5,
    },
    {
        name = "ui_size_bottom_height_auto",
        path = { "bottom", "height_auto" },
        group = "Size",
        label = "Bottom height auto (fit)",
        type = "bool",
        default = false,
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
    -- Per-layout dock BEHAVIOUR: whether opening a file closes the surface (auto_hide), and — for the docks that
    -- stay — where focus lands afterwards (keep_focus). float has no keep_focus (it always hides).
    {
        name = "ui_size_float_auto_hide",
        path = { "float", "auto_hide" },
        group = "Size",
        label = "Float auto hide on open",
        type = "bool",
        default = true,
    },
    {
        name = "ui_size_area_auto_hide",
        path = { "area", "auto_hide" },
        group = "Size",
        label = "Area auto hide on open",
        type = "bool",
        default = false,
    },
    {
        name = "ui_size_area_keep_focus",
        path = { "area", "keep_focus" },
        group = "Size",
        label = "Area keep focus after open",
        type = "bool",
        default = true,
    },
    {
        name = "ui_size_bottom_auto_hide",
        path = { "bottom", "auto_hide" },
        group = "Size",
        label = "Bottom auto hide on open",
        type = "bool",
        default = false,
    },
    {
        name = "ui_size_bottom_keep_focus",
        path = { "bottom", "keep_focus" },
        group = "Size",
        label = "Bottom keep focus after open",
        type = "bool",
        default = true,
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
    if spec.path[1] == "area" then
        pcall(function()
            local ma = require("lvim-utils.msgarea")
            if ma.refresh then
                ma.refresh()
            end
        end)
    end
end

--- The current value of `spec` for the panel / control-center: a BOOLEAN for `bool` specs, else the size
--- fraction as an OPTION STRING (to match a select choice).
---@param spec LvimUtilsSpec
---@return any
function M.get(spec)
    local v = read_path(size_tbl(), spec.path)
    if v == nil then
        v = spec.default
    end
    if spec.type == "bool" then
        return v == true
    end
    return encode(v)
end

--- Apply a new value LIVE into `config.ui.size` and persist it. `value` is a boolean for `bool` specs (accepts
--- `true`/`"true"`/`1`), else a size option string.
---@param spec LvimUtilsSpec
---@param value any
---@param persist? boolean  default true; false while restoring FROM the store
function M.set(spec, value, persist)
    local resolved
    if spec.type == "bool" then
        resolved = value == true or value == "true" or value == 1
    else
        resolved = decode(value)
    end
    write_path(size_tbl(), spec.path, resolved)
    if persist ~= false then
        store.save(spec.name, resolved)
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
            default = (spec.type == "bool") and spec.default or encode(spec.default),
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
    -- Migrate older models onto the current per-AXIS booleans:
    --  1. A size persisted as the string "auto" (the original model) → turn that AXIS's `*_auto` ON and reset the
    --     fraction to its default. The dropped `ui_size_auto_max` key is simply never loaded (no spec).
    --  2. A per-LAYOUT `ui_size_<layout>_auto` (the interim single-boolean model) → the layout's height axis (and,
    --     for float, width) `*_auto`.
    for _, spec in ipairs(M.specs) do
        if spec.type == "select" and store.load(spec.name) == "auto" then
            store.save("ui_size_" .. spec.path[1] .. "_" .. spec.path[2] .. "_auto", true)
            store.save(spec.name, encode(spec.default))
        end
    end
    for _, layout in ipairs({ "float", "area", "bottom" }) do
        local legacy = store.load("ui_size_" .. layout .. "_auto")
        if legacy ~= nil then
            local on = legacy == true or legacy == "true" or legacy == 1
            store.save("ui_size_" .. layout .. "_height_auto", on)
            if layout == "float" then
                store.save("ui_size_float_width_auto", on)
            end
        end
    end
    for _, spec in ipairs(M.specs) do
        local v = store.load(spec.name)
        if v ~= nil then
            M.set(spec, v, false)
        end
    end
end

return M
