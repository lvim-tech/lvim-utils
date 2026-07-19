-- lvim-utils.icons: a provider-agnostic icon facade for the whole lvim-tech set.
-- Every plugin that shows a file/ft icon resolves it HERE, not against a specific icon
-- plugin, and passes the provider ITS OWN config chose. So a consumer (e.g. lvim-dashboard)
-- can be used with lvim-icons, nvim-web-devicons or mini.icons — or none — WITHOUT depending
-- on any particular one. The adapter logic lives here ONCE; consumers only forward a
-- `provider` string. lvim-utils is the shared base every lvim-tech plugin already loads, so
-- this seam is reachable everywhere without adding a dependency.
--
-- Unified result (every backend is adapted to this shape):
--   { glyph = "…", hl = "<group>", color = "#rrggbb"|nil, width = <cells>, name = "<id>" }
-- `width` is 1 for devicons/mini and for lvim-icons font mode, 2 for lvim-icons svg mode —
-- consumers ALWAYS pad columns from it.
--
-- provider values:
--   "lvim"     → lvim-icons          (palette theming, brand mode, svg mode)
--   "devicons" → nvim-web-devicons
--   "mini"     → mini.icons
--   "auto"     → the first of lvim → devicons → mini that is INSTALLED, else a built-in glyph
-- A requested-but-absent provider degrades through the same auto chain, then the built-in
-- fallback — so a resolve never errors and never returns nil.
--
---@module "lvim-utils.icons"

local M = {}

---@class LvimUtilsIconResult
---@field glyph string   The glyph to render (a Nerd Font char, or an svg ligature from lvim-icons)
---@field hl    string   Highlight group to paint it with ("" when the backend gives none)
---@field color string?  Resolved hex colour (for manual painting: fzf ANSI, statusline chunks)
---@field width integer  Display-cell width of `glyph` (1 for devicons/mini/font, 2 for svg)
---@field name  string   The backend's icon id / key

-- Built-in fallback glyphs when NO provider is installed (single-width Nerd Font).
---@type table<string, string>
local FALLBACK = { file = "", directory = "" }

-- provider name → module require path.
---@type table<string, string>
local MODULE = { lvim = "lvim-icons", devicons = "nvim-web-devicons", mini = "mini.icons" }

-- The auto-probe order: our provider first, then the common third-party ones.
---@type string[]
local AUTO_ORDER = { "lvim", "devicons", "mini" }

-- Cache of resolved provider modules. A present module is cached; a MISSING one is NOT
-- cached (nil), so a provider that loads lazily later is still picked up.
---@type table<string, table>
local mods = {}

--- The loaded module for a provider name, or nil when it is not installed.
---@param name string
---@return table?
local function provider_mod(name)
    if mods[name] then
        return mods[name]
    end
    local path = MODULE[name]
    if not path then
        return nil
    end
    local ok, m = pcall(require, path)
    if ok and type(m) == "table" then
        mods[name] = m
        return m
    end
    return nil
end

--- Resolve a requested provider to a concrete (name, module). "auto" (or an absent requested
--- provider) walks AUTO_ORDER; "fallback" with nil module means no provider is installed.
---@param requested string?
---@return string name, table? module
local function pick(requested)
    requested = requested or "auto"
    if requested ~= "auto" then
        local m = provider_mod(requested)
        if m then
            return requested, m
        end
    end
    for _, name in ipairs(AUTO_ORDER) do
        local m = provider_mod(name)
        if m then
            return name, m
        end
    end
    return "fallback", nil
end

--- The hex of a highlight group's foreground, or nil (mini/devicons return a group name).
---@param group string?
---@return string?
local function hl_hex(group)
    if not group or group == "" then
        return nil
    end
    local h = vim.api.nvim_get_hl(0, { name = group, link = false })
    return (h and h.fg) and ("#%06x"):format(h.fg) or nil
end

-- ── per-provider adapters (backend return → unified result) ─────────────────

---@param m table
---@param name string
---@param opts table
---@return LvimUtilsIconResult
local function from_lvim(m, name, opts)
    -- lvim-icons already returns the unified shape (with width + color).
    return m.get(name, opts)
end

---@param m table
---@param name string
---@return LvimUtilsIconResult
local function from_devicons(m, name)
    local base = vim.fn.fnamemodify(name, ":t")
    local ext = vim.fn.fnamemodify(base, ":e")
    local glyph, color = m.get_icon_color(base, ext, { default = true })
    local _, group = m.get_icon(base, ext, { default = true })
    return { glyph = glyph or "", hl = group or "", color = color, width = 1, name = base }
end

---@param m table
---@param name string
---@param opts table
---@return LvimUtilsIconResult
local function from_mini(m, name, opts)
    -- mini.icons keys by category. Map our request to the closest one.
    local category, key
    if opts.kind and opts.kind:find("directory") then
        category = "directory"
        key = (name ~= "" and vim.fn.fnamemodify(name, ":t")) or "dir"
    elseif opts.filetype and (name == nil or name == "") then
        category = "filetype"
        key = opts.filetype
    else
        category = "file"
        key = vim.fn.fnamemodify(name, ":t")
    end
    local glyph, group = m.get(category, key)
    return { glyph = glyph or "", hl = group or "", color = hl_hex(group), width = 1, name = key }
end

--- Resolve an icon for `name` using the requested provider (falling back per the module
--- header). Never errors, never returns nil.
---@param name string   a path or bare filename
---@param opts { provider?: string, filetype?: string, kind?: string, color_mode?: string }?  `color_mode` ("theme"|"brand"|"theme_brand") is honoured ONLY by the lvim-icons provider (devicons/mini carry their own colours); it is forwarded verbatim.
---@return LvimUtilsIconResult
function M.get(name, opts)
    opts = opts or {}
    local prov, m = pick(opts.provider)
    if prov == "lvim" and m then
        return from_lvim(m, name, opts)
    elseif prov == "devicons" and m then
        return from_devicons(m, name)
    elseif prov == "mini" and m then
        return from_mini(m, name, opts)
    end
    -- No provider installed → a single built-in glyph so consumers still render something.
    local glyph = (opts.kind and opts.kind:find("directory")) and FALLBACK.directory or FALLBACK.file
    return { glyph = glyph, hl = "", color = nil, width = 1, name = "default" }
end

--- A KEY→{icon,color,hl,name} map over the provider's whole table — for consumers building a
--- static lookup (e.g. the fzf awk icon map). Empty when the provider offers no enumeration
--- (the caller then falls back to per-item M.get or no icons).
---@param opts { provider?: string, color_mode?: string }?
---@return table<string, { icon: string, color: string?, hl: string?, name: string }>
function M.get_icons(opts)
    opts = opts or {}
    local prov, m = pick(opts.provider)
    local out = {}
    if prov == "lvim" and m then
        return m.get_icons({ color_mode = opts.color_mode })
    elseif prov == "devicons" and m then
        for k, def in pairs(m.get_icons() or {}) do
            if def.icon then
                out[k] = { icon = def.icon, color = def.color, hl = nil, name = def.name or k }
            end
        end
    elseif prov == "mini" and m and type(m.list) == "function" then
        for _, category in ipairs({ "extension", "file" }) do
            for _, key in ipairs(m.list(category) or {}) do
                local glyph, group = m.get(category, key)
                if glyph and glyph ~= "" then
                    out[key] = { icon = glyph, color = hl_hex(group), hl = group, name = key }
                end
            end
        end
    end
    return out
end

--- The concrete provider name that WOULD be used for a request ("lvim"/"devicons"/"mini"/
--- "fallback"). For health reporting and consumers that want to know.
---@param requested string?
---@return string
function M.active(requested)
    return (pick(requested))
end

--- Bind a provider (and optionally a colour mode) once and return a small resolver — for hot
--- paths (a picker over thousands of rows) that would otherwise pass them on every call. A
--- per-call `opts.color_mode` still overrides the bound one.
---@param provider string?
---@param color_mode string?  default colour mode for lvim-icons ("theme"|"brand"|"theme_brand")
---@return { get: fun(name: string, opts?: table): LvimUtilsIconResult, get_icons: fun(): table }
function M.bind(provider, color_mode)
    return {
        get = function(name, opts)
            opts = opts or {}
            opts.provider = provider
            if opts.color_mode == nil then
                opts.color_mode = color_mode
            end
            return M.get(name, opts)
        end,
        get_icons = function()
            return M.get_icons({ provider = provider, color_mode = color_mode })
        end,
    }
end

return M
