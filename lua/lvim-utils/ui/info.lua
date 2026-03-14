-- lua/lvim-utils/ui/info.lua
-- Informational floating window (read-only by default, folds optional).
local config = require("lvim-utils.config")
local util   = require("lvim-utils.ui.util")

local api = vim.api
local M   = {}

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Resolve a dimension value for the info window.
---   "auto"      → min(content_size, 90% of max_val)
---   0 < v <= 1  → fraction of max_val
---   integer     → used as-is
---@param val          string|number
---@param max_val      integer
---@param content_size integer
---@return integer
local function resolve_dim(val, max_val, content_size)
	if val == "auto" then
		return math.min(content_size, math.floor(max_val * 0.9))
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

--- Create manual folds in the window for the given line ranges.
--- folds[].start_line and folds[].end_line are 0-based buffer line indices.
---@param buf   integer
---@param win   integer
---@param folds { start_line: integer, end_line: integer }[]
local function apply_folds(buf, win)
	api.nvim_set_option_value("foldmethod", "manual", { win = win })
	api.nvim_set_option_value("foldenable", true,     { win = win })
end

-- ─── public API ───────────────────────────────────────────────────────────────

--- Open an informational floating window.
---@param content string|string[]
---@param opts? { title?: string, width?: number|string, height?: number|string, max_height?: number, border?: string, close_keys?: string[], filetype?: string, position?: "editor"|"win"|"cursor", winhighlight?: string, zindex?: integer, readonly?: boolean, highlights?: { line: integer, col_start: integer, col_end: integer, group: string }[], folds?: { start_line: integer, end_line: integer }[], footer_hints?: { key: string, label: string }[] }
--- highlights[].line is 0-based relative to content (title rows are not counted).
--- col_end = -1 highlights to end of line.
--- folds[].start_line / end_line are 0-based buffer line indices (absolute, not content-relative).
--- readonly defaults to true; set to false to allow editing and skip the horizontal cursor lock.
--- footer_hints: list of {key, label} pairs rendered via lvim-utils.ui.footer (centered, LvimUiFooterKey/Label highlights).
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

	-- Footer: built via lvim-utils.ui.footer for consistent key/label highlights
	local footer_hint_ranges
	if c.footer_hints then
		local ok_f, footer_mod = pcall(require, "lvim-utils.ui.footer")
		if ok_f then
			local flines, franges = footer_mod.build({ hints = c.footer_hints, width = width })
			vim.list_extend(lines, flines)
			footer_hint_ranges = franges
		end
	end

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
		zindex   = c.zindex or nil,
	})

	api.nvim_set_option_value("scrolloff",     0,      { win = win })
	api.nvim_set_option_value("wrap",          false,  { win = win })
	api.nvim_set_option_value("cursorline",    false,  { win = win })
	api.nvim_set_option_value("concealcursor", "nvic", { win = win })
	api.nvim_set_option_value("conceallevel",  2,      { win = win })
	api.nvim_set_option_value("winblend",      0,      { win = win })
	api.nvim_set_option_value(
		"winhighlight",
		c.winhighlight or "Normal:LvimUiNormal,NormalFloat:LvimUiNormal,FloatBorder:LvimUiBorder,CursorLine:LvimUiNormal",
		{ win = win }
	)

	if title_row then
		local text_start = math.floor((width - util.dw(c.title)) / 2)
		pcall(api.nvim_buf_set_extmark, buf, util.NS, title_row,
			math.max(0, text_start - 1), {
				end_col  = math.min(width, text_start + #c.title + 1),
				hl_group = "LvimUiTitle",
				priority = 200,
			})
		util.hl_line(buf, sep_row, "LvimUiSeparator")
	end

	if c.highlights then
		local content_offset = title_row and 4 or 0
		for _, hl in ipairs(c.highlights) do
			local buf_line  = hl.line + content_offset
			local line_text = lines[buf_line + 1] or ""
			local col_end   = (hl.col_end == nil or hl.col_end == -1)
				and #line_text
				or  hl.col_end
			pcall(api.nvim_buf_set_extmark, buf, util.NS, buf_line, hl.col_start or 0, {
				end_row  = buf_line,
				end_col  = col_end,
				hl_group = hl.group,
				priority = 210,
			})
		end
	end

	if footer_hint_ranges then
		require("lvim-utils.ui.footer").apply_hl(buf, #lines, footer_hint_ranges)
	end

	if c.folds and #c.folds > 0 then
		apply_folds(buf, win)
		local sorted_folds = vim.tbl_filter(
			function(f) return f.start_line and f.end_line end,
			c.folds
		)
		table.sort(sorted_folds, function(a, b)
			return (a.end_line - a.start_line) < (b.end_line - b.start_line)
		end)
		for _, fold in ipairs(sorted_folds) do
			pcall(api.nvim_win_call, win, function()
				vim.cmd(string.format([[%d,%dfold]], fold.start_line + 1, fold.end_line + 1))
			end)
		end
	end

	local is_readonly = c.readonly ~= false
	if is_readonly then
		make_readonly(buf)
		setup_horizontal_lock(buf, win)
	else
		local ok_cur, cursor_mod = pcall(require, "lvim-utils.cursor")
		if ok_cur then cursor_mod.mark_input_buffer(buf, true) end
	end

	local ko = { buffer = buf, silent = true, nowait = true }
	for _, k in ipairs(c.close_keys) do
		vim.keymap.set("n", k, function() M.close_info(win) end, ko)
	end
	if is_readonly then
		for _, map in ipairs({ { "l", "<Nop>" }, { "<Right>", "<Nop>" }, { "$", "<Nop>" }, { "^", "0" } }) do
			vim.keymap.set("n", map[1], map[2], ko)
		end
	end

	pcall(api.nvim_win_set_cursor, win, { title_row and 5 or 1, 0 })

	if c.markview and not (c.highlights and #c.highlights > 0) then
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
