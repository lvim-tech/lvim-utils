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
-- `width` is 1 for devicons/mini and for lvim-icons font mode, 2 for an lvim-icons svg-mode IMAGE —
-- consumers ALWAYS pad columns from it. An image (`image = true`) is two kitty placeholder cells whose
-- highlight foreground IS the terminal image id: paint it only through `hl` (or `on_bg` below), never with
-- a colour of your own — and pass `font = true` to get a font glyph where you must colour the icon yourself.
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
---@field glyph string   The glyph to render (a Nerd Font char, or two placeholder cells of an lvim-icons image)
---@field hl    string   Highlight group to paint it with ("" when the backend gives none)
---@field color string?  Resolved hex colour (for manual painting: fzf ANSI, statusline chunks)
---@field width integer  Display-cell width of `glyph` (1 for devicons/mini/font, 2 for an image)
---@field name  string   The backend's icon id / key
---@field image boolean? true when `glyph` is an lvim-icons terminal image (paint it only through `hl`)
---@field placement? "real"|"virtual"  how a buffer view puts it on a line (lvim-icons `placement`; nil = real)

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

-- ── UI icons ────────────────────────────────────────────────────────────────

--- A UI icon (not a file / folder) — a plugin passes its own Nerd `glyph` and colour group `hl`. With
--- lvim-icons in "material" mode it becomes an IMAGE of that glyph filled with that group's colour; in every
--- other case it is the glyph and group as given. Paint it like any icon result (`hl`, `text` / `mark`,
--- `on_bg` on a bar).
---@param opts { glyph: string, hl?: string, color?: string }
---@return LvimUtilsIconResult
function M.ui(opts)
    opts = opts or {}
    local m = provider_mod("lvim")
    if m and m.ui then
        return m.ui(opts)
    end
    local glyph = opts.glyph or ""
    return {
        glyph = glyph,
        hl = opts.hl or "",
        color = opts.color,
        width = glyph ~= "" and vim.fn.strdisplaywidth(glyph) or 0,
        name = "",
    }
end

--- A tree guide line as an IMAGE (lvim-icons, wherever the terminal shows images): two cells, a vertical line
--- at their middle — the centre of a 2-cell icon — over the full cell height, in the colour of `opts.hl`. nil
--- when there is no such image (another provider, no images): draw the text guide then.
--- `opts.under` = the icon it runs under (an icon result): the line goes under that icon's middle.
---@param opts { hl?: string, color?: string, under?: LvimUtilsIconResult|{ glyph: string } }
---@return LvimUtilsIconResult?
function M.guide(opts)
    local m = provider_mod("lvim")
    if m and m.guide then
        return m.guide(opts)
    end
    return nil
end

-- ── putting an icon on a buffer line ───────────────────────────────────────
-- lvim-icons decides per kind of icon (font glyph / image) whether a buffer view shows it as TEXT of the line
-- ("real") or as inline VIRTUAL text ("virtual": the cursor skips it, it is never yanked, searched or
-- edited). A consumer builds its line with `text(r)` — the icon and its separator, or nothing — and then
-- calls `mark(…)` at the column the icon belongs to, which draws a virtual icon or colours a real one.
-- Other providers (devicons / mini) have no `placement`: always real.

--- Whether `r` is drawn as inline virtual text in a buffer.
---@param r LvimUtilsIconResult?
---@return boolean
function M.is_virtual(r)
    return r ~= nil and r.placement == "virtual" and (r.glyph or "") ~= ""
end

--- The text a buffer line carries for icon `r`: the glyph and `sep` (default one space) when it is real, ""
--- when it is virtual (then `mark` draws both).
---@param r LvimUtilsIconResult?
---@param sep? string
---@return string
function M.text(r, sep)
    if not r or (r.glyph or "") == "" or M.is_virtual(r) then
        return ""
    end
    return r.glyph .. (sep or " ")
end

--- Draw / colour icon `r` at (`row`, `col`) of `buf` (0-based; `col` = the byte where `text(r)` was put).
--- Virtual: an inline extmark with the glyph and `sep`, kept LEFT of text typed at that column
--- (`right_gravity = false`: in insert mode the cursor stays after the icon) and combined with the line's
--- background (CursorLine shows under it). Real: the glyph's bytes are coloured with `r.hl`.
---@param buf integer
---@param ns integer
---@param row integer
---@param col integer
---@param r LvimUtilsIconResult?
---@param opts? { sep?: string, priority?: integer, hl?: string }  `hl` overrides `r.hl` for a FONT icon only
---@return integer? extmark id
function M.mark(buf, ns, row, col, r, opts)
    if not r or (r.glyph or "") == "" then
        return nil
    end
    opts = opts or {}
    local hl = (not r.image and opts.hl) or r.hl
    if hl == "" then
        hl = nil
    end
    if M.is_virtual(r) then
        return vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
            virt_text = { { r.glyph, hl }, { opts.sep or " " } },
            virt_text_pos = "inline",
            right_gravity = false,
            hl_mode = "combine",
            priority = opts.priority or 200,
        })
    end
    if not hl then
        return nil
    end
    return vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
        end_col = col + #r.glyph,
        hl_group = hl,
        priority = opts.priority or 200,
    })
end

---@type table<string, { base: string, bg: string|integer|nil }>  every on_bg group → what it is made of
local on_bg_groups = {}
---@type table<string, string>  derived group → the "<fg>|<bg>" it was last published into the veils with
local on_bg_published = {}
---@type boolean
local on_bg_hooked = false

--- The background a group SHOWS (its `bg`, or its `fg` when it is reversed), or nil.
---@param name string
---@return integer?
local function shown_bg(name)
    local d = vim.api.nvim_get_hl(0, { name = name, link = false })
    if d.reverse then
        return d.fg
    end
    return d.bg
end

--- (Re)define one on_bg group from what it is made of NOW: the image id of its base group, its background.
---@param group string
local function define_on_bg(group)
    local spec = on_bg_groups[group]
    local fg = vim.api.nvim_get_hl(0, { name = spec.base, link = false }).fg
    local bg = spec.bg
    if type(bg) == "string" and bg:sub(1, 1) ~= "#" then
        bg = shown_bg(bg) -- a group name: whatever it shows now
    end
    pcall(vim.api.nvim_set_hl, 0, group, { fg = fg, bg = bg })
    local stamp = tostring(fg) .. "|" .. tostring(bg)
    if on_bg_published[group] ~= stamp then
        on_bg_published[group] = stamp
        pcall(function()
            require("lvim-utils.dim").publish(group)
        end)
    end
end

--- The highlight group to paint an IMAGE icon with on a background of your own (a status bar, a winbar, a
--- band): the image id stays in the foreground and only the background is added. `bg` is best a GROUP NAME
--- (the bar's own group): the group is then named after it (`<hl>_on_<Group>`), so a cached bar keeps a
--- valid name across themes, and it is re-derived on every `:colorscheme` / palette change from what that
--- group shows then (a reversed group's fg). A "#rrggbb" / number pins a fixed colour instead. The name has
--- the icon's own prefix, so lvim-icons' data registration keeps a backdrop veil off it. Returns nil for a
--- font icon — colour that one as you always did.
---@param r LvimUtilsIconResult
---@param bg string|integer|nil  a highlight group name, a "#rrggbb", a number, or nil (none)
---@return string? group
function M.on_bg(r, bg)
    if not (r and r.image and r.hl and r.hl ~= "") then
        return nil
    end
    local key
    if bg == nil then
        key = "none"
    elseif type(bg) == "number" then
        key = ("%06x"):format(bg)
    elseif bg:sub(1, 1) == "#" then
        key = bg:sub(2)
    else
        key = bg:gsub("[^%w_]", "_")
    end
    local group = r.hl .. "_on_" .. key
    on_bg_groups[group] = { base = r.hl, bg = bg }
    define_on_bg(group)
    if not on_bg_hooked then
        on_bg_hooked = true
        local function redefine()
            for g in pairs(on_bg_groups) do
                define_on_bg(g)
            end
        end
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("LvimUtilsIconsOnBg", { clear = true }),
            callback = function()
                -- after the image groups themselves are re-asserted (their factories run on ColorScheme too)
                vim.schedule(redefine)
            end,
        })
        local ok, colors = pcall(require, "lvim-utils.colors")
        if ok and colors.on_change then
            colors.on_change(function()
                vim.schedule(redefine)
            end)
        end
    end
    return group
end

return M
