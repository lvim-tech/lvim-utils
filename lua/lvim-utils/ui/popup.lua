-- lua/lvim-utils/ui/popup.lua
-- Core floating popup: select / multiselect / input / tabs modes.
--
-- Modes and their callback signatures:
--   select      → callback(confirmed: boolean, index: integer)
--   multiselect → callback(confirmed: boolean, selected: table<string, boolean>)
--   input       → callback(confirmed: boolean, value: string)
--   tabs        → callback(confirmed: boolean, result)
--                 result = { tab, index, item } for simple tabs
--                 result = table<name, value>   for typed-row tabs
local util       = require("lvim-utils.ui.util")
local rows       = require("lvim-utils.ui.rows")
local header_mod = require("lvim-utils.ui.header")
local content_mod = require("lvim-utils.ui.content")
local footer_mod = require("lvim-utils.ui.footer")

local api = vim.api

local NS              = util.NS
local FT              = util.FT
local cfg             = util.cfg
local dw              = util.dw
local resolve_border  = util.resolve_border
local calc_pos        = util.calc_pos

local row_display       = rows.row_display
local item_label        = rows.item_label
local item_icon         = rows.item_icon
local first_selectable  = rows.first_selectable
local resolve_initial_row = rows.resolve_initial_row

local M = {}

-- ─── instance cfg helpers ─────────────────────────────────────────────────────

--- Build a merged config: global defaults deep-extended with instance overrides.
---@param instance_cfg table|nil
---@return table
local function build_cfg(instance_cfg)
	if not instance_cfg then return util.cfg() end
	local merged = vim.deepcopy(util.cfg())
	return vim.tbl_deep_extend("force", merged, instance_cfg)
end

--- Build an hl_map from instance highlights: group_name → resolved inline group name.
--- Instance highlights are registered as anonymous inline groups so they never
--- collide with the global named groups.
---@param highlights table|nil
---@return table
local function build_hl_map(highlights)
	if not highlights then return {} end
	local map = {}
	for name, def in pairs(highlights) do
		map[name] = util.resolve_hl(def)
	end
	return map
end

--- Return a resolve_hl function scoped to the instance hl_map.
--- Named strings are looked up in hl_map first; inline tables go through
--- the shared util.resolve_hl inline cache.
---@param hl_map table
---@return fun(val: any): string|nil
local function make_resolve_hl(hl_map)
	return function(val)
		if type(val) == "string" then return hl_map[val] or val end
		return util.resolve_hl(val)
	end
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Parse a HeaderField into (text, hl).
---@param v HeaderField|nil
---@return string|nil, HlDef|nil
local function parse_hf(v)
	if type(v) == "table" then return v.text, v.hl end
	return v, nil
end

-- ─── type annotations ─────────────────────────────────────────────────────────

---@alias UiMode "select"|"multiselect"|"input"|"tabs"

---@alias HeaderField string|{ text: string, hl?: HlDef }

---@class UiOpts
---@field mode?             UiMode
---@field title?            HeaderField
---@field subtitle?         HeaderField
---@field info?             HeaderField
---@field items?            (string|SelectItem)[]
---@field tabs?             Tab[]
---@field placeholder?      string
---@field callback?         fun(confirmed: boolean, result: any)
---@field on_change?        fun(row: Row)
---@field border?              "rounded"|"single"|"double"|"none"
---@field max_items?           integer
---@field initial_selected?    table<string, boolean>
---@field current_item?        string|SelectItem
---@field horizontal_actions?  boolean
---@field position?            "editor"|"win"|"cursor"
---@field tab_selector?        string|integer
---@field initial_row?         string|integer

-- ─── open ─────────────────────────────────────────────────────────────────────

---@param opts UiOpts
---@param instance_cfg? table  Per-instance config overrides (highlights, icons, keys, …)
function M.open(opts, instance_cfg)
	local s_cfg      = build_cfg(instance_cfg)
	local hl_map     = build_hl_map(instance_cfg and instance_cfg.highlights)
	local resolve_hl = make_resolve_hl(hl_map)

	local mode               = opts.mode or "select"
	local title,    title_hl    = parse_hf(opts.title)
	local subtitle, subtitle_hl = parse_hf(opts.subtitle)
	local info,     info_hl     = parse_hf(opts.info)
	local items              = opts.items or {}
	local tabs_opt           = opts.tabs or {}
	local placeholder        = opts.placeholder or ""
	local callback           = opts.callback or function() end
	local on_change          = opts.on_change
	local border_style       = opts.border or s_cfg.border
	local max_items          = opts.max_items or s_cfg.max_items
	local initial_selected   = opts.initial_selected or {}
	local current_item       = opts.current_item
	local horizontal_actions = (opts.horizontal_actions == true) and (mode == "tabs")
	local position           = opts.position or s_cfg.position or "center"
	local tab_selector       = opts.tab_selector
	local initial_row        = opts.initial_row

	local saved_win  = api.nvim_get_current_win()
	local saved_view = vim.fn.winsaveview()

	-- ── initial tab ───────────────────────────────────────────────────────────

	local initial_active_tab = 1
	if tab_selector then
		if type(tab_selector) == "number" then
			initial_active_tab = math.max(1, math.min(math.floor(tab_selector), #tabs_opt))
		else
			for i, t in ipairs(tabs_opt) do
				if t.label == tab_selector then initial_active_tab = i; break end
			end
		end
	end

	-- ── state ─────────────────────────────────────────────────────────────────
	-- All mutable state in `s` so mode files can read/write through it.

	local s = {
		-- config / opts
		mode               = mode,
		horizontal_actions = horizontal_actions,
		position           = position,
		placeholder        = placeholder,
		on_change          = on_change,
		tabs               = tabs_opt,
		items              = items,

		-- header (set during layout)
		title              = title,
		subtitle           = subtitle,
		info               = info,
		title_hl           = title_hl,
		subtitle_hl        = subtitle_hl,
		info_hl            = info_hl,
		meta_lines         = {},
		header_lines       = {},
		meta_offset        = 0,
		header_height      = 0,
		width              = 0,

		-- mutable navigation state
		active_tab         = initial_active_tab,
		current_idx        = 0,
		scroll             = 0,
		selected           = vim.deepcopy(initial_selected),
		row_cursor         = 1,

		-- layout (updated by recalc_heights)
		action_bar_ht      = 0,
		footer_height      = 0,
		content_height     = 0,
		total_height       = 0,
		_row               = 0,
		_col               = 0,

		-- set after window creation
		buf                = nil,
		win                = nil,
		ko                 = nil,
	}

	-- ── helper functions ──────────────────────────────────────────────────────

	local function cur_items()
		if s.mode == "tabs" then
			local t = s.tabs[s.active_tab]
			return (t and t.items) or {}
		end
		return s.items
	end

	local function cur_rows()
		local t = s.tabs[s.active_tab]
		return (t and t.rows) or {}
	end

	local function tab_has_rows()
		local t = s.tabs[s.active_tab]
		return t and t.rows and #t.rows > 0
	end

	local function cur_content_rows()
		if not s.horizontal_actions then return cur_rows() end
		local out = {}
		for _, r in ipairs(cur_rows()) do
			if r.type ~= "action" then table.insert(out, r) end
		end
		return out
	end

	local function cur_action_rows()
		local out = {}
		for _, r in ipairs(cur_rows()) do
			if r.type == "action" then table.insert(out, r) end
		end
		return out
	end

	s.cur_items        = cur_items
	s.cur_rows         = cur_rows
	s.tab_has_rows     = tab_has_rows
	s.cur_content_rows = cur_content_rows
	s.cur_action_rows  = cur_action_rows

	-- ── initial cursor ────────────────────────────────────────────────────────

	s.row_cursor = resolve_initial_row(cur_rows(), initial_row)

	if current_item then
		for i, v in ipairs(cur_items()) do
			if v == current_item then s.current_idx = i - 1; break end
		end
	end

	-- ── layout ────────────────────────────────────────────────────────────────

	if mode ~= "tabs" then
		s.header_lines = {}
		if title    then table.insert(s.header_lines, title); table.insert(s.header_lines, "") end
		if subtitle then table.insert(s.header_lines, subtitle) end
		if info     then table.insert(s.header_lines, ""); table.insert(s.header_lines, info) end
	else
		s.meta_lines = {}
		if title    then table.insert(s.meta_lines, title); table.insert(s.meta_lines, "") end
		if subtitle then table.insert(s.meta_lines, subtitle) end
		if info     then table.insert(s.meta_lines, ""); table.insert(s.meta_lines, info) end
	end

	s.meta_offset   = #s.meta_lines + (#s.meta_lines > 0 and 1 or 0)
	s.header_height = (mode == "tabs")
		and (s.meta_offset + 4)
		or  (#s.header_lines > 0 and #s.header_lines + 3 or 0)

	local function get_content_count()
		if mode == "tabs" then
			if tab_has_rows() then
				return s.horizontal_actions and #cur_content_rows() or #cur_rows()
			else
				return #cur_items()
			end
		elseif mode == "input" then
			return 1
		else
			return #cur_items()
		end
	end

	local function recalc_heights()
		s.action_bar_ht  = (s.horizontal_actions and tab_has_rows() and #cur_action_rows() > 0) and 1 or 0
		s.footer_height  = 3 + s.action_bar_ht
		s.content_height = math.min(get_content_count(), max_items)
		s.total_height   = math.min(
			s.header_height + s.content_height + s.footer_height,
			math.floor(vim.o.lines * s_cfg.max_height)
		)
		s.content_height = math.max(1, s.total_height - s.header_height - s.footer_height)
	end

	s.recalc_heights = recalc_heights

	local function calc_width()
		local w = footer_mod.max_width(mode, tab_has_rows(), s_cfg)
		if title    then w = math.max(w, dw(title)    + 4) end
		if subtitle then w = math.max(w, dw(subtitle) + 4) end
		if info     then w = math.max(w, dw(info)     + 4) end
		if mode == "tabs" then
			local tl = ""
			for _, t in ipairs(s.tabs) do tl = tl .. "  " .. (t.label or "") .. "  " end
			w = math.max(w, dw(tl) + 2)
			for _, t in ipairs(s.tabs) do
				for _, r in ipairs(t.rows or {}) do
					if not (s.horizontal_actions and r.type == "action") then
						w = math.max(w, dw(row_display(r, s_cfg.icons)) + 6)
					end
				end
				if s.horizontal_actions then
					local bar, first = "", true
					for _, r in ipairs(t.rows or {}) do
						if r.type == "action" then
							if not first then bar = bar .. "  │  " end
							bar   = bar .. " " .. (r.label or "") .. " "
							first = false
						end
					end
					w = math.max(w, dw(bar) + 4)
				end
				for _, item in ipairs(t.items or {}) do
					local iw = dw(item_label(item)) + (item_icon(item) and (dw(item_icon(item)) + 1) or 0)
					w = math.max(w, iw + 8)
				end
			end
		elseif mode == "input" then
			w = math.max(w, dw(placeholder) + 6)
		else
			for _, item in ipairs(cur_items()) do
				local iw = dw(item_label(item)) + (item_icon(item) and (dw(item_icon(item)) + 1) or 0)
				w = math.max(w, iw + 8)
			end
		end
		return math.min(w + 2, vim.o.columns - 6)
	end

	s.width = calc_width()
	recalc_heights()

	-- ── window ────────────────────────────────────────────────────────────────

	s.buf = api.nvim_create_buf(false, true)
	vim.bo[s.buf].bufhidden = "wipe"
	vim.bo[s.buf].swapfile  = false
	vim.bo[s.buf].filetype  = FT

	if mode == "input" then
		pcall(require("lvim-utils.cursor").mark_input_buffer, s.buf, true)
	end

	s._row, s._col = calc_pos(s.total_height, s.width, position)
	s.win = api.nvim_open_win(s.buf, true, {
		relative = "editor",
		width    = s.width,
		height   = s.total_height,
		row      = s._row,
		col      = s._col,
		border   = resolve_border(border_style),
		style    = "minimal",
	})
	pcall(require("lvim-utils.cursor").update)

	local normal_hl = hl_map["LvimUiNormal"] or "LvimUiNormal"
	local border_hl = hl_map["LvimUiBorder"] or "LvimUiBorder"
	api.nvim_set_option_value("wrap",      false, { win = s.win })
	api.nvim_set_option_value("scrolloff", 0,     { win = s.win })

	-- ── render ────────────────────────────────────────────────────────────────

	local winhighlight_val =
		"Normal:"      .. normal_hl ..
		",NormalFloat:" .. normal_hl ..
		",FloatBorder:" .. border_hl

	local function reset_win_opts()
		if not api.nvim_win_is_valid(s.win) then return end
		api.nvim_set_option_value("number",         false,             { win = s.win })
		api.nvim_set_option_value("relativenumber", false,             { win = s.win })
		api.nvim_set_option_value("signcolumn",     "no",              { win = s.win })
		api.nvim_set_option_value("cursorline",     false,             { win = s.win })
		api.nvim_set_option_value("cursorcolumn",   false,             { win = s.win })
		api.nvim_set_option_value("winblend",       0,                 { win = s.win })
		api.nvim_set_option_value("winhighlight",   winhighlight_val,  { win = s.win })
	end

	local function render()
		reset_win_opts()
		api.nvim_buf_clear_namespace(s.buf, NS, 0, -1)

		local ctx = {
			cfg        = s_cfg,
			resolve_hl = resolve_hl,
			mode               = s.mode,
			width              = s.width,
			buf                = s.buf,
			tabs               = s.tabs,
			active_tab         = s.active_tab,
			meta_lines         = s.meta_lines,
			header_lines       = s.header_lines,
			meta_offset        = s.meta_offset,
			header_height      = s.header_height,
			title              = s.title,
			subtitle           = s.subtitle,
			info               = s.info,
			title_hl           = s.title_hl,
			subtitle_hl        = s.subtitle_hl,
			info_hl            = s.info_hl,
			content_height     = s.content_height,
			scroll             = s.scroll,
			row_cursor         = s.row_cursor,
			selected           = s.selected,
			current_item       = current_item,
			current_idx        = s.current_idx,
			horizontal_actions = s.horizontal_actions,
			action_bar_ht      = s.action_bar_ht,
			placeholder        = s.placeholder,
			items              = cur_items(),
			rows               = cur_rows(),
			has_rows           = tab_has_rows(),
			content_rows       = cur_content_rows(),
			action_rows        = cur_action_rows(),
		}

		local hdr_lines, tab_ranges, centered_offset         = header_mod.build(ctx)
		local cnt_lines, action_bar_ranges, action_bar_offset = content_mod.build(ctx)
		local ftr_lines, hint_ranges                          = footer_mod.build(ctx)

		local lines = {}
		vim.list_extend(lines, hdr_lines)
		vim.list_extend(lines, cnt_lines)
		vim.list_extend(lines, ftr_lines)

		vim.bo[s.buf].modifiable = true
		api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
		vim.bo[s.buf].modifiable = (s.mode == "input")

		header_mod.apply_hl(s.buf, ctx, tab_ranges, centered_offset)
		content_mod.apply_hl(s.buf, ctx, action_bar_ranges, action_bar_offset)
		footer_mod.apply_hl(s.buf, #lines, hint_ranges, ctx)

		-- cursor positioning
		if s.mode == "input" then
			api.nvim_win_set_cursor(s.win, { s.header_height + 1, #s.placeholder + 2 })

		elseif s.mode == "tabs" and tab_has_rows() then
			local cur_r     = cur_rows()[s.row_cursor]
			local on_action = s.horizontal_actions and cur_r and cur_r.type == "action"
			if on_action then
				local bar_line = s.header_height + s.content_height + 1
				local seg_col  = action_bar_offset
				for _, seg in ipairs(action_bar_ranges) do
					if seg.row_abs == s.row_cursor then seg_col = action_bar_offset + seg.s; break end
				end
				api.nvim_win_set_cursor(s.win, { bar_line, seg_col })
			else
				local drows = s.horizontal_actions and cur_content_rows() or cur_rows()
				local cp    = s.row_cursor
				if s.horizontal_actions then
					for ci, r in ipairs(drows) do
						if r == cur_r then cp = ci; break end
					end
				end
				if cp >= s.scroll + 1 and cp <= s.scroll + s.content_height then
					api.nvim_win_set_cursor(s.win, { s.header_height + (cp - s.scroll), 0 })
				else
					api.nvim_win_set_cursor(s.win, { s.header_height + 1, 0 })
				end
			end

		else
			local ci = cur_items()
			if #ci > 0 and s.current_idx >= s.scroll and s.current_idx < s.scroll + s.content_height then
				api.nvim_win_set_cursor(s.win, { s.header_height + (s.current_idx - s.scroll) + 1, 0 })
			else
				api.nvim_win_set_cursor(s.win, { s.header_height + 1, 0 })
			end
		end
	end

	-- ── close ─────────────────────────────────────────────────────────────────

	local function close(confirmed, result)
		pcall(api.nvim_win_close, s.win, true)
		pcall(api.nvim_buf_delete, s.buf, { force = true })
		vim.schedule(function()
			if api.nvim_win_is_valid(saved_win) then
				pcall(vim.fn.winrestview, saved_view)
			end
		end)
		callback(confirmed, result)
	end

	s.render = render
	s.close  = close
	s.ko     = { buffer = s.buf, silent = true, nowait = true }

	-- ── initial scroll for tabs ───────────────────────────────────────────────

	if initial_row and mode == "tabs" and tab_has_rows() then
		local pos = s.row_cursor
		if s.horizontal_actions then
			local target = cur_rows()[s.row_cursor]
			for ci, r in ipairs(cur_content_rows()) do
				if r == target then pos = ci; break end
			end
		end
		if pos > s.content_height then s.scroll = pos - s.content_height end
	end

	render()

	-- ── dispatch to mode ──────────────────────────────────────────────────────

	require("lvim-utils.ui.mode." .. mode).attach(s)
end

return M
