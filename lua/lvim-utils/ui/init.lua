-- lua/lvim-utils/ui/init.lua
-- Floating popup components for lvim-utils.
-- All popups share a single internal open() function driven by a mode flag.
--
-- Modes and their callback signatures:
--   select      → callback(confirmed: boolean, index: integer)
--   multiselect → callback(confirmed: boolean, selected: table<string, boolean>)
--   input       → callback(confirmed: boolean, value: string)
--   tabs        → callback(confirmed: boolean, result)
--                 result = { tab, index, item } for simple tabs
--                 result = table<name, value>   for typed-row tabs
--
-- Public API:
--   M.select(opts)      – pick one item from a list
--   M.multiselect(opts) – pick multiple items
--   M.input(opts)       – free-text input field
--   M.tabs(opts)        – tabbed view with typed rows or simple item lists
--   M.info(content, opts) – read-only markdown/text info window
--   M.close_info(win)   – programmatically close an info window

local hl = require("lvim-utils.highlight")
local config = require("lvim-utils.config")

local M = {}
local api = vim.api
local NS = api.nvim_create_namespace("lvim_utils_ui_ns")
local FT = "lvim-utils-ui"

hl.register({
	LvimUiTitle = { link = "Title" },
	LvimUiSubtitle = { link = "Comment" },
	LvimUiInfo = { link = "DiagnosticInfo" },
	LvimUiCursorLine = { link = "CursorLine" },
	LvimUiTabActive = { link = "TabLineSel" },
	LvimUiTabInactive = { link = "TabLine" },
	LvimUiButtonActive = { link = "TabLineSel" },
	LvimUiButtonInactive = { link = "TabLine" },
	LvimUiSeparator = { link = "WinSeparator" },
	LvimUiFooter = { link = "Comment" },
	LvimUiInput = { link = "CurSearch" },
	LvimUiSpacer = { link = "Comment" },
	LvimUiNormal = { link = "NormalFloat" },
	LvimUiBorder = { link = "FloatBorder" },
})

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Return the display width of a value (handles multi-byte / wide characters).
---@param s any
---@return integer
local function dw(s)
	return vim.fn.strdisplaywidth(tostring(s or ""))
end

--- Return s centered within width columns, padded with spaces on both sides.
---@param s     any
---@param width integer
---@return string
local function center(s, width)
	s = tostring(s or "")
	local len = dw(s)
	if len >= width then return s end
	local l = math.floor((width - len) / 2)
	return string.rep(" ", l) .. s .. string.rep(" ", width - len - l)
end

--- Return s left-padded with indent spaces and right-padded to fill width.
---@param s      any
---@param width  integer
---@param indent integer  Number of leading spaces (default 2)
---@return string
local function lpad(s, width, indent)
	s = string.rep(" ", indent or 2) .. tostring(s or "")
	local len = dw(s)
	return len >= width and s or (s .. string.rep(" ", width - len))
end

--- Apply a full-line highlight group to a buffer row via an extmark.
---@param buf   integer
---@param row   integer  0-based line number
---@param group string|nil  Highlight group name; no-op when nil
local function hl_line(buf, row, group)
	if not group then return end
	api.nvim_buf_set_extmark(buf, NS, row, 0, { line_hl_group = group, priority = 200 })
end

local BORDERS = {
	rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
	single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
	double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
	none = { "", "", "", "", "", "", "", "" },
}

--- Resolve a border spec to a concrete 8-element table.
--- Accepts a named key ("rounded", "single", "double", "none") or a raw table.
---@param b string|table
---@return table
local function resolve_border(b)
	if type(b) == "table" then return b end
	return BORDERS[b] or BORDERS.rounded
end

--- Convenience accessor for the live UI config table.
---@return table
local function cfg()
	return config.ui
end

-- ─── row type system ──────────────────────────────────────────────────────────

---@alias RowType "bool"|"boolean"|"select"|"int"|"integer"|"float"|"number"|"string"|"text"|"action"|"spacer"|"spacer_line"

---@class Row
---@field type     RowType
---@field name?    string
---@field label?   string
---@field value?   any
---@field default? any
---@field options? string[]          -- select: list of options
---@field run?     fun(value: any, close?: fun(confirmed: boolean, result: any))  -- action rows receive a close callback as second arg
---@field top?     boolean           -- spacer: blank line above
---@field bottom?  boolean           -- spacer: blank line below

---@class Tab
---@field label string
---@field rows? Row[]
---@field items? string[]            -- simple list (backward compat, treated as select items)

--- Convenience accessor for the configured icon set.
---@return table
local function icons()
	return cfg().icons
end

--- Return true when a row can receive keyboard focus (i.e. is not a spacer).
---@param row Row
---@return boolean
local function is_selectable(row)
	return row.type ~= "spacer" and row.type ~= "spacer_line"
end

--- Build the display string for a typed row.
---@param row Row
---@return string
local function row_display(row)
	local t = row.type or "string"
	local label = row.label or row.name or ""
	local val = tostring(row.value ~= nil and row.value or row.default or "")

	if t == "bool" or t == "boolean" then
		return (row.value and icons().bool_on or icons().bool_off) .. "  " .. label
	elseif t == "select" then
		return icons().select .. "  " .. label .. ": " .. val
	elseif t == "int" or t == "integer" or t == "float" or t == "number" then
		return icons().number .. "  " .. label .. ": " .. val
	elseif t == "string" or t == "text" then
		return icons().string .. "  " .. label .. ": " .. val
	elseif t == "action" then
		return icons().action .. "  " .. label
	elseif t == "spacer" then
		return icons().spacer .. " " .. label
	elseif t == "spacer_line" then
		return ""
	end
	return "   " .. label
end

--- Return the 1-based index of the first selectable row, or 1 as fallback.
---@param rows Row[]
---@return integer
local function first_selectable(rows)
	for i, r in ipairs(rows) do
		if is_selectable(r) then return i end
	end
	return 1
end

--- Return the next selectable row index in direction delta (+1 / -1),
--- or nil when the boundary is reached.
---@param rows  Row[]
---@param from  integer  Current 1-based index
---@param delta integer  +1 for down, -1 for up
---@return integer|nil
local function next_selectable(rows, from, delta)
	local i = from + delta
	while i >= 1 and i <= #rows do
		if is_selectable(rows[i]) then
			return i
		end
		i = i + delta
	end
	return nil
end

-- ─── position helper ──────────────────────────────────────────────────────────

--- Compute the (row, col) for nvim_open_win (both 0-based, relative = "editor").
--- "editor" → centered in the full Neovim editor area.
--- "win"    → centered within the current window.
--- "cursor" → below the cursor when space allows, otherwise above; column aligned
---            with the cursor and clamped to the screen.
---@param height   integer
---@param width    integer
---@param position "editor"|"win"|"cursor"|nil
---@return integer row, integer col
local function calc_pos(height, width, position)
	if position == "cursor" then
		local sr   = vim.fn.screenrow() - 1
		local sc   = vim.fn.screencol() - 1
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
		local wpos    = vim.api.nvim_win_get_position(src_win)  -- {row, col} 0-based screen
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

-- ─── core open ────────────────────────────────────────────────────────────────

---@alias UiMode "select"|"multiselect"|"input"|"tabs"

---@class UiOpts
---@field mode?             UiMode
---@field title?            string
---@field subtitle?         string
---@field info?             string
---@field items?            string[]
---@field tabs?             Tab[]
---@field placeholder?      string
---@field callback?         fun(confirmed: boolean, result: any)
---@field on_change?        fun(row: Row)       -- tabs mode: called on each value change
---@field border?              "rounded"|"single"|"double"|"none"
---@field max_items?           integer
---@field initial_selected?    table<string, boolean>
---@field current_item?        string
---@field horizontal_actions?  boolean  -- tabs mode: render action rows as a horizontal bar
---@field position?            "editor"|"win"|"cursor"  -- popup placement strategy

---@param opts UiOpts
local function open(opts)
	local mode = opts.mode or "select"
	local title = opts.title
	local subtitle = opts.subtitle
	local info = opts.info
	local items = opts.items or {}
	local tabs = opts.tabs or {}
	local placeholder = opts.placeholder or ""
	local callback = opts.callback or function() end
	local on_change = opts.on_change
	local border_style = opts.border or cfg().border
	local max_items = opts.max_items or cfg().max_items
	local initial_selected = opts.initial_selected or {}
	local current_item = opts.current_item
	local horizontal_actions = (opts.horizontal_actions == true) and (mode == "tabs")
	local position = opts.position or cfg().position or "center"

	local saved_win = api.nvim_get_current_win()
	local saved_view = vim.fn.winsaveview()

	-- ── state ───────────────────────────────────────────────────────────────────

	local active_tab = 1
	local current_idx = 0 -- 0-based for select/multiselect
	local scroll = 0
	local selected = vim.deepcopy(initial_selected)

	-- Resolve items for current tab (simple mode)
	local function cur_items()
		if mode == "tabs" then
			local t = tabs[active_tab]
			return (t and t.items) or {}
		end
		return items
	end

	-- Resolve rows for current tab
	local function cur_rows()
		local t = tabs[active_tab]
		return (t and t.rows) or {}
	end

	-- Is current tab using typed rows?
	local function tab_has_rows()
		local t = tabs[active_tab]
		return t and t.rows and #t.rows > 0
	end

	-- Non-action rows only (used when horizontal_actions = true)
	local function cur_content_rows()
		if not horizontal_actions then
			return cur_rows()
		end
		local out = {}
		for _, r in ipairs(cur_rows()) do
			if r.type ~= "action" then
				table.insert(out, r)
			end
		end
		return out
	end

	-- Action rows only
	local function cur_action_rows()
		local out = {}
		for _, r in ipairs(cur_rows()) do
			if r.type == "action" then
				table.insert(out, r)
			end
		end
		return out
	end

	local row_cursor = first_selectable(cur_rows())

	if current_item then
		for i, v in ipairs(cur_items()) do
			if v == current_item then
				current_idx = i - 1
				break
			end
		end
	end

	-- ── layout ──────────────────────────────────────────────────────────────────

	local function footer_text()
		local k = cfg().keys
		local l = cfg().labels
		if mode == "input" then
			return string.format("  %s %s   %s %s  ", k.confirm, l.confirm, k.cancel, l.cancel)
		elseif mode == "multiselect" then
			return string.format(
				"  %s/%s %s   %s %s   %s %s  ",
				k.multiselect.toggle,
				k.multiselect.toggle_alt,
				l.toggle,
				k.multiselect.confirm,
				l.confirm,
				k.multiselect.cancel,
				l.cancel
			)
		elseif mode == "tabs" then
			if tab_has_rows() then
				-- when cursor is on the horizontal action bar
				if horizontal_actions then
					local cur = cur_rows()[row_cursor]
					if cur and cur.type == "action" then
						return string.format(
							"  %s/%s %s   %s %s   %s %s  ",
							k.tabs.prev,
							k.tabs.next,
							l.navigate,
							k.confirm,
							l.execute,
							k.cancel,
							l.close
						)
					end
				end
				local row = cur_rows()[row_cursor]
				local t = row and row.type or ""
				if t == "bool" or t == "boolean" then
					return string.format(
						"  %s/%s %s   %s %s   %s %s  ",
						k.up,
						k.down,
						l.navigate,
						k.confirm,
						l.toggle,
						k.cancel,
						l.close
					)
				elseif t == "select" then
					return string.format(
						"  %s/%s %s   %s/%s %s   %s %s  ",
						k.up,
						k.down,
						l.navigate,
						k.list.next_option,
						k.list.prev_option,
						l.cycle,
						k.cancel,
						l.close
					)
				elseif
					t == "int"
					or t == "integer"
					or t == "float"
					or t == "number"
					or t == "string"
					or t == "text"
				then
					return string.format(
						"  %s/%s %s   %s %s   %s %s  ",
						k.up,
						k.down,
						l.navigate,
						k.confirm,
						l.edit,
						k.cancel,
						l.close
					)
				elseif t == "action" then
					return string.format(
						"  %s/%s %s   %s %s   %s %s  ",
						k.up,
						k.down,
						l.navigate,
						k.confirm,
						l.execute,
						k.cancel,
						l.close
					)
				else
					return string.format(
						"  %s/%s %s   %s/%s %s   %s %s  ",
						k.tabs.prev,
						k.tabs.next,
						l.tabs,
						k.up,
						k.down,
						l.navigate,
						k.cancel,
						l.close
					)
				end
			else
				return string.format(
					"  %s/%s %s   %s/%s %s   %s %s   %s %s  ",
					k.tabs.prev,
					k.tabs.next,
					l.tabs,
					k.up,
					k.down,
					l.navigate,
					k.confirm,
					l.confirm,
					k.cancel,
					l.cancel
				)
			end
		else
			return string.format(
				"  %s/%s %s   %s %s   %s %s  ",
				k.up,
				k.down,
				l.navigate,
				k.select.confirm,
				l.confirm,
				k.select.cancel,
				l.cancel
			)
		end
	end

	local function max_footer_width()
		if mode == "tabs" and tab_has_rows() then
			local k = cfg().keys
			local l = cfg().labels
			return dw(
				string.format(
					"  %s/%s %s   %s/%s %s   %s %s  ",
					k.up,
					k.down,
					l.navigate,
					k.list.next_option,
					k.list.prev_option,
					l.cycle,
					k.cancel,
					l.close
				)
			)
		end
		return dw(footer_text())
	end

	local function calc_width()
		local w = max_footer_width()
		if title then
			w = math.max(w, dw(title) + 4)
		end
		if subtitle then
			w = math.max(w, dw(subtitle) + 4)
		end
		if info then
			w = math.max(w, dw(info) + 4)
		end
		if mode == "tabs" then
			local tl = ""
			for _, t in ipairs(tabs) do
				tl = tl .. "  " .. (t.label or "") .. "  "
			end
			w = math.max(w, dw(tl) + 2)
			-- check rows width
			for _, t in ipairs(tabs) do
				for _, r in ipairs(t.rows or {}) do
					if not (horizontal_actions and r.type == "action") then
						w = math.max(w, dw(row_display(r)) + 6)
					end
				end
				-- action bar width
				if horizontal_actions then
					local bar, first = "", true
					for _, r in ipairs(t.rows or {}) do
						if r.type == "action" then
							if not first then
								bar = bar .. "  │  "
							end
							bar = bar .. " " .. (r.label or "") .. " "
							first = false
						end
					end
					w = math.max(w, dw(bar) + 4)
				end
				for _, item in ipairs(t.items or {}) do
					w = math.max(w, dw(tostring(item)) + 8)
				end
			end
		elseif mode == "input" then
			w = math.max(w, dw(placeholder) + 6)
		else
			for _, item in ipairs(cur_items()) do
				w = math.max(w, dw(tostring(item)) + 8)
			end
		end
		return math.min(w + 2, vim.o.columns - 6)
	end

	local header_lines
	local meta_lines = {}  -- tabs mode: title/subtitle/info lines above the tab bar
	if mode ~= "tabs" then
		header_lines = {}
		if title then
			table.insert(header_lines, title)
		end
		if subtitle then
			table.insert(header_lines, subtitle)
		end
		if info then
			table.insert(header_lines, "")
			table.insert(header_lines, info)
		end
	else
		if title then
			table.insert(meta_lines, title)
		end
		if subtitle then
			table.insert(meta_lines, subtitle)
		end
		if info then
			table.insert(meta_lines, "")
			table.insert(meta_lines, info)
		end
	end

	-- meta_offset: rows before the tab bar in tabs mode
	local meta_offset = #meta_lines + (#meta_lines > 0 and 1 or 0)
	local header_height = (mode == "tabs") and (meta_offset + 4) or (#(header_lines or {}) > 0 and #header_lines + 3 or 0)
	local action_bar_ht = (horizontal_actions and tab_has_rows() and #cur_action_rows() > 0) and 1 or 0
	local footer_height = 3 + action_bar_ht
	local width = calc_width()

	local function get_content_count()
		if mode == "tabs" then
			if tab_has_rows() then
				return horizontal_actions and #cur_content_rows() or #cur_rows()
			else
				return #cur_items()
			end
		elseif mode == "input" then
			return 1
		else
			return #cur_items()
		end
	end

	local content_height = math.min(get_content_count(), max_items)
	local total_height =
		math.min(header_height + content_height + footer_height, math.floor(vim.o.lines * cfg().max_height))
	content_height = math.max(1, total_height - header_height - footer_height)

	-- ── window ──────────────────────────────────────────────────────────────────

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = FT

	-- Input mode: exempt this buffer from cursor hiding before cursor.update runs.
	-- The cursor module's BufDelete autocmd will clean up the registry on wipe.
	if mode == "input" then
		pcall(require("lvim-utils.cursor").mark_input_buffer, buf, true)
	end

	local _row, _col = calc_pos(total_height, width, position)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = total_height,
		row = _row,
		col = _col,
		border = resolve_border(border_style),
		style = "minimal",
	})
	pcall(require("lvim-utils.cursor").update)

	api.nvim_set_option_value("wrap", false, { win = win })
	api.nvim_set_option_value("scrolloff", 0, { win = win })
	api.nvim_set_option_value("cursorline", false, { win = win })
	api.nvim_set_option_value("winhighlight", "NormalFloat:LvimUiNormal,FloatBorder:LvimUiBorder", { win = win })

	-- ── render ──────────────────────────────────────────────────────────────────

	local function render()
		api.nvim_buf_clear_namespace(buf, NS, 0, -1)
		local lines = {}
		local tab_ranges = {}
		local centered_offset = 0
		local action_bar_ranges = {}
		local action_bar_offset = 0

		-- header
		if mode == "tabs" then
			-- optional title/subtitle/info above the tab bar
			for _, l in ipairs(meta_lines) do
				table.insert(lines, l == "" and "" or center(l, width))
			end
			if #meta_lines > 0 then
				table.insert(lines, "")
			end
			local tab_bar = ""
			for i, t in ipairs(tabs) do
				local lbl = " " .. (t.label or ("Tab " .. i)) .. " "
				local start = #tab_bar
				tab_bar = tab_bar .. lbl
				table.insert(tab_ranges, { active = (i == active_tab), s = start, e = #tab_bar })
			end
			centered_offset = math.floor((width - dw(tab_bar)) / 2)
			table.insert(lines, center(tab_bar, width))
			table.insert(lines, "")
			table.insert(lines, string.rep("─", width))
			table.insert(lines, "")
		else
			for _, l in ipairs(header_lines or {}) do
				table.insert(lines, l == "" and "" or center(l, width))
			end
			if #(header_lines or {}) > 0 then
				table.insert(lines, "")
				table.insert(lines, string.rep("─", width))
				table.insert(lines, "")
			end
		end

		-- content
		if mode == "input" then
			table.insert(lines, lpad(placeholder, width, 2))
		elseif mode == "tabs" and tab_has_rows() then
			local drows = horizontal_actions and cur_content_rows() or cur_rows()
			for i = 1, content_height do
				local row = drows[scroll + i]
				if row then
					table.insert(lines, lpad(row_display(row), width, 2))
				else
					table.insert(lines, "")
				end
			end
			-- action bar
			if horizontal_actions and action_bar_ht > 0 then
				local arows = cur_action_rows()
				local bar, col_b, col_w = "", 0, 0
				for i, ar in ipairs(arows) do
					local seg = " " .. (ar.label or "") .. " "
					local s_b = col_b
					local e_b = col_b + #seg
					local row_abs = 0
					for ri, r in ipairs(cur_rows()) do
						if r == ar then
							row_abs = ri
							break
						end
					end
					table.insert(action_bar_ranges, { s = s_b, e = e_b, row_abs = row_abs })
					bar = bar .. seg
					col_b = e_b
					col_w = col_w + dw(seg)
					if i < #arows then
						local sep = "  │  "
						bar = bar .. sep
						col_b = col_b + #sep
						col_w = col_w + dw(sep)
					end
				end
				action_bar_offset = math.floor((width - col_w) / 2)
				table.insert(lines, center(bar, width))
			end
		else
			local ci = cur_items()
			for i = 1, content_height do
				local item = ci[scroll + i]
				if item then
					local line
					if mode == "multiselect" then
						local mark = selected[item] and icons().multi_selected .. " " or icons().multi_empty .. " "
						line = lpad(mark .. tostring(item), width, 2)
					elseif current_item ~= nil and item == current_item then
						-- current marker replaces the 2-space leading indent
						line = lpad(icons().current .. " " .. tostring(item), width, 0)
					else
						line = lpad(tostring(item), width, 2)
					end
					table.insert(lines, line)
				else
					table.insert(lines, "")
				end
			end
		end

		-- footer
		table.insert(lines, "")
		table.insert(lines, string.rep("─", width))
		table.insert(lines, center(footer_text(), width))

		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = (mode == "input")

		-- highlights
		if mode == "tabs" then
			-- meta line highlights
			for i, l in ipairs(meta_lines) do
				if l == title then
					hl_line(buf, i - 1, "LvimUiTitle")
				elseif l == subtitle then
					hl_line(buf, i - 1, "LvimUiSubtitle")
				elseif l == info then
					hl_line(buf, i - 1, "LvimUiInfo")
				end
			end
			-- tab bar extmarks (shifted down by meta_offset rows)
			for _, r in ipairs(tab_ranges) do
				api.nvim_buf_set_extmark(buf, NS, meta_offset, centered_offset + r.s, {
					end_col = centered_offset + r.e,
					hl_group = r.active and "LvimUiTabActive" or "LvimUiTabInactive",
					priority = 200,
				})
			end
			hl_line(buf, meta_offset + 2, "LvimUiSeparator")
		else
			for i, l in ipairs(header_lines or {}) do
				if l == title then
					hl_line(buf, i - 1, "LvimUiTitle")
				elseif l == subtitle then
					hl_line(buf, i - 1, "LvimUiSubtitle")
				elseif l == info then
					hl_line(buf, i - 1, "LvimUiInfo")
				end
			end
			if #(header_lines or {}) > 0 then
				-- separator sits at: #header_lines (empty) + 1 (separator) = index #header_lines + 1 (0-based)
				hl_line(buf, #header_lines + 1, "LvimUiSeparator")
			end
		end

		if mode == "input" then
			hl_line(buf, header_height, "LvimUiInput")
		elseif mode == "tabs" and tab_has_rows() then
			local drows = horizontal_actions and cur_content_rows() or cur_rows()
			local active_row = cur_rows()[row_cursor]
			for i = 1, content_height do
				local row = drows[scroll + i]
				local row_idx = header_height + i - 1
				if row then
					if row == active_row then
						hl_line(buf, row_idx, "LvimUiCursorLine")
					elseif not is_selectable(row) then
						hl_line(buf, row_idx, "LvimUiSpacer")
					end
				end
			end
			-- action bar highlights
			if horizontal_actions and #action_bar_ranges > 0 then
				local bar_lnum = header_height + content_height -- 0-based
				for _, seg in ipairs(action_bar_ranges) do
					if seg.row_abs == row_cursor then
						api.nvim_buf_set_extmark(buf, NS, bar_lnum, action_bar_offset + seg.s, {
							end_col = action_bar_offset + seg.e,
							hl_group = "LvimUiButtonActive",
							priority = 900,
						})
					else
						api.nvim_buf_set_extmark(buf, NS, bar_lnum, action_bar_offset + seg.s, {
							end_col = action_bar_offset + seg.e,
							hl_group = "LvimUiButtonInactive",
							priority = 200,
						})
					end
				end
			end
		else
			local ci = cur_items()
			for i = 1, content_height do
				local global = scroll + i - 1
				local row_idx = header_height + i - 1
				if #ci > 0 and global == current_idx then
					hl_line(buf, row_idx, "LvimUiCursorLine")
				end
			end
		end

		hl_line(buf, #lines - 2, "LvimUiSeparator")
		hl_line(buf, #lines - 1, "LvimUiFooter")

		-- cursor position
		if mode == "input" then
			api.nvim_win_set_cursor(win, { header_height + 1, #placeholder + 2 })
		elseif mode == "tabs" and tab_has_rows() then
			local cur_r = cur_rows()[row_cursor]
			local on_action = horizontal_actions and cur_r and cur_r.type == "action"
			if on_action then
				local bar_line = header_height + content_height + 1 -- 1-based
				local seg_col = action_bar_offset
				for _, seg in ipairs(action_bar_ranges) do
					if seg.row_abs == row_cursor then
						seg_col = action_bar_offset + seg.s
						break
					end
				end
				api.nvim_win_set_cursor(win, { bar_line, seg_col })
			else
				local drows = horizontal_actions and cur_content_rows() or cur_rows()
				local cp = row_cursor
				if horizontal_actions then
					for ci, r in ipairs(drows) do
						if r == cur_r then
							cp = ci
							break
						end
					end
				end
				if cp >= scroll + 1 and cp <= scroll + content_height then
					api.nvim_win_set_cursor(win, { header_height + (cp - scroll), 0 })
				else
					api.nvim_win_set_cursor(win, { header_height + 1, 0 })
				end
			end
		else
			local ci = cur_items()
			if #ci > 0 and current_idx >= scroll and current_idx < scroll + content_height then
				api.nvim_win_set_cursor(win, { header_height + (current_idx - scroll) + 1, 0 })
			else
				api.nvim_win_set_cursor(win, { header_height + 1, 0 })
			end
		end
	end

	render()

	-- ── actions ─────────────────────────────────────────────────────────────────

	local function close(confirmed, result)
		pcall(api.nvim_win_close, win, true)
		pcall(api.nvim_buf_delete, buf, { force = true })
		vim.schedule(function()
			if api.nvim_win_is_valid(saved_win) then
				pcall(vim.fn.winrestview, saved_view)
			end
		end)
		callback(confirmed, result)
	end

	-- Move for select/multiselect/tabs-items
	local function move(delta)
		local ci = cur_items()
		local new = current_idx + delta
		if new < 0 or new >= #ci then
			return
		end
		current_idx = new
		if current_idx < scroll then
			scroll = current_idx
		elseif current_idx >= scroll + content_height then
			scroll = current_idx - content_height + 1
		end
		render()
	end

	-- Move for tabs with typed rows (skips spacers)
	local function move_row(delta)
		local rows = cur_rows()

		if not horizontal_actions then
			local next = next_selectable(rows, row_cursor, delta)
			if not next then
				return
			end
			row_cursor = next
			if row_cursor < scroll + 1 then
				scroll = row_cursor - 1
			elseif row_cursor > scroll + content_height then
				scroll = row_cursor - content_height
			end
			render()
			return
		end

		-- horizontal_actions: j/k navigate content rows; actions reached by going past the end
		local cur_r = rows[row_cursor]
		local on_action = cur_r and cur_r.type == "action"
		local cr = cur_content_rows()

		if on_action then
			if delta == -1 then
				-- k from action bar → last selectable content row
				for i = #cr, 1, -1 do
					if is_selectable(cr[i]) then
						for ri, r in ipairs(rows) do
							if r == cr[i] then
								row_cursor = ri
								if i > scroll + content_height then
									scroll = i - content_height
								end
								render()
								return
							end
						end
					end
				end
			end
			return -- j from action bar: stay
		end

		-- Find current position in content rows
		local cur_ci = 0
		for i, r in ipairs(cr) do
			if r == cur_r then
				cur_ci = i
				break
			end
		end

		-- Walk content rows in direction, skipping spacers
		local i = cur_ci + delta
		while i >= 1 and i <= #cr do
			if is_selectable(cr[i]) then
				for ri, r in ipairs(rows) do
					if r == cr[i] then
						row_cursor = ri
						if i < scroll + 1 then
							scroll = i - 1
						elseif i > scroll + content_height then
							scroll = i - content_height
						end
						render()
						return
					end
				end
			end
			i = i + delta
		end

		-- Past last content row going down → jump to first action
		if delta > 0 then
			local ar = cur_action_rows()
			if #ar > 0 then
				for ri, r in ipairs(rows) do
					if r == ar[1] then
						row_cursor = ri
						render()
						return
					end
				end
			end
		end
	end

	-- Cycle between action rows on the horizontal bar (l/h)
	local function move_action(delta)
		if not horizontal_actions then
			return
		end
		local rows = cur_rows()
		local cur_r = rows[row_cursor]
		if not cur_r or cur_r.type ~= "action" then
			return
		end
		local ar = cur_action_rows()
		local cur_ai = 1
		for i, r in ipairs(ar) do
			for ri, rr in ipairs(rows) do
				if rr == r and ri == row_cursor then
					cur_ai = i
					break
				end
			end
		end
		local new_ai = ((cur_ai - 1 + delta) % #ar) + 1
		for ri, r in ipairs(rows) do
			if r == ar[new_ai] then
				row_cursor = ri
				render()
				return
			end
		end
	end

	-- Activate a typed row (<CR> behaviour depends on type)
	local function activate_row()
		local rows = cur_rows()
		local row = rows[row_cursor]
		if not row or not is_selectable(row) then
			return
		end
		local t = row.type or "string"

		if t == "bool" or t == "boolean" then
			row.value = not row.value
			if row.run then
				row.run(row.value)
			end
			if on_change then
				on_change(row)
			end
			render()
		elseif t == "select" then
			local opts2 = row.options or {}
			if #opts2 == 0 then
				return
			end
			local idx = 1
			for i, v in ipairs(opts2) do
				if v == row.value then
					idx = i
					break
				end
			end
			row.value = opts2[(idx % #opts2) + 1]
			if row.run then
				row.run(row.value)
			end
			if on_change then
				on_change(row)
			end
			render()
		elseif t == "int" or t == "integer" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					local n = tonumber(input)
					if n and math.floor(n) == n then
						row.value = n
						if row.run then
							row.run(n)
						end
						if on_change then
							on_change(row)
						end
						render()
					end
				end
			)
		elseif t == "float" or t == "number" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					local n = tonumber(input)
					if n then
						row.value = n
						if row.run then
							row.run(n)
						end
						if on_change then
							on_change(row)
						end
						render()
					end
				end
			)
		elseif t == "string" or t == "text" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					row.value = input
					if row.run then
						row.run(input)
					end
					if on_change then
						on_change(row)
					end
					render()
				end
			)
		elseif t == "action" then
			if row.run then
				row.run(row.value, close)
			end
		end
	end

	-- Prev select option with <BS>
	local function prev_select_option()
		local rows = cur_rows()
		local row = rows[row_cursor]
		if not row or (row.type ~= "select") then
			return
		end
		local opts2 = row.options or {}
		if #opts2 == 0 then
			return
		end
		local idx = 1
		for i, v in ipairs(opts2) do
			if v == row.value then
				idx = i
				break
			end
		end
		local prev = idx - 1
		if prev < 1 then
			prev = #opts2
		end
		row.value = opts2[prev]
		if row.run then
			row.run(row.value)
		end
		if on_change then
			on_change(row)
		end
		render()
	end

	-- Snapshot rows for callback on close
	local function rows_snapshot()
		local snap = {}
		for _, t in ipairs(tabs) do
			for _, r in ipairs(t.rows or {}) do
				if r.name then
					snap[r.name] = r.value
				end
			end
		end
		return snap
	end

	-- ── keymaps ─────────────────────────────────────────────────────────────────

	local ko = { buffer = buf, silent = true, nowait = true }
	local k = cfg().keys

	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, ko)
	end

	if mode == "input" then
		vim.schedule(function()
			vim.cmd("startinsert")
		end)
		vim.keymap.set("i", k.confirm, function()
			local l = api.nvim_buf_get_lines(buf, header_height, header_height + 1, false)
			vim.cmd("stopinsert")
			close(true, (l[1] or ""):gsub("^%s+", ""))
		end, ko)
		vim.keymap.set({ "i", "n" }, k.cancel, function()
			vim.cmd("stopinsert")
			close(false, nil)
		end, ko)
	elseif mode == "tabs" then
		map(k.tabs.next, function()
			local on_action = horizontal_actions and cur_rows()[row_cursor] and cur_rows()[row_cursor].type == "action"
			if on_action then
				move_action(1)
			elseif active_tab < #tabs then
				active_tab = active_tab + 1
				current_idx = 0
				scroll = 0
				row_cursor = first_selectable(cur_rows())
				render()
			end
		end)
		map(k.tabs.prev, function()
			local on_action = horizontal_actions and cur_rows()[row_cursor] and cur_rows()[row_cursor].type == "action"
			if on_action then
				move_action(-1)
			elseif active_tab > 1 then
				active_tab = active_tab - 1
				current_idx = 0
				scroll = 0
				row_cursor = first_selectable(cur_rows())
				render()
			end
		end)

		if tab_has_rows() then
			map(k.down, function()
				move_row(1)
			end)
			map(k.up, function()
				move_row(-1)
			end)
			map(k.confirm, function()
				activate_row()
			end)
			map(k.list.next_option, function()
				activate_row()
			end)
			map(k.list.prev_option, function()
				prev_select_option()
			end)
			map(k.cancel, function()
				close(true, rows_snapshot())
			end)
			map(k.close, function()
				close(false, nil)
			end)
		else
			map(k.down, function()
				move(1)
			end)
			map(k.up, function()
				move(-1)
			end)
			map(k.confirm, function()
				local item = cur_items()[current_idx + 1]
				close(true, { tab = active_tab, index = current_idx + 1, item = item })
			end)
			map(k.cancel, function()
				close(false, nil)
			end)
			map(k.close, function()
				close(false, nil)
			end)
		end
	elseif mode == "multiselect" then
		local function toggle_current()
			local item = cur_items()[current_idx + 1]
			if not item then
				return
			end
			if selected[item] then
				selected[item] = nil
			else
				selected[item] = true
			end
			render()
		end
		map(k.down, function()
			move(1)
		end)
		map(k.up, function()
			move(-1)
		end)
		map(k.multiselect.toggle, toggle_current)
		map(k.multiselect.toggle_alt, toggle_current)
		map(k.multiselect.confirm, function()
			close(true, selected)
		end)
		map(k.multiselect.cancel, function()
			close(false, nil)
		end)
		map(k.close, function()
			close(false, nil)
		end)
	else -- select
		map(k.down, function()
			move(1)
		end)
		map(k.up, function()
			move(-1)
		end)
		map(k.select.confirm, function()
			close(true, current_idx + 1)
		end)
		map(k.select.cancel, function()
			close(false, nil)
		end)
		map(k.close, function()
			close(false, nil)
		end)
	end
end

-- ─── info window ─────────────────────────────────────────────────────────────

--- Resolve a dimension value for the info window.
---   "auto"      → min(content_size + 4, 90% of max_val)
---   0 < v <= 1  → fraction of max_val
---   integer     → used as-is
---@param val          string|number
---@param max_val      integer  Screen dimension (lines or columns)
---@param content_size integer  Natural content size
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

--- Make a buffer read-only and block all editing keys in normal and visual mode.
---@param buf integer
local function make_readonly(buf)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modified = false
	vim.bo[buf].buftype = "nofile"
	local ko = { buffer = buf, silent = true, nowait = true }
	for _, k in ipairs({
		"a",
		"i",
		"o",
		"A",
		"I",
		"O",
		"c",
		"C",
		"d",
		"D",
		"s",
		"S",
		"r",
		"R",
		"x",
		"X",
		"p",
		"P",
		"<Del>",
	}) do
		vim.keymap.set("n", k, "<Nop>", ko)
	end
	for _, k in ipairs({ "d", "c", "x", "p" }) do
		vim.keymap.set("v", k, "<Nop>", ko)
	end
end

--- Install a CursorMoved autocmd that clamps the cursor to column 0,
--- preventing horizontal movement in the read-only info window.
---@param buf integer
---@param win integer
local function setup_horizontal_lock(buf, win)
	local aug = api.nvim_create_augroup("LvimInfoHLock_" .. buf, { clear = true })
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = aug,
		buffer = buf,
		callback = function()
			if not api.nvim_win_is_valid(win) then
				return
			end
			local pos = api.nvim_win_get_cursor(win)
			if pos[2] > 0 then
				api.nvim_win_set_cursor(win, { pos[1], 0 })
			end
		end,
	})
end

---Open a read-only informational floating window.
---@param content string|string[]
---@param opts? { title?: string, width?: number|string, height?: number|string, max_height?: number, border?: string, close_keys?: string[], filetype?: string }
---@return integer buf, integer win
function M.info(content, opts)
	local c = vim.tbl_deep_extend("force", config.ui, opts or {})
	local content_lines = type(content) == "string" and vim.split(content, "\n") or vim.list_extend({}, content)

	-- calculate max content width (resolve_dim "auto" adds +4 on top of this)
	local max_w = c.title and dw(c.title) or 0
	for _, l in ipairs(content_lines) do
		max_w = math.max(max_w, dw(l))
	end

	local width = resolve_dim(c.width, vim.o.columns, max_w)

	-- build buffer lines: in-buffer header (title + separator) then content
	local lines = {}
	local title_row, sep_row
	if c.title then
		title_row = 0
		table.insert(lines, center(c.title, width))
		table.insert(lines, "")
		sep_row = #lines
		table.insert(lines, string.rep("─", width))
		table.insert(lines, "")
	end
	vim.list_extend(lines, content_lines)

	local height = resolve_dim(c.height, vim.o.lines, #lines)
	height = math.min(height, math.floor(vim.o.lines * c.max_height))

	local _row, _col = calc_pos(height, width, c.position)

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = c.filetype

	api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = _row,
		col = _col,
		style = "minimal",
		border = resolve_border(c.border),
	})

	api.nvim_set_option_value("scrolloff", 0, { win = win })
	api.nvim_set_option_value("wrap", false, { win = win })
	api.nvim_set_option_value("cursorline", false, { win = win })
	api.nvim_set_option_value("concealcursor", "nvic", { win = win })
	api.nvim_set_option_value("conceallevel", 2, { win = win })
	api.nvim_set_option_value(
		"winhighlight",
		"NormalFloat:LvimUiNormal,FloatBorder:LvimUiBorder,CursorLine:LvimUiNormal",
		{ win = win }
	)

	-- apply header highlights (must be after buf_set_lines)
	if title_row then
		hl_line(buf, title_row, "LvimUiTitle")
		hl_line(buf, sep_row, "LvimUiSeparator")
	end

	make_readonly(buf)
	setup_horizontal_lock(buf, win)

	local ko = { buffer = buf, silent = true, nowait = true }
	for _, k in ipairs(c.close_keys) do
		vim.keymap.set("n", k, function()
			M.close_info(win)
		end, ko)
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

---Close an info window.
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

-- ─── public API ───────────────────────────────────────────────────────────────

--- callback(confirmed, index)
---@param opts UiOpts
function M.select(opts)
	opts.mode = "select"
	open(opts)
end

--- callback(confirmed, table<string, boolean>)
---@param opts UiOpts
function M.multiselect(opts)
	opts.mode = "multiselect"
	open(opts)
end

--- callback(confirmed, string)
---@param opts UiOpts
function M.input(opts)
	opts.mode = "input"
	open(opts)
end

--- callback(confirmed, result)
--- result = { tab, index, item } for simple tabs
--- result = table<name, value>   for typed-row tabs
--- on_change(row) called on every value change
---@param opts UiOpts
function M.tabs(opts)
	opts.mode = "tabs"
	open(opts)
end

return M
