-- lua/lvim-utils/ui/util.lua
-- Shared utilities for lvim-utils UI components.
local config = require("lvim-utils.config")
local api    = vim.api

local M = {}

M.NS = api.nvim_create_namespace("lvim_utils_ui_ns")
M.FT = "lvim-utils-ui"

-- ─── resolve_hl ───────────────────────────────────────────────────────────────

--- Accept either a highlight group name (string) or an inline hl definition (table).
--- Tables are registered as dynamic groups and their name is cached.
local _hl_cache = {}
function M.resolve_hl(val)
	if type(val) == "string" then return val end
	if type(val) ~= "table" then return nil end
	local key = vim.inspect(val)
	if not _hl_cache[key] then
		local name = "LvimUiInline_" .. vim.tbl_count(_hl_cache)
		api.nvim_set_hl(0, name, val)
		_hl_cache[key] = name
	end
	return _hl_cache[key]
end

-- ─── config accessor ──────────────────────────────────────────────────────────

--- Convenience accessor for the live UI config table.
---@return table
function M.cfg()
	return config.ui
end

-- ─── string / display helpers ─────────────────────────────────────────────────

--- Return the display width of a value (handles multi-byte / wide characters).
---@param s any
---@return integer
function M.dw(s)
	return vim.fn.strdisplaywidth(tostring(s or ""))
end

--- Return s centered within width columns, padded with spaces on both sides.
---@param s     any
---@param width integer
---@return string
function M.center(s, width)
	s = tostring(s or "")
	local len = M.dw(s)
	if len >= width then return s end
	local l = math.floor((width - len) / 2)
	return string.rep(" ", l) .. s .. string.rep(" ", width - len - l)
end

--- Return s left-padded with indent spaces and right-padded to fill width.
---@param s      any
---@param width  integer
---@param indent integer  Number of leading spaces (default 2)
---@return string
function M.lpad(s, width, indent)
	s = string.rep(" ", indent or 2) .. tostring(s or "")
	local len = M.dw(s)
	return len >= width and s or (s .. string.rep(" ", width - len))
end

-- ─── highlight helpers ────────────────────────────────────────────────────────

--- Apply a full-line highlight group to a buffer row via an extmark.
---@param buf   integer
---@param row   integer  0-based line number
---@param group string|nil  Highlight group name; no-op when nil
function M.hl_line(buf, row, group)
	if not group then return end
	api.nvim_buf_set_extmark(buf, M.NS, row, 0, { line_hl_group = group, priority = 200 })
end

-- ─── hl merge helper ──────────────────────────────────────────────────────────

--- Merge two hl defs, taking ONLY the bg field from overlay.
--- Used for per-item overrides (tab, button) where fg/bold come from the global level.
--- base can be a string (named group) or a table; overlay must be a table with a bg field.
---@param base    string|table|nil
---@param overlay string|table|nil
---@return string|table|nil
function M.merge_bg(base, overlay)
	if not overlay then return base end
	local new_bg = type(overlay) == "table" and overlay.bg or nil
	if not new_bg then return base end
	if type(base) == "string" then
		local attrs = api.nvim_get_hl(0, { name = base, link = false })
		attrs.bg = new_bg
		return attrs
	elseif type(base) == "table" then
		return vim.tbl_extend("force", base, { bg = new_bg })
	end
	return { bg = new_bg }
end

-- ─── border helpers ───────────────────────────────────────────────────────────

M.BORDERS = {
	rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
	single  = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
	double  = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
	none    = { "", "", "", "", "", "", "", "" },
}

--- Resolve a border spec to a concrete 8-element table.
--- Normalizes custom tables: corners between non-empty edges cannot be "".
---@param b string|table
---@return table
function M.resolve_border(b)
	if type(b) ~= "table" then return M.BORDERS[b] or M.BORDERS.rounded end
	local t = vim.list_extend({}, b)
	-- corners: {1=TL,3=TR,5=BR,7=BL}, adjacent edges: TL={8,2}, TR={2,4}, BR={4,6}, BL={6,8}
	local adj = { { 8, 2 }, { 2, 4 }, { 4, 6 }, { 6, 8 } }
	for i, edges in ipairs(adj) do
		if t[i * 2 - 1] == "" and (t[edges[1]] ~= "" and t[edges[2]] ~= "") then
			t[i * 2 - 1] = " "
		end
	end
	return t
end

-- ─── position helper ──────────────────────────────────────────────────────────

--- Compute the (row, col) for nvim_open_win (both 0-based, relative = "editor").
--- "editor" → centered in the full Neovim editor area.
--- "win"    → centered within the current window.
--- "cursor" → below the cursor when space allows, otherwise above.
---@param height   integer
---@param width    integer
---@param position "editor"|"win"|"cursor"|nil
---@return integer row, integer col
function M.calc_pos(height, width, position)
	if position == "cursor" then
		local sr    = vim.fn.screenrow() - 1
		local sc    = vim.fn.screencol() - 1
		local lines = vim.o.lines
		local cols  = vim.o.columns
		local row
		if sr + 2 + height <= lines then
			row = sr + 1
		else
			row = math.max(0, sr - height - 1)
		end
		local col = math.min(sc, math.max(0, cols - width - 2))
		return row, col
	end
	if position == "win" then
		local src_win = vim.api.nvim_get_current_win()
		local wpos    = vim.api.nvim_win_get_position(src_win)
		local wh      = vim.api.nvim_win_get_height(src_win)
		local ww      = vim.api.nvim_win_get_width(src_win)
		local row = wpos[1] + math.max(0, math.floor((wh - height) / 2))
		local col = wpos[2] + math.max(0, math.floor((ww - width)  / 2))
		return row, col
	end
	-- "editor": full editor area (default)
	return
		math.floor((vim.o.lines   - height) / 2),
		math.floor((vim.o.columns - width)  / 2)
end

return M
