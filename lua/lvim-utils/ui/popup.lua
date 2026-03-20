-- lua/lvim-utils/ui/popup.lua
-- Core floating popup: select / multiselect / input / tabs modes.
--
-- Three-window architecture:
--   win_header  (not focusable) — title / tab-bar / separator
--   win         (focused)       — content rows / input field
--   win_footer  (not focusable) — separator / key hints
--
-- The three windows are positioned adjacently and moved together.
-- This eliminates horizontal scroll in win bleeding into win_header/win_footer.
--
-- Modes and their callback signatures:
--   select      → callback(confirmed: boolean, index: integer)
--   multiselect → callback(confirmed: boolean, selected: table<string, boolean>)
--   input       → callback(confirmed: boolean, value: string)
--   tabs        → callback(confirmed: boolean, result)
--                 result = { tab, index, item } for simple tabs
--                 result = table<name, value>   for typed-row tabs
local util = require("lvim-utils.ui.util")
local rows = require("lvim-utils.ui.rows")
local header_mod = require("lvim-utils.ui.header")
local content_mod = require("lvim-utils.ui.content")
local footer_mod = require("lvim-utils.ui.footer")

local api = vim.api

local NS = util.NS
local FT = util.FT
local dw = util.dw
local resolve_border = util.resolve_border
local calc_pos = util.calc_pos

local row_display = rows.row_display
local item_label = rows.item_label
local item_icon = rows.item_icon
local resolve_initial_row = rows.resolve_initial_row

local M = {}

-- ─── instance cfg helpers ─────────────────────────────────────────────────────

--- Build a merged config: global defaults deep-extended with instance overrides.
---@param instance_cfg table|nil
---@return table
local function build_cfg(instance_cfg)
	if not instance_cfg then
		return util.cfg()
	end
	local merged = vim.deepcopy(util.cfg())
	return vim.tbl_deep_extend("force", merged, instance_cfg)
end

--- Build an hl_map from instance highlights: group_name → resolved inline group name.
--- Instance highlights are registered as anonymous inline groups so they never
--- collide with the global named groups.
---@param highlights table|nil
---@return table
local function build_hl_map(highlights)
	if not highlights then
		return {}
	end
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
		if type(val) == "string" then
			return hl_map[val] or val
		end
		return util.resolve_hl(val)
	end
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Parse a HeaderField into (text, hl).
---@param v HeaderField|nil
---@return string|nil, HlDef|nil
local function parse_hf(v)
	if type(v) == "table" then
		return v.text, v.hl
	end
	return v, nil
end

-- ─── type annotations ─────────────────────────────────────────────────────────

---@alias UiMode "select"|"multiselect"|"input"|"tabs"|"info"

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
---@field border?           "rounded"|"single"|"double"|"none"
---@field width?            integer                             Fixed width (overrides auto and config)
---@field max_width?        integer                             Cap for auto width (overrides config max_width)
---@field height?           number                              Fixed total height: 0.1-1.0 fraction of screen or absolute lines
---@field max_items?        integer
---@field close_keys?       string[]                           Override config close_keys for this instance
---@field initial_selected? table<string, boolean>
---@field current_item?     string|SelectItem
---@field horizontal_actions? boolean
---@field position?         "editor"|"win"|"cursor"
---@field tab_selector?     string|integer
---@field initial_row?      string|integer
---@field footer_hints?     {key:string, label:string}[]       Override footer hint list
---@field show_footer?      boolean                            false = no footer (default true)
---@field back_key?         string                             Key to trigger back navigation
---@field content?          string[]                           Info mode: raw content lines
---@field readonly?         boolean                            Info mode: read-only (default true)
---@field wrap?             boolean                            Info mode: enable line wrap
---@field highlights?       {line:integer, col_start:integer, col_end:integer, group:string}[]
---@field folds?            {start_line:integer, end_line:integer}[]
---@field fold_icon?        string                             Icon for collapsed fold indicator
---@field markview?         boolean
---@field keymaps?          table<string, fun()|{fn:fun(), label:string}> Custom keymaps (info mode)
---@field zindex?           integer
---@field on_open?          fun(buf: integer, win: integer)
---@field hide_cursor?      boolean                            false = keep cursor visible (default: true for most modes)

-- ─── open ─────────────────────────────────────────────────────────────────────

---@param opts UiOpts
---@param instance_cfg? table  Per-instance config overrides (highlights, icons, keys, …)
function M.open(opts, instance_cfg)
	local s_cfg = build_cfg(instance_cfg)
	local hl_map = build_hl_map(instance_cfg and instance_cfg.highlights)
	local resolve_hl = make_resolve_hl(hl_map)

	local mode = opts.mode or "select"
	local title, title_hl = parse_hf(opts.title)
	local subtitle, subtitle_hl = parse_hf(opts.subtitle)
	local info, info_hl = parse_hf(opts.info)
	local items = (mode == "info" and opts.content) or opts.items or {}
	local tabs_opt = opts.tabs or {}
	local placeholder = opts.placeholder or ""
	local callback = opts.callback or function() end
	local on_change = opts.on_change
	local border_style = opts.border or s_cfg.border
	local max_items = opts.max_items or s_cfg.max_items
	local close_keys = opts.close_keys or s_cfg.close_keys
	local initial_selected = opts.initial_selected or {}
	local current_item = opts.current_item
	local horizontal_actions = (opts.horizontal_actions == true) and (mode == "tabs")
	local position = opts.position or s_cfg.position or "center"
	local tab_selector = opts.tab_selector
	local initial_row = opts.initial_row
	local on_open = opts.on_open

	local saved_win = api.nvim_get_current_win()
	local saved_view = vim.fn.winsaveview()

	-- ── initial tab ───────────────────────────────────────────────────────────

	local initial_active_tab = 1
	if tab_selector then
		if type(tab_selector) == "number" then
			initial_active_tab = math.max(1, math.min(math.floor(tab_selector), #tabs_opt))
		else
			for i, t in ipairs(tabs_opt) do
				if t.label == tab_selector then
					initial_active_tab = i
					break
				end
			end
		end
	end

	-- ── state ─────────────────────────────────────────────────────────────────
	-- All mutable state in `s` so mode files can read/write through it.

	local s = {
		-- config / opts
		cfg = s_cfg,
		mode = mode,
		horizontal_actions = horizontal_actions,
		position = position,
		placeholder = placeholder,
		on_change = on_change,
		tabs = tabs_opt,
		items = items,

		-- header (set during layout)
		title = title,
		subtitle = subtitle,
		info = info,
		title_hl = title_hl,
		subtitle_hl = subtitle_hl,
		info_hl = info_hl,
		meta_lines = {},
		header_lines = {},
		meta_offset = 0,
		header_height = 0,
		width = 0,

		-- mutable navigation state
		active_tab = initial_active_tab,
		current_idx = 0,
		scroll = 0,
		selected = vim.deepcopy(initial_selected),
		row_cursor = 1,

		-- layout (updated by recalc_heights)
		action_bar_ht = 0,
		footer_height = 0,
		content_height = 0,
		total_height = 0,
		_row = 0,
		_col = 0,

		close_keys = close_keys,
		show_footer = opts.show_footer ~= false,
		back_key = opts.back_key,

		-- info mode
		info_readonly = opts.readonly ~= false,
		info_wrap = opts.wrap == true,
		info_highlights = opts.highlights,
		info_folds = opts.folds,
		info_fold_icon = opts.fold_icon,
		info_markview = opts.markview,
		info_keymaps = opts.keymaps,

		-- set after window creation
		buf = nil,
		win = nil,
		buf_header = nil,
		win_header = nil,
		buf_footer = nil,
		win_footer = nil,
		ko = nil,
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
		if not s.horizontal_actions then
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

	local function cur_action_rows()
		local out = {}
		for _, r in ipairs(cur_rows()) do
			if r.type == "action" then
				table.insert(out, r)
			end
		end
		return out
	end

	s.cur_items = cur_items
	s.cur_rows = cur_rows
	s.tab_has_rows = tab_has_rows
	s.cur_content_rows = cur_content_rows
	s.cur_action_rows = cur_action_rows

	-- ── initial cursor ────────────────────────────────────────────────────────

	s.row_cursor = resolve_initial_row(cur_rows(), initial_row)

	if current_item then
		for i, v in ipairs(cur_items()) do
			if v == current_item then
				s.current_idx = i - 1
				break
			end
		end
	end

	-- ── layout ────────────────────────────────────────────────────────────────

	if mode ~= "tabs" then
		s.header_lines = {}
		if title then
			table.insert(s.header_lines, title)
			if subtitle or info then
				table.insert(s.header_lines, "")
			end
		end
		if subtitle then
			table.insert(s.header_lines, subtitle)
		end
		if info then
			table.insert(s.header_lines, "")
			table.insert(s.header_lines, info)
		end
	else
		s.meta_lines = {}
		if title then
			table.insert(s.meta_lines, title)
			if subtitle or info then
				table.insert(s.meta_lines, "")
			end
		end
		if subtitle then
			table.insert(s.meta_lines, subtitle)
		end
		if info then
			table.insert(s.meta_lines, "")
			table.insert(s.meta_lines, info)
		end
	end

	s.meta_offset = #s.meta_lines + (#s.meta_lines > 0 and 1 or 0)
	s.header_height = (mode == "tabs") and (s.meta_offset + 4) or (#s.header_lines > 0 and #s.header_lines + 3 or 0)

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

	local function resolve_height(v)
		return math.floor(v <= 1.0 and vim.o.lines * v or v)
	end

	local function recalc_heights()
		s.action_bar_ht = (s.horizontal_actions and tab_has_rows() and #cur_action_rows() > 0) and 1 or 0
		s.footer_height = s.show_footer and (3 + s.action_bar_ht) or 0
		local max_total = type(s_cfg.height) == "number" and resolve_height(s_cfg.height)
			or math.floor(vim.o.lines * s_cfg.max_height)
		if type(s_cfg.height) == "number" then
			-- explicit height drives content — max_items controls only virtual scroll buffer
			local avail = math.max(1, max_total - s.header_height - s.footer_height)
			s.content_height = math.min(get_content_count(), avail)
		else
			s.content_height = max_items and math.min(get_content_count(), max_items) or get_content_count()
		end
		s.content_height = math.max(1, s.content_height)
		-- Use s._real_hdr once set (after s.header_height is reset to 0 below).
		-- On the first call s._real_hdr is nil so s.header_height is still correct.
		s.total_height = (s._real_hdr or s.header_height) + s.content_height + s.footer_height
	end

	s.recalc_heights = recalc_heights

	local function calc_width()
		local w = footer_mod.max_width(mode, tab_has_rows(), s_cfg)
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
			for _, t in ipairs(s.tabs) do
				tl = tl .. "  " .. (t.label or "") .. "  "
			end
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
					local iw = dw(item_label(item)) + (item_icon(item) and (dw(item_icon(item)) + 1) or 0)
					w = math.max(w, iw + 8)
				end
			end
		elseif mode == "input" then
			w = math.max(w, dw(placeholder) + 6)
		elseif mode == "info" then
			for _, line in ipairs(cur_items()) do
				w = math.max(w, dw(line) + 2)
			end
		else
			for _, item in ipairs(cur_items()) do
				local iw = dw(item_label(item)) + (item_icon(item) and (dw(item_icon(item)) + 1) or 0)
				w = math.max(w, iw + 8)
			end
		end
		local hard_max = vim.o.columns - 6
		local function resolve_max(v)
			if not v then
				return hard_max
			end
			local abs = v <= 1.0 and math.floor(vim.o.columns * v) or math.floor(v)
			return math.min(abs, hard_max)
		end
		local call_max = resolve_max(opts.max_width or s_cfg.max_width)
		return math.floor(math.min(w + 2, call_max))
	end

	local function resolve_width(v)
		return math.floor(v <= 1.0 and vim.o.columns * v or v)
	end

	if opts.width then
		s.width = resolve_width(opts.width)
	elseif type(s_cfg.width) == "number" then
		s.width = resolve_width(s_cfg.width)
	else
		s.width = calc_width()
	end
	recalc_heights()
	if opts.height then
		local max_total = resolve_height(opts.height)
		s.total_height = math.min(s.total_height, max_total)
		s.content_height = math.max(1, s.total_height - s.header_height - s.footer_height)
		s.total_height = s.header_height + s.content_height + s.footer_height
	end

	-- ── windows ───────────────────────────────────────────────────────────────
	-- Three separate floating windows stacked vertically:
	--   win_header (not focusable) at row _row
	--   win        (focused)       at row _row + real_header_height
	--   win_footer (not focusable) at row _row + real_header_height + content_height

	-- Save the real layout heights before overriding s.header_height / s.footer_height
	-- so mode files see a 0-based content buffer.
	local real_header_height = s.header_height
	local real_footer_height = s.show_footer and s.footer_height or 0

	-- Store so recalc_heights() can keep s.total_height correct after
	-- s.header_height is reset to 0 below (tab-switch centering fix).
	s._real_hdr = real_header_height

	-- Content buffer (receives keyboard input / focus)
	s.buf = api.nvim_create_buf(false, true)
	vim.bo[s.buf].bufhidden = "wipe"
	vim.bo[s.buf].swapfile = false
	vim.bo[s.buf].filetype = FT

	-- Header buffer (read-only display)
	s.buf_header = api.nvim_create_buf(false, true)
	vim.bo[s.buf_header].bufhidden = "wipe"
	vim.bo[s.buf_header].swapfile = false

	-- Footer buffer (read-only display)
	s.buf_footer = api.nvim_create_buf(false, true)
	vim.bo[s.buf_footer].bufhidden = "wipe"
	vim.bo[s.buf_footer].swapfile = false

	if mode == "input" or opts.hide_cursor == false then
		pcall(require("lvim-utils.cursor").mark_input_buffer, s.buf, true)
	end

	-- ── partial border tables ─────────────────────────────────────────────
	-- Each window gets only the sides it "owns" so the three windows
	-- together look like one seamless bordered box:
	--   win_header  → top + left + right   (no bottom)
	--   win         → left + right only    (no top/bottom)
	--   win_footer  → bottom + left + right (no top)
	-- When no adjacent window exists the content window inherits that edge.
	--
	-- resolve_border handles both named strings ("rounded", "single", …)
	-- and custom 8-element tables, so user config is always respected.
	local has_header_win = real_header_height > 0
	local has_footer_win = s.show_footer and real_footer_height > 0

	local bc = resolve_border(border_style)
	local TL, top, TR, R, BR, bot, BL, L = bc[1], bc[2], bc[3], bc[4], bc[5], bc[6], bc[7], bc[8]

	-- A side contributes space only when its char is non-empty.
	local bro = top ~= "" and 1 or 0 -- top-border row overhead (header window)
	local bbo = bot ~= "" and 1 or 0 -- bottom-border row overhead (footer window)
	local blo = L ~= "" and 1 or 0 -- left-border col overhead
	local bro_w = R ~= "" and 1 or 0 -- right-border col overhead
	local use_border = bro + bbo + blo + bro_w > 0

	local b_header, b_content, b_footer
	if use_border then
		b_header = { TL, top, TR, R, "", "", "", L }
		b_content = {
			has_header_win and "" or TL,
			has_header_win and "" or top,
			has_header_win and "" or TR,
			R,
			has_footer_win and "" or BR,
			has_footer_win and "" or bot,
			has_footer_win and "" or BL,
			L,
		}
		b_footer = { "", "", "", R, BR, bot, BL, L }
	else
		b_header = "none"
		b_content = "none"
		b_footer = "none"
	end

	-- Store border overhead so that any later recalc_pos call (e.g. tab switch)
	-- uses the same offsets as the initial open.
	local _bh = bro + bbo -- total row overhead (top + bottom borders)
	local _bw = blo + bro_w -- total col overhead (left + right borders)
	s._bh, s._bw, s._blo = _bh, _bw, blo

	-- Centre on the full visual footprint (border chars included).
	s._row, s._col = calc_pos(s.total_height + _bh, s.width + _bw, position)

	-- Content window row: sits right after the header's content rows
	-- plus 1 if the header has a top border (that border occupies its own row).
	local content_row = s._row + (has_header_win and (real_header_height + bro) or 0)

	-- Header window (not focusable)
	s.win_header = nil
	if real_header_height > 0 then
		s.win_header = api.nvim_open_win(s.buf_header, false, {
			relative = "editor",
			width = s.width,
			height = real_header_height,
			row = s._row,
			col = s._col,
			border = b_header,
			style = "minimal",
			focusable = false,
			zindex = opts.zindex,
		})
	end

	-- Content window (focused)
	-- Suppress autocmds to prevent WinEnter/BufEnter handlers from closing
	-- the window immediately (e.g. when called from a vim.schedule callback).
	local _ei = vim.o.eventignore
	vim.o.eventignore = "all"
	s.win = api.nvim_open_win(s.buf, true, {
		relative = "editor",
		width = s.width,
		height = s.content_height,
		row = content_row,
		col = s._col,
		border = b_content,
		style = "minimal",
		zindex = opts.zindex,
	})
	vim.o.eventignore = _ei

	-- Footer window (not focusable)
	s.win_footer = nil
	if s.show_footer and real_footer_height > 0 then
		s.win_footer = api.nvim_open_win(s.buf_footer, false, {
			relative = "editor",
			width = s.width,
			height = real_footer_height,
			row = content_row + s.content_height,
			col = s._col,
			border = b_footer,
			style = "minimal",
			focusable = false,
			zindex = opts.zindex,
		})
	end

	pcall(require("lvim-utils.cursor").update)

	local normal_hl = hl_map["LvimUiNormal"] or "LvimUiNormal"
	local border_hl = hl_map["LvimUiBorder"] or "LvimUiBorder"
	api.nvim_set_option_value("wrap", false, { win = s.win })
	api.nvim_set_option_value("scrolloff", 0, { win = s.win })

	-- Mode files see a 0-based content buffer (no header/footer rows in s.buf).
	s.header_height = 0
	s.footer_height = 0

	-- ── render ────────────────────────────────────────────────────────────────

	local winhighlight_val = "Normal:" .. normal_hl .. ",NormalFloat:" .. normal_hl .. ",FloatBorder:" .. border_hl

	local function set_win_opts(win, wrap_val)
		if not api.nvim_win_is_valid(win) then
			return
		end
		api.nvim_set_option_value("number", false, { win = win })
		api.nvim_set_option_value("relativenumber", false, { win = win })
		api.nvim_set_option_value("signcolumn", "no", { win = win })
		api.nvim_set_option_value("cursorline", false, { win = win })
		api.nvim_set_option_value("cursorcolumn", false, { win = win })
		api.nvim_set_option_value("winblend", 0, { win = win })
		api.nvim_set_option_value("winhighlight", winhighlight_val, { win = win })
		api.nvim_set_option_value("wrap", wrap_val, { win = win })
		api.nvim_set_option_value("scrolloff", 0, { win = win })
	end

	local function render()
		-- ── build shared context ─────────────────────────────────────────────
		-- header_height = 0 so content.apply_hl uses 0-based row indices
		-- (matching the content buffer which starts at line 0).
		local ctx = {
			cfg = s_cfg,
			resolve_hl = resolve_hl,
			mode = s.mode,
			width = s.width,
			buf = s.buf,
			tabs = s.tabs,
			active_tab = s.active_tab,
			meta_lines = s.meta_lines,
			header_lines = s.header_lines,
			meta_offset = s.meta_offset,
			header_height = 0,
			title = s.title,
			subtitle = s.subtitle,
			info = s.info,
			title_hl = s.title_hl,
			subtitle_hl = s.subtitle_hl,
			info_hl = s.info_hl,
			content_height = s.content_height,
			scroll = s.scroll,
			row_cursor = s.row_cursor,
			selected = s.selected,
			current_item = current_item,
			current_idx = s.current_idx,
			horizontal_actions = s.horizontal_actions,
			action_bar_ht = s.action_bar_ht,
			placeholder = s.placeholder,
			items = cur_items(),
			rows = cur_rows(),
			has_rows = tab_has_rows(),
			content_rows = cur_content_rows(),
			action_rows = cur_action_rows(),
			info_highlights = s.info_highlights,
			info_readonly = s.info_readonly,
			back_key = s.back_key,
		}

		ctx.hints = opts.footer_hints
		if s.mode == "info" and s.info_keymaps then
			local extra = {}
			for lhs, v in pairs(s.info_keymaps) do
				if type(v) == "table" and type(v.label) == "string" then
					table.insert(extra, { key = lhs, label = v.label })
				end
			end
			if #extra > 0 then
				local base = ctx.hints or footer_mod.hints(ctx)
				ctx.hints = vim.list_extend(vim.list_extend({}, base), extra)
			end
		end

		-- ── header window ────────────────────────────────────────────────────
		if s.win_header and api.nvim_win_is_valid(s.win_header) then
			set_win_opts(s.win_header, false)
			api.nvim_buf_clear_namespace(s.buf_header, NS, 0, -1)
			local hdr_lines, tab_ranges, centered_offset = header_mod.build(ctx)
			vim.bo[s.buf_header].modifiable = true
			api.nvim_buf_set_lines(s.buf_header, 0, -1, false, hdr_lines)
			vim.bo[s.buf_header].modifiable = false
			header_mod.apply_hl(s.buf_header, ctx, tab_ranges, centered_offset)
		end

		-- ── content window ───────────────────────────────────────────────────
		set_win_opts(s.win, s.info_wrap or false)
		api.nvim_buf_clear_namespace(s.buf, NS, 0, -1)

		local cnt_lines, action_bar_ranges, action_bar_offset = content_mod.build(ctx)
		local info_editable = s.mode == "info" and not s.info_readonly
		local was_readonly = vim.bo[s.buf].readonly
		if was_readonly then
			vim.bo[s.buf].readonly = false
		end
		vim.bo[s.buf].modifiable = true
		api.nvim_buf_set_lines(s.buf, 0, -1, false, cnt_lines)
		vim.bo[s.buf].modifiable = (s.mode == "input") or info_editable
		if was_readonly then
			vim.bo[s.buf].readonly = true
		end

		content_mod.apply_hl(s.buf, ctx, action_bar_ranges, action_bar_offset)

		-- ── footer window ────────────────────────────────────────────────────
		if s.show_footer and s.win_footer and api.nvim_win_is_valid(s.win_footer) then
			set_win_opts(s.win_footer, false)
			api.nvim_buf_clear_namespace(s.buf_footer, NS, 0, -1)
			local ftr_lines, hint_ranges = footer_mod.build(ctx)
			vim.bo[s.buf_footer].modifiable = true
			api.nvim_buf_set_lines(s.buf_footer, 0, -1, false, ftr_lines)
			vim.bo[s.buf_footer].modifiable = false
			footer_mod.apply_hl(s.buf_footer, #ftr_lines, hint_ranges, ctx)
		end

		-- ── cursor positioning (0-based in content window) ───────────────────
		if not api.nvim_win_is_valid(s.win) then
			return
		end

		if s.mode == "input" then
			api.nvim_win_set_cursor(s.win, { 1, #s.placeholder + 2 })
		elseif s.mode == "info" then
			local line = s.info_line or 1
			local row_in_win = line - s.scroll
			local cur_col = 0
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			if ok then
				cur_col = pos[2]
			end
			pcall(api.nvim_win_set_cursor, s.win, { row_in_win, cur_col })
		elseif s.mode == "tabs" and tab_has_rows() then
			local cur_r = cur_rows()[s.row_cursor]
			local on_action = s.horizontal_actions and cur_r and cur_r.type == "action"
			if on_action then
				local bar_line = s.content_height + 1
				local seg_col = action_bar_offset
				for _, seg in ipairs(action_bar_ranges) do
					if seg.row_abs == s.row_cursor then
						seg_col = action_bar_offset + seg.s
						break
					end
				end
				api.nvim_win_set_cursor(s.win, { bar_line, seg_col })
			else
				local drows = s.horizontal_actions and cur_content_rows() or cur_rows()
				local cp = s.row_cursor
				if s.horizontal_actions then
					for ci, r in ipairs(drows) do
						if r == cur_r then
							cp = ci
							break
						end
					end
				end
				if cp >= s.scroll + 1 and cp <= s.scroll + s.content_height then
					api.nvim_win_set_cursor(s.win, { cp - s.scroll, 0 })
				else
					api.nvim_win_set_cursor(s.win, { 1, 0 })
				end
			end
		else
			local ci = cur_items()
			if #ci > 0 and s.current_idx >= s.scroll and s.current_idx < s.scroll + s.content_height then
				api.nvim_win_set_cursor(s.win, { (s.current_idx - s.scroll) + 1, 0 })
			else
				api.nvim_win_set_cursor(s.win, { 1, 0 })
			end
		end
	end

	-- ── close ─────────────────────────────────────────────────────────────────

	local closed = false
	local function close(confirmed, result)
		if closed then
			return
		end
		closed = true
		pcall(api.nvim_win_close, s.win, true)
		if s.win_header then
			pcall(api.nvim_win_close, s.win_header, true)
		end
		if s.win_footer then
			pcall(api.nvim_win_close, s.win_footer, true)
		end
		vim.schedule(function()
			if api.nvim_win_is_valid(saved_win) then
				api.nvim_win_call(saved_win, function()
					pcall(vim.fn.winrestview, saved_view)
				end)
			end
		end)
		callback(confirmed, result)
	end

	local function recalc_win_height()
		-- Only relevant for wrap mode.
		if not s.info_wrap then
			return
		end
		if not api.nvim_win_is_valid(s.win) then
			return
		end
		-- Measure actual rendered height of content rows.
		local ok, result = pcall(api.nvim_win_text_height, s.win, {
			start_row = 0,
			end_row = s.content_height - 1,
		})
		if not ok then
			return
		end
		local max_total = math.floor(vim.o.lines * s_cfg.max_height)
		local new_content = math.min(result.all, max_total - real_header_height - real_footer_height)
		new_content = math.max(1, new_content)
		api.nvim_win_set_height(s.win, new_content)
		s.content_height = new_content
		-- Reposition footer window to follow content height change.
		if s.win_footer and api.nvim_win_is_valid(s.win_footer) then
			local new_ftr_row = s._row + (has_header_win and (real_header_height + bro) or 0) + s.content_height
			api.nvim_win_set_config(s.win_footer, {
				relative = "editor",
				row = new_ftr_row,
				col = s._col,
				width = s.width,
				height = real_footer_height,
			})
		end
	end

	s.render = render
	s.close = close
	s.recalc_win_height = recalc_win_height
	s.ko = { buffer = s.buf, silent = true, nowait = true }

	-- Resize all three windows to a new width (used by input mode on text growth).
	s.sync_win_config = function()
		if api.nvim_win_is_valid(s.win) then
			api.nvim_win_set_config(s.win, { width = s.width })
		end
		if s.win_header and api.nvim_win_is_valid(s.win_header) then
			api.nvim_win_set_config(s.win_header, { width = s.width })
		end
		if s.win_footer and api.nvim_win_is_valid(s.win_footer) then
			api.nvim_win_set_config(s.win_footer, { width = s.width })
		end
	end

	-- Reposition and resize all three windows after s._row, s._col, s.content_height change.
	-- Called by tabs mode on tab switch (which may change content_height).
	s.sync_layout = function()
		local c_row = s._row + (has_header_win and (real_header_height + bro) or 0)
		if s.win_header and api.nvim_win_is_valid(s.win_header) then
			api.nvim_win_set_config(s.win_header, {
				relative = "editor",
				row = s._row,
				col = s._col,
				width = s.width,
				height = real_header_height,
			})
		end
		if api.nvim_win_is_valid(s.win) then
			api.nvim_win_set_config(s.win, {
				relative = "editor",
				row = c_row,
				col = s._col,
				width = s.width,
				height = s.content_height,
			})
		end
		if s.win_footer and api.nvim_win_is_valid(s.win_footer) then
			api.nvim_win_set_config(s.win_footer, {
				relative = "editor",
				row = c_row + s.content_height,
				col = s._col,
				width = s.width,
				height = real_footer_height,
			})
		end
	end

	-- ── initial scroll for tabs ───────────────────────────────────────────────

	if initial_row and mode == "tabs" and tab_has_rows() then
		local pos = s.row_cursor
		if s.horizontal_actions then
			local target = cur_rows()[s.row_cursor]
			for ci, r in ipairs(cur_content_rows()) do
				if r == target then
					pos = ci
					break
				end
			end
		end
		if pos > s.content_height then
			s.scroll = pos - s.content_height
		end
	end

	-- ── dispatch to mode ──────────────────────────────────────────────────────
	-- attach() must run before render() so that info mode's make_readonly()
	-- (which calls nvim_buf_set_lines to clear undo history) does not wipe
	-- the extmarks that render() applies.

	require("lvim-utils.ui.mode." .. mode).attach(s)

	render()

	if on_open then
		on_open(s.buf, s.win)
	end
	vim.cmd("redraw!")
end

return M
