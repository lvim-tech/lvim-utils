-- lua/lvim-utils/highlight/init.lua
-- Dynamic highlight group registration that survives colorscheme changes,
-- plus color manipulation helpers (blend, lighten, darken) and group utilities.
--
-- Public API:
--   M.bind(fn)                       – self-theme: apply a palette-derived factory with
--                                      `default = true`, re-applied on palette/ColorScheme
--                                      change (the canonical self-theming entry point)
--   M.register(groups, force?)       – register and immediately apply fixed highlight groups
--   M.setup()                        – install the ColorScheme autocmd (call once)
--   M.blend(fg, bg, alpha)           – blend two hex colors
--   M.lighten(color, amount)         – lighten a color toward white
--   M.darken(color, amount)          – darken a color toward black
--   M.define(name, opts)             – set a highlight group (always applied)
--   M.define_if_missing(name, opts)  – set a highlight group only if it doesn't exist
--   M.clear(name)                    – clear a highlight group
--   M.get(name)                      – get highlight group attributes
--   M.link(name, link_to)            – link one group to another
--   M.group_exists(name)             – check if a group is defined

local M = {}

--- Internal registry: name → opts table for all registered groups.
---@type table<string, table>
local registry = {}

--- Bound palette-derived factories (see M.bind). Each is re-run on ColorScheme and on
--- palette change; the groups it returns are applied with `default = true`.
---@type (fun(): table<string, table>)[]
local bound = {}

-- ─── color helpers ────────────────────────────────────────────────────────────

--- Convert a hex color string to RGB components.
---@param hex string  Color in "#RRGGBB" format
---@return number r, number g, number b  Values in 0-255 range
local function hex_to_rgb(hex)
	if not hex or hex == "" then
		return 0, 0, 0
	end
	hex = hex:gsub("^#", "")
	return tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
end

--- Convert RGB components to a hex color string.
---@param r number
---@param g number
---@param b number
---@return string  Color in "#rrggbb" format
local function rgb_to_hex(r, g, b)
	r = math.max(0, math.min(255, math.floor(r + 0.5)))
	g = math.max(0, math.min(255, math.floor(g + 0.5)))
	b = math.max(0, math.min(255, math.floor(b + 0.5)))
	return string.format("#%02x%02x%02x", r, g, b)
end

---Blend two hex colors together.
---@param fg     string  Foreground color in "#RRGGBB" format
---@param bg     string  Background color in "#RRGGBB" format
---@param alpha  number  Blend factor: 1.0 = fully fg, 0.0 = fully bg
---@return string  Blended color in hex format
function M.blend(fg, bg, alpha)
	if not fg or not bg then
		return fg or bg or "#000000"
	end
	local fr, fg_, fb = hex_to_rgb(fg)
	local br, bg_, bb = hex_to_rgb(bg)
	return rgb_to_hex(fr * alpha + br * (1 - alpha), fg_ * alpha + bg_ * (1 - alpha), fb * alpha + bb * (1 - alpha))
end

---Lighten a color by blending it toward white.
---@param color   string  Hex color to lighten
---@param amount  number  0.0 = unchanged, 1.0 = white
---@return string
function M.lighten(color, amount)
	return M.blend("#ffffff", color, amount)
end

---Darken a color by blending it toward black.
---@param color   string  Hex color to darken
---@param amount  number  0.0 = unchanged, 1.0 = black
---@return string
function M.darken(color, amount)
	return M.blend("#000000", color, amount)
end

-- ─── group utilities ──────────────────────────────────────────────────────────

---Check whether a highlight group is defined (non-empty).
---@param name string
---@return boolean
function M.group_exists(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and hl ~= nil and not vim.tbl_isempty(hl)
end

---Define or override a highlight group.
---@param name string
---@param opts table
function M.define(name, opts)
	vim.api.nvim_set_hl(0, name, opts)
end

---Define a highlight group only if it is not already set.
---@param name string
---@param opts table
---@return boolean  true if the group was defined, false if it already existed
function M.define_if_missing(name, opts)
	if not M.group_exists(name) then
		vim.api.nvim_set_hl(0, name, opts)
		return true
	end
	return false
end

---Clear a highlight group (reset to empty).
---@param name string
function M.clear(name)
	vim.api.nvim_set_hl(0, name, {})
end

---Get the attributes of a highlight group.
---@param name string
---@return table|nil  Attribute table, or nil if the group is not defined
function M.get(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok and hl and not vim.tbl_isempty(hl) then
		return hl
	end
	return nil
end

---Link one highlight group to another.
---@param name    string  Group to define
---@param link_to string  Target group to link to
function M.link(name, link_to)
	vim.api.nvim_set_hl(0, name, { link = link_to })
end

-- ─── registry / persistence ───────────────────────────────────────────────────

--- Apply one bound factory's groups.
--- `force = false` (the default) applies with `default = true` — the group is only filled
--- in if nothing else (a colorscheme or the user) already defines it, so it stays
--- overwritable. `force = true` applies for real (no `default`), which is required when the
--- palette actually changed (sync / live preview): a plain `default` re-apply would be a
--- no-op because the group already exists, so the new colors would never show.
---@param fn     fun(colors?: table): table<string, table>
---@param force? boolean
local function apply_bound(fn, force)
	-- Pass the live palette to the factory for ergonomics; factories that ignore the
	-- argument and require the palette themselves keep working.
	local ok_c, colors = pcall(require, "lvim-utils.colors")
	local ok, groups = pcall(fn, ok_c and colors or nil)
	if not ok or type(groups) ~= "table" then
		return
	end
	for name, opts in pairs(groups) do
		opts = vim.deepcopy(opts)
		opts.default = (not force) or nil
		vim.api.nvim_set_hl(0, name, opts)
	end
end

--- Re-apply all registered groups (force flag honoured) and every bound factory.
local function apply_all()
	for name, entry in pairs(registry) do
		if entry.force then
			vim.api.nvim_set_hl(0, name, entry.opts)
		else
			M.define_if_missing(name, entry.opts)
		end
	end
	for _, fn in ipairs(bound) do
		apply_bound(fn)
	end
end

---Register highlight groups and apply them immediately.
---Can be called multiple times from different modules.
---@param groups  table<string, table>  Map of group name → nvim_set_hl opts
---@param force?  boolean               Always apply, even if the group already exists
function M.register(groups, force)
	for name, opts in pairs(groups) do
		registry[name] = { opts = opts, force = force or false }
		if force then
			vim.api.nvim_set_hl(0, name, opts)
		else
			M.define_if_missing(name, opts)
		end
	end
end

---Bind a palette-derived highlight factory for self-theming. `fn` returns a map of
---group → opts computed from the live palette (read it inside `fn`). The groups are
---applied now with `default = true` (so the active colorscheme or the user can override
---them) and re-applied automatically whenever the palette syncs from lvim-colorscheme
---(`colors.on_change`) and on every `ColorScheme` (via |M.setup|'s autocmd). This is the
---one mechanism every lvim-tech plugin should use to theme its own UI from the shared
---palette while staying overwritable off-lvim.
---The factory receives the live palette as its first argument (it may also require it
---directly). Returns a dispose function that unbinds the factory (stops further re-applies);
---useful for isolated `ui.new()` instances or plugins that tear down.
---@param fn fun(colors?: table): table<string, table>
---@return fun()  dispose
function M.bind(fn)
	bound[#bound + 1] = fn
	-- initial: default (overwritable by a colorscheme/user that already themed the group)
	apply_bound(fn, false)
	-- palette sync / live preview: force, so the actually-changed colors take effect
	local disposed = false
	local ok, colors = pcall(require, "lvim-utils.colors")
	if ok and type(colors.on_change) == "function" then
		colors.on_change(function()
			if not disposed then
				apply_bound(fn, true)
			end
		end)
	end
	return function()
		disposed = true
		for i, f in ipairs(bound) do
			if f == fn then
				table.remove(bound, i)
				break
			end
		end
	end
end

---Install the ColorScheme autocmd so registered + bound groups survive theme changes.
---Call once during plugin initialisation.
function M.setup()
	local aug = vim.api.nvim_create_augroup("LvimUtilsHighlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = aug,
		callback = apply_all,
		desc = "Re-apply lvim-utils highlight groups after colorscheme change",
	})
end

return M
