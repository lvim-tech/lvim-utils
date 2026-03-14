-- lua/lvim-utils/ui/info.lua
-- Read-only informational floating window.
local config = require("lvim-utils.config")
local util   = require("lvim-utils.ui.util")

local api = vim.api
local M   = {}

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Resolve a dimension value for the info window.
---   "auto"      → min(content_size + 4, 90% of max_val)
---   0 < v <= 1  → fraction of max_val
---   integer     → used as-is
---@param val          string|number
---@param max_val      integer
---@param content_size integer
---@return integer
local function resolve_dim(val, max_val, content_size)
	if val == "auto" then
		return math.min(content_size + 4, math.floor(max_val * 0.9))
	elseif type(val) == "number" and val > 0 and val <= 1 then
		return math.floor(val * max_val)
	else
		return math.floor(tonumber(val) or content_size)
	end
end

--- Make a buffer read-only and block all editing keys.
---@param buf integer
local function make_readonly(buf)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly   = true
	vim.bo[buf].modified   = false
	vim.bo[buf].buftype    = "nofile"
	local ko = { buffer = buf, silent = true, nowait = true }
	for _, k in ipairs({
		"a", "i", "o", "A", "I", "O",
		"c", "C", "d", "D", "s", "S",
		"r", "R", "x", "X", "p", "P", "<Del>",
	}) do
		vim.keymap.set("n", k, "<Nop>", ko)
	end
	for _, k in ipairs({ "d", "c", "x", "p" }) do
		vim.keymap.set("v", k, "<Nop>", ko)
	end
end

--- Install a CursorMoved autocmd that clamps the cursor to column 0.
---@param buf integer
---@param win integer
local function setup_horizontal_lock(buf, win)
	local aug = api.nvim_create_augroup("LvimInfoHLock_" .. buf, { clear = true })
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group    = aug,
		buffer   = buf,
		callback = function()
			if not api.nvim_win_is_valid(win) then return end
			local pos = api.nvim_win_get_cursor(win)
			if pos[2] > 0 then
				api.nvim_win_set_cursor(win, { pos[1], 0 })
			end
		end,
	})
end

-- ─── public API ───────────────────────────────────────────────────────────────

--- Open a read-only informational floating window.
---@param content string|string[]
---@param opts? { title?: string, width?: number|string, height?: number|string, max_height?: number, border?: string, close_keys?: string[], filetype?: string }
---@return integer buf, integer win
function M.info(content, opts)
	local c             = vim.tbl_deep_extend("force", config.ui, opts or {})
	local content_lines = type(content) == "string"
		and vim.split(content, "\n")
		or  vim.list_extend({}, content)

	local max_w = c.title and util.dw(c.title) or 0
	for _, l in ipairs(content_lines) do
		max_w = math.max(max_w, util.dw(l))
	end

	local width = resolve_dim(c.width, vim.o.columns, max_w)

	local lines = {}
	local title_row, sep_row
	if c.title then
		title_row = 0
		table.insert(lines, util.center(c.title, width))
		table.insert(lines, "")
		sep_row = #lines
		table.insert(lines, string.rep("─", width))
		table.insert(lines, "")
	end
	vim.list_extend(lines, content_lines)

	local height = resolve_dim(c.height, vim.o.lines, #lines)
	height = math.min(height, math.floor(vim.o.lines * c.max_height))

	local _row, _col = util.calc_pos(height, width, c.position)

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile  = false
	vim.bo[buf].filetype  = c.filetype

	api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width    = width,
		height   = height,
		row      = _row,
		col      = _col,
		style    = "minimal",
		border   = util.resolve_border(c.border),
	})

	api.nvim_set_option_value("scrolloff",     0,      { win = win })
	api.nvim_set_option_value("wrap",          false,  { win = win })
	api.nvim_set_option_value("cursorline",    false,  { win = win })
	api.nvim_set_option_value("concealcursor", "nvic", { win = win })
	api.nvim_set_option_value("conceallevel",  2,      { win = win })
	api.nvim_set_option_value(
		"winhighlight",
		"NormalFloat:LvimUiNormal,FloatBorder:LvimUiBorder,CursorLine:LvimUiNormal",
		{ win = win }
	)

	if title_row then
		util.hl_line(buf, title_row, "LvimUiTitle")
		util.hl_line(buf, sep_row,   "LvimUiSeparator")
	end

	make_readonly(buf)
	setup_horizontal_lock(buf, win)

	local ko = { buffer = buf, silent = true, nowait = true }
	for _, k in ipairs(c.close_keys) do
		vim.keymap.set("n", k, function() M.close_info(win) end, ko)
	end
	for _, map in ipairs({ { "l", "<Nop>" }, { "<Right>", "<Nop>" }, { "$", "<Nop>" }, { "^", "0" } }) do
		vim.keymap.set("n", map[1], map[2], ko)
	end

	pcall(api.nvim_win_set_cursor, win, { title_row and 5 or 1, 0 })

	if c.markview then
		local ok, markview = pcall(require, "markview")
		if ok and markview and markview.render then
			vim.bo[buf].filetype = "markdown"
			pcall(markview.render, buf)
		end
	end

	return buf, win
end

--- Close an info window.
---@param win integer
function M.close_info(win)
	if win and api.nvim_win_is_valid(win) then
		local buf = api.nvim_win_get_buf(win)
		pcall(api.nvim_del_augroup_by_name, "LvimInfoHLock_" .. buf)
		api.nvim_win_close(win, true)
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
	end
end

return M
