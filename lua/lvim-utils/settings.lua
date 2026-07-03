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

-- Backdrop winblend choices (integers, ASCENDING) in STEPS of 5: 0 = fully opaque veil (strongest darken),
-- 100 = invisible. <CR> raises the value (more see-through / softer dim).
local BLEND_OPTIONS = {}
for i = 0, 20 do
    BLEND_OPTIONS[i + 1] = tostring(i * 5)
end

--- Option string → the numeric fraction the config holds ("0.8" → 0.8). Booleans (the `auto` rows) round-trip
--- as-is via the `bool` specs, which skip encode/decode.
---@param v any
---@return any
local function decode(v)
    return tonumber(v) or v
end

--- Numeric value → the option string the panel / store use. A number has two candidate forms — trimmed FRACTION
--- ("0.8", "1.0") and bare INTEGER ("55", "1") — which collide at whole numbers (a size `1.0` vs a blend `1`).
--- When `options` is given, return whichever candidate IS a real option (so a select always round-trips); with no
--- options, integers print bare and fractions trimmed.
---@param v any
---@param options? string[]  the spec's select choices, to disambiguate the format
---@return any
local function encode(v, options)
    if v == nil then
        return v
    end
    if type(v) ~= "number" then
        return tostring(v)
    end
    local frac = (("%.2f"):format(v):gsub("0$", ""):gsub("%.$", "")) -- "0.85", "1.0", "55.0"
    local int = (v == math.floor(v)) and tostring(math.floor(v)) or nil -- "1", "55" (nil for non-integers)
    if options then
        for _, o in ipairs(options) do
            if o == int or o == frac then
                return o
            end
        end
    end
    return int or frac
end

---@class LvimUtilsSpec
---@field name    string     persistence key (matches the control-center setting name)
---@field path    string[]   nested location under `config.ui[root]`
---@field root?   string     which `config.ui` sub-table the path is in: "size" (default) | "backdrop"
---@field group   string     panel tab / control-center group
---@field label   string     display label
---@field type    string     "select" (a size fraction / blend) | "bool" (a toggle)
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
    -- Backdrop dim/darken veil PER LAYOUT (`config.ui.backdrop`) — a toggle + a winblend for each. The `hl` colour
    -- stays config-only (a highlight-group name isn't a panel choice).
    {
        name = "ui_backdrop_float_enabled",
        path = { "float", "enabled" },
        root = "backdrop",
        group = "Backdrop",
        label = "Float backdrop",
        type = "bool",
        default = true,
    },
    {
        name = "ui_backdrop_float_blend",
        path = { "float", "blend" },
        root = "backdrop",
        group = "Backdrop",
        label = "Float backdrop blend",
        type = "select",
        options = BLEND_OPTIONS,
        default = 65,
    },
    {
        name = "ui_backdrop_area_enabled",
        path = { "area", "enabled" },
        root = "backdrop",
        group = "Backdrop",
        label = "Area backdrop",
        type = "bool",
        default = true,
    },
    {
        name = "ui_backdrop_area_blend",
        path = { "area", "blend" },
        root = "backdrop",
        group = "Backdrop",
        label = "Area backdrop blend",
        type = "select",
        options = BLEND_OPTIONS,
        default = 65,
    },
    {
        name = "ui_backdrop_bottom_enabled",
        path = { "bottom", "enabled" },
        root = "backdrop",
        group = "Backdrop",
        label = "Bottom backdrop",
        type = "bool",
        default = true,
    },
    {
        name = "ui_backdrop_bottom_blend",
        path = { "bottom", "blend" },
        root = "backdrop",
        group = "Backdrop",
        label = "Bottom backdrop blend",
        type = "select",
        options = BLEND_OPTIONS,
        default = 65,
    },
}

--- The live `config.ui[root]` table (created if missing) — a spec's `root` ("size" default, or "backdrop").
---@param root? string
---@return table
local function root_tbl(root)
    root = root or "size"
    local ui = require("lvim-utils.config").ui
    ui[root] = ui[root] or {}
    return ui[root]
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
    if (spec.root or "size") == "size" and spec.path[1] == "area" then
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
    local v = read_path(root_tbl(spec.root), spec.path)
    if v == nil then
        v = spec.default
    end
    if spec.type == "bool" then
        return v == true
    end
    return encode(v, spec.options)
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
    write_path(root_tbl(spec.root), spec.path, resolved)
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
            -- The default the control-center applies when NOTHING is persisted MUST be the LIVE config value (which
            -- `M.get` reads from `config.ui[root]`), NOT a hardcoded `spec.default`: config.lua is the source of
            -- truth, so a user editing e.g. `config.ui.backdrop.float.blend` must win. A stale literal here would
            -- let control-center overwrite the edited config with the old default on load (they can diverge).
            default = M.get(spec),
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
            store.save(spec.name, encode(spec.default, spec.options))
        end
    end
    for _, layout in ipairs({ "float", "area", "bottom" }) do
        local legacy = store.load("ui_size_" .. layout .. "_auto")
        if legacy ~= nil then
            local on = legacy == true or legacy == "true" or legacy == 1
            -- Migrate ONCE, and ONLY onto an axis with no explicit per-axis value yet — never clobber a choice the
            -- user has since made in the panel. Then DROP the legacy key so it can't re-seed on EVERY start: that
            -- was the bug that made unchecking a `*_auto` toggle revert to checked after a restart.
            if store.load("ui_size_" .. layout .. "_height_auto") == nil then
                store.save("ui_size_" .. layout .. "_height_auto", on)
            end
            if layout == "float" and store.load("ui_size_float_width_auto") == nil then
                store.save("ui_size_float_width_auto", on)
            end
            store.clear("ui_size_" .. layout .. "_auto")
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
