-- lua/lvim-utils/notify/init.lua
-- Notification hub: intercepts vim.notify (and optionally print), routes
-- every message through a list of pluggable printers, and ships two
-- built-in printers:
--   "toast"   – one floating panel per severity level, stacked vertically
--   "history" – ring-buffer; browsable with M.history()
--
-- Works out-of-the-box after require() — no setup() call needed.

local M = {}

local api = vim.api
local hl = require("lvim-utils.highlight")
local levels = vim.log.levels
local NS = api.nvim_create_namespace("lvim_utils_notify")

-- ── level metadata ────────────────────────────────────────────────────────

-- Per-panel metadata: key → { icon_key, name, icon, hl, header_hl }
-- icon_key  – looked up in _cfg.icons and _cfg.level_names (built-in panels)
-- name      – explicit display name (overrides icon_key-based lookup when set)
-- icon      – explicit icon char (overrides _cfg.icons lookup when set)
-- hl        – highlight group for content lines
-- header_hl – highlight group for the header bar
-- Reverse map: vim.log.levels integer → icon_key string
local LEVEL_KEY = {
	[levels.TRACE] = "trace",
	[levels.DEBUG] = "debug",
	[levels.INFO] = "info",
	[levels.WARN] = "warn",
	[levels.ERROR] = "error",
}

local _panel_meta = {
	[levels.TRACE] = {
		icon_key = "trace",
		hl = "LvimNotifyDebug",
		header_hl = "LvimNotifyHeaderDebug",
		sep_hl = "LvimNotifySepDebug",
		title_hl = "LvimNotifyTitleDebug",
	},
	[levels.DEBUG] = {
		icon_key = "debug",
		hl = "LvimNotifyDebug",
		header_hl = "LvimNotifyHeaderDebug",
		sep_hl = "LvimNotifySepDebug",
		title_hl = "LvimNotifyTitleDebug",
	},
	[levels.INFO] = {
		icon_key = "info",
		hl = "LvimNotifyInfo",
		header_hl = "LvimNotifyHeaderInfo",
		sep_hl = "LvimNotifySepInfo",
		title_hl = "LvimNotifyTitleInfo",
	},
	[levels.WARN] = {
		icon_key = "warn",
		hl = "LvimNotifyWarn",
		header_hl = "LvimNotifyHeaderWarn",
		sep_hl = "LvimNotifySepWarn",
		title_hl = "LvimNotifyTitleWarn",
	},
	[levels.ERROR] = {
		icon_key = "error",
		hl = "LvimNotifyError",
		header_hl = "LvimNotifyHeaderError",
		sep_hl = "LvimNotifySepError",
		title_hl = "LvimNotifyTitleError",
	},
}

-- Bottom-to-top stacking order (ERROR closest to bottom edge)
-- Custom panels registered via M.register_panel() are prepended (shown highest).
local PANEL_ORDER = {
	levels.ERROR,
	levels.WARN,
	levels.INFO,
	levels.DEBUG,
	levels.TRACE,
}

-- ── runtime state ─────────────────────────────────────────────────────────

local _cfg = require("lvim-utils.config").notify
local _history = {}
local _printers = {}

-- One panel per level: _panels[level] = { win, buf, width, height, entries }
local _panels = {}

-- Named progress channels, each rendered as its own independent floating panel.
-- Registered via M.progress_register(id, opts); updated via M.progress_update(id, lines).
-- _prog_channels[id] = { name, icon, header_hl, lines, marks, natural_w, win, buf, height }
local _prog_channels = {}
-- Insertion order: first registered = lowest in the stack (closest to bottom edge).
local _prog_order = {}

-- ── helpers ───────────────────────────────────────────────────────────────

local function dw(s)
	return vim.fn.strdisplaywidth(tostring(s or ""))
end

local function wrap(text, limit)
	if limit <= 0 then
		return { tostring(text) }
	end
	local lines = {}
	for raw in tostring(text):gmatch("[^\n]+") do
		local line = ""
		for word in raw:gmatch("%S+") do
			local candidate = line == "" and word or (line .. " " .. word)
			if dw(candidate) > limit then
				if line ~= "" then
					table.insert(lines, line)
				end
				line = word
			else
				line = candidate
			end
		end
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return #lines > 0 and lines or { "" }
end

-- ── panel management ──────────────────────────────────────────────────────

local function _close_panel(level)
	local p = _panels[level]
	if not p then
		return
	end
	if api.nvim_win_is_valid(p.win) then
		api.nvim_win_close(p.win, true)
	end
	if api.nvim_buf_is_valid(p.buf) then
		api.nvim_buf_delete(p.buf, { force = true })
	end
	_panels[level] = nil
end

--- Reposition all open panels so they stack from bottom_margin upward.
--- Progress channels are at the bottom (in registration order); level panels stack above.
local function _restack()
	local offset = _cfg.bottom_margin or 2

	for _, id in ipairs(_prog_order) do
		local ch = _prog_channels[id]
		if ch and ch.win and api.nvim_win_is_valid(ch.win) then
			local win_row = math.max(0, vim.o.lines - offset - (ch.height or 1))
			api.nvim_win_set_config(ch.win, {
				relative = "editor",
				row = win_row,
				col = api.nvim_win_get_config(ch.win).col,
			})
			offset = offset + (ch.height or 1) + (_cfg.panel_gap or 1)
		end
	end

	for _, lvl in ipairs(PANEL_ORDER) do
		local p = _panels[lvl]
		if p and api.nvim_win_is_valid(p.win) then
			local win_row = math.max(0, vim.o.lines - offset - p.height)
			api.nvim_win_set_config(p.win, {
				relative = "editor",
				row = win_row,
				col = api.nvim_win_get_config(p.win).col,
			})
			offset = offset + p.height + (_cfg.panel_gap or 1)
		end
	end
end

local _rebuild_all -- forward declaration; defined after progress helpers

--- Rebuild one panel's buffer content at the given width. No restack.
local function _rebuild_panel(level, win_w)
	local p = _panels[level]
	if not p or #p.entries == 0 then
		return
	end

	p.width = win_w

	local cfg_icons = _cfg.icons or {}
	local cfg_names = _cfg.level_names or {}
	local meta = _panel_meta[level] or {}
	local icon_key = meta.icon_key or tostring(level)
	local pad_s = string.rep(" ", _cfg.padding or 1)
	local count = #p.entries
	local name = meta.name or cfg_names[icon_key] or icon_key
	local icon = meta.icon or cfg_icons[icon_key] or " "
	local header_hl = meta.header_hl or "LvimNotifyHeaderInfo"
	local sep_hl = meta.sep_hl or "LvimNotifySepInfo"
	if count > 1 then
		name = name .. "s"
	end

	local hdr = pad_s .. icon .. " " .. name
	local fill = win_w - dw(hdr)
	if fill > 0 then
		hdr = hdr .. string.rep(" ", fill)
	end

	local sep = string.rep(_cfg.separator or "─", win_w)

	local all_lines = { hdr }
	local row_offset = 1
	local col_marks = {}
	local sep_rows = {}

	for i, entry in ipairs(p.entries) do
		if i > 1 and _cfg.show_separator ~= false then
			table.insert(all_lines, sep)
			table.insert(sep_rows, row_offset)
			row_offset = row_offset + 1
		end
		for _, l in ipairs(entry.lines) do
			local lw = dw(l)
			table.insert(all_lines, lw < win_w and (l .. string.rep(" ", win_w - lw)) or l)
		end
		for _, m in ipairs(entry.marks) do
			table.insert(col_marks, { m[1] + row_offset, m[2], m[3], m[4] })
		end
		row_offset = row_offset + #entry.lines
	end

	local h = #all_lines
	local buf = p.buf
	local win = p.win
	local win_col = math.max(0, vim.o.columns - win_w - 1)

	api.nvim_set_option_value("modifiable", true, { buf = buf })
	api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
	api.nvim_set_option_value("modifiable", false, { buf = buf })

	api.nvim_buf_clear_namespace(buf, NS, 0, -1)

	api.nvim_buf_set_extmark(buf, NS, 0, 0, {
		end_col = #hdr,
		hl_group = header_hl,
		hl_eol = true,
		priority = 200,
	})

	for _, r in ipairs(sep_rows) do
		api.nvim_buf_set_extmark(buf, NS, r, 0, {
			end_col = #sep,
			hl_group = sep_hl,
			hl_eol = true,
			priority = 150,
		})
	end

	for _, m in ipairs(col_marks) do
		api.nvim_buf_set_extmark(buf, NS, m[1], m[2], {
			end_col = m[3],
			hl_group = m[4],
			priority = 150,
		})
	end

	if not api.nvim_win_is_valid(win) then
		return
	end
	p.height = h
	api.nvim_win_set_config(win, {
		relative = "editor",
		width = win_w,
		height = h,
		row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
		col = win_col,
	})
end

--- Global max natural_w across every notify entry and every progress channel.
local function _global_max_w()
	local w = _cfg.min_width or 36
	for _, p in pairs(_panels) do
		for _, e in ipairs(p.entries) do
			w = math.max(w, e.natural_w or 0)
		end
	end
	for _, ch in pairs(_prog_channels) do
		w = math.max(w, ch.natural_w or 0)
	end
	return w
end

--- Close empty panel for `level` if needed, then trigger a full uniform rebuild.
local function _rebuild(level)
	local p = _panels[level]
	if p and #p.entries == 0 then
		_close_panel(level)
	end
	_rebuild_all()
end

-- ── progress channels ─────────────────────────────────────────────────────

--- Render (or close) one named progress channel at the given width. No restack.
local function _render_prog_channel(id, win_w)
	local ch = _prog_channels[id]
	if not ch then
		return
	end

	if not ch.lines or #ch.lines == 0 then
		if ch.win and api.nvim_win_is_valid(ch.win) then
			api.nvim_win_close(ch.win, true)
		end
		if ch.buf and api.nvim_buf_is_valid(ch.buf) then
			api.nvim_buf_delete(ch.buf, { force = true })
		end
		ch.win = nil
		ch.buf = nil
		ch.height = nil
		return
	end

	local pad_s = string.rep(" ", _cfg.padding or 1)
	local hdr_icon = ch.icon or (_cfg.icons or {}).progress or "󰔟"
	local hdr_name = ch.name or tostring(id)
	local hdr_hl = ch.header_hl or "LvimNotifyHeaderInfo"
	local hdr_text = pad_s .. hdr_icon .. " " .. hdr_name
	local hdr_fill = win_w - dw(hdr_text)
	if hdr_fill > 0 then
		hdr_text = hdr_text .. string.rep(" ", hdr_fill)
	end

	-- col_marks format: { row, col_start, col_end_bytes, hl_group, hl_eol? }
	local all_lines = { hdr_text }
	local col_marks = { { 0, 0, #hdr_text, hdr_hl, true } }
	local row_offset = 1

	for _, l in ipairs(ch.lines) do
		local safe = l:gsub("\n", " ")
		local lw = dw(safe)
		table.insert(all_lines, lw < win_w and (safe .. string.rep(" ", win_w - lw)) or safe)
	end
	for _, m in ipairs(ch.marks or {}) do
		table.insert(col_marks, { row_offset + m[1], m[2], m[3], m[4] })
	end

	local h = #all_lines
	local win_col = math.max(0, vim.o.columns - win_w - 1)

	if not ch.win or not api.nvim_win_is_valid(ch.win) then
		local buf = api.nvim_create_buf(false, true)
		api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
		local win = api.nvim_open_win(buf, false, {
			relative = "editor",
			row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
			col = win_col,
			width = win_w,
			height = h,
			border = _cfg.border or "none",
			style = "minimal",
			focusable = false,
			zindex = math.max(1, (_cfg.zindex or 200) - 10),
		})
		api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
		ch.win = win
		ch.buf = buf
	end

	local buf = ch.buf
	api.nvim_set_option_value("modifiable", true, { buf = buf })
	api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
	api.nvim_set_option_value("modifiable", false, { buf = buf })

	api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for _, m in ipairs(col_marks) do
		api.nvim_buf_set_extmark(buf, NS, m[1], m[2], {
			end_col = m[3],
			hl_group = m[4],
			hl_eol = m[5] or false,
			priority = 150,
		})
	end

	ch.height = h
	if api.nvim_win_is_valid(ch.win) then
		api.nvim_win_set_config(ch.win, {
			relative = "editor",
			width = win_w,
			height = h,
			row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
			col = win_col,
		})
	end
end

--- Master rebuild: one global width for ALL panels (notify levels + progress channels).
_rebuild_all = function()
	local win_w = _global_max_w()
	for _, lvl in ipairs(PANEL_ORDER) do
		if _panels[lvl] then
			_rebuild_panel(lvl, win_w)
		end
	end
	for _, id in ipairs(_prog_order) do
		_render_prog_channel(id, win_w)
	end
	_restack()
	vim.schedule(function()
		vim.cmd("redraw!")
	end)
end

-- ── toast printer ─────────────────────────────────────────────────────────

local function _show_toast(msg, level, opts)
	opts = opts or {}
	level = level or levels.INFO
	msg = tostring(msg or "")

	local meta = _panel_meta[level] or {}
	local title_hl = meta.title_hl or "LvimNotifyTitleInfo"
	local title = opts.title and tostring(opts.title) or nil
	local pad = _cfg.padding or 1
	local pad_s = string.rep(" ", pad)
	local max_w = _cfg.max_width or 60
	local min_w = _cfg.min_width or 36

	local available = max_w - pad * 2
	local msg_lines = wrap(msg, available)

	-- Natural width: widest content line, clamped to [min_w, max_w].
	local inner_w = 0
	if title then
		inner_w = math.max(inner_w, dw(title))
	end
	for _, l in ipairs(msg_lines) do
		inner_w = math.max(inner_w, dw(l))
	end
	local natural_w = math.min(max_w, math.max(min_w, inner_w + pad * 2))

	local lines = {}
	local marks = {}
	local ri = 0

	local function push(str, ...)
		table.insert(lines, str)
		for _, m in ipairs({ ... }) do
			table.insert(marks, { ri, m[1], m[2], m[3] })
		end
		ri = ri + 1
	end

	if title then
		local s = pad_s .. title
		push(s, { pad, pad + dw(title), title_hl })
	end

	for _, mline in ipairs(msg_lines) do
		push(pad_s .. mline)
	end

	local entry = { lines = lines, marks = marks, natural_w = natural_w }

	-- Create panel for this level if needed.
	-- Initial width uses natural_w; _rebuild will widen it when more entries arrive.
	if not _panels[level] or not api.nvim_win_is_valid(_panels[level].win) then
		_panels[level] = nil
		local buf = api.nvim_create_buf(false, true)
		local win_col = math.max(0, vim.o.columns - natural_w - 1)
		api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
		local win = api.nvim_open_win(buf, false, {
			relative = "editor",
			row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - 2),
			col = win_col,
			width = natural_w,
			height = 1,
			border = _cfg.border or "none",
			style = "minimal",
			focusable = false,
			zindex = _cfg.zindex or 200,
		})
		api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
		_panels[level] = { win = win, buf = buf, width = natural_w, height = 1, entries = {} }
	end

	table.insert(_panels[level].entries, entry)
	_rebuild(level)

	local timeout = (opts.timeout ~= nil) and opts.timeout or (_cfg.timeout or 4000)
	if timeout > 0 then
		vim.defer_fn(function()
			local p = _panels[level]
			if not p then
				return
			end
			for i, e in ipairs(p.entries) do
				if e == entry then
					table.remove(p.entries, i)
					_rebuild(level)
					break
				end
			end
		end, timeout)
	end
end

-- ── history printer ────────────────────────────────────────────────────────

local function _append_history(msg, level, opts)
	table.insert(_history, {
		msg = tostring(msg or ""),
		level = level or levels.INFO,
		opts = opts or {},
		time = os.time(),
	})
	local max = _cfg.max_history or 100
	while #_history > max do
		table.remove(_history, 1)
	end
end

-- ── dispatch ───────────────────────────────────────────────────────────────

local _in_dispatch = false

local function _dispatch(msg, level, opts)
	if _in_dispatch then
		return
	end
	_in_dispatch = true
	for _, p in ipairs(_printers) do
		pcall(p.fn, msg, level, opts)
	end
	_in_dispatch = false
end

-- ── public API ─────────────────────────────────────────────────────────────

function M.add_printer(name, fn)
	M.remove_printer(name)
	table.insert(_printers, { name = name, fn = fn })
end

function M.remove_printer(name)
	for i, p in ipairs(_printers) do
		if p.name == name then
			table.remove(_printers, i)
			return
		end
	end
end

function M.has_printer(name)
	for _, p in ipairs(_printers) do
		if p.name == name then
			return true
		end
	end
	return false
end

function M.notify(msg, level, opts)
	_dispatch(msg, level, opts)
end
function M.get_history()
	return vim.deepcopy(_history)
end
function M.clear()
	_history = {}
end

--- Register a named progress channel with its own floating panel and appearance.
--- Safe to call multiple times; subsequent calls update appearance only.
---@param id   string  Unique channel identifier
---@param opts table   { name?: string, icon?: string, header_hl?: string }
function M.progress_register(id, opts)
	opts = opts or {}
	if not _prog_channels[id] then
		_prog_channels[id] = {}
		table.insert(_prog_order, id)
	end
	local ch = _prog_channels[id]
	if opts.name ~= nil then
		ch.name = opts.name
	end
	if opts.icon ~= nil then
		ch.icon = opts.icon
	end
	if opts.header_hl ~= nil then
		ch.header_hl = opts.header_hl
	end
end

--- Register a custom panel with a unique key, display name, and highlight groups.
--- The panel is stacked above all built-in severity panels by default.
---@param key  any     Unique identifier (string or integer) for the panel
---@param opts table   { name: string, icon: string, hl: string, header_hl: string, order?: integer }
function M.register_panel(key, opts)
	opts = opts or {}
	_panel_meta[key] = {
		name = opts.name,
		icon = opts.icon,
		hl = opts.hl or "LvimNotifyInfo",
		header_hl = opts.header_hl or "LvimNotifyHeaderInfo",
	}
	-- Remove any existing position for this key, then insert at requested order.
	for i, k in ipairs(PANEL_ORDER) do
		if k == key then
			table.remove(PANEL_ORDER, i)
			break
		end
	end
	table.insert(PANEL_ORDER, opts.order or 1, key)
end

--- Push a message directly to a named panel (built-in or custom).
--- Accepts the same opts as vim.notify (title, timeout, …).
---@param key  any     Panel key passed to M.register_panel, or a vim.log.levels value
---@param msg  string
---@param opts table|nil
function M.push(key, msg, opts)
	_show_toast(msg, key, opts)
end

--- Update content for a named progress channel (auto-registers if unknown).
---@param id    string
---@param lines string[]
---@param marks table[]|nil  { row, col_start, col_end, hl_group } (row 0-based within lines)
function M.progress_update(id, lines, marks)
	if not _prog_channels[id] then
		_prog_channels[id] = {}
		table.insert(_prog_order, id)
	end
	local ch = _prog_channels[id]
	ch.lines = lines
	ch.marks = marks or {}
	local min_w = _cfg.min_width or 36
	local max_w = _cfg.max_width or 60
	local nw = min_w
	for _, l in ipairs(lines) do
		nw = math.max(nw, dw(l))
	end
	ch.natural_w = math.min(max_w, nw + (_cfg.padding or 1) * 2)
	_rebuild_all()
end

--- Clear content for a named progress channel and close its panel.
---@param id string
function M.progress_clear(id)
	local ch = _prog_channels[id]
	if not ch then
		return
	end
	ch.lines = nil
	ch.marks = nil
	ch.natural_w = nil
	_rebuild_all()
end

--- Clear all progress channels and close all their panels.
function M.progress_clear_all()
	for _, ch in pairs(_prog_channels) do
		ch.lines = nil
		ch.marks = nil
		ch.natural_w = nil
	end
	_rebuild_all()
end

-- ── history window ────────────────────────────────────────────────────────

local _hist_NS = api.nvim_create_namespace("lvim_utils_notify_history")

--- Build lines + highlights for the history popup. Returns them without touching any buffer.
local function _history_build(filter)
	local lines = {}
	local highlights = {} -- { line, col_start, col_end, group }

	local function push_hl(group, col_s, col_e)
		table.insert(highlights, { line = #lines - 1, col_start = col_s, col_end = col_e, group = group })
	end

	local function push_header(label)
		local text = "  " .. label
		table.insert(lines, text)
		push_hl("LvimUiTitle", 0, #text)
	end

	-- notifications
	for i = #_history, 1, -1 do
		local item = _history[i]
		if not filter or filter == (LEVEL_KEY[item.level] or "info") then
			local key = LEVEL_KEY[item.level] or "info"
			local meta = _panel_meta[item.level] or {}
			local icon = (_cfg.icons or {})[key] or " "
			local ts = os.date("%H:%M:%S", item.time) --[[@as string]]
			local title = item.opts and item.opts.title
			local pre = title and ("[" .. title .. "] ") or ""
			local icon_s = 3
			local icon_e = icon_s + #icon
			local ts_s = icon_e + 2
			local msg_flat = item.msg:gsub("\n", " ")
			table.insert(lines, "   " .. icon .. "  " .. ts .. "  " .. pre .. msg_flat)
			push_hl(meta.title_hl or "LvimNotifyInfo", icon_s, icon_e)
			push_hl("LvimUiFooterLabel", ts_s, ts_s + #ts)
		end
	end

	return lines, highlights
end

--- Write pre-built lines + highlights into buf.
local function _history_write(buf, lines, highlights)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	api.nvim_buf_clear_namespace(buf, _hist_NS, 0, -1)
	for _, m in ipairs(highlights) do
		api.nvim_buf_set_extmark(buf, _hist_NS, m.line, m.col_start, {
			end_col = m.col_end,
			hl_group = m.group,
			priority = 100,
		})
	end
end

local _lvl_map = { i = "info", w = "warn", e = "error", d = "debug" }
local _lvl_labels = { i = "Info", w = "Warn", e = "Error", d = "Debug" }

function M.history()
	if #_history == 0 then
		M.push(vim.log.levels.INFO, "No notifications")
		return
	end

	local ui = require("lvim-utils.ui")
	local filter = nil
	local buf_ref ---@type integer

	local function rerender()
		if buf_ref and api.nvim_buf_is_valid(buf_ref) then
			local lines, hls = _history_build(filter)
			_history_write(buf_ref, lines, hls)
		end
	end

	local lines, hls = _history_build(filter)

	local keymaps = {
		r = { fn = rerender, label = "Refresh" },
	}
	for key, lvl in pairs(_lvl_map) do
		local lbl = _lvl_labels[key]
		keymaps[key] = {
			fn = function()
				filter = filter == lvl and nil or lvl
				rerender()
			end,
			label = lbl,
		}
	end

	ui.info(lines, {
		title = " Notifications",
		highlights = hls,
		keymaps = keymaps,
		hide_cursor = false,
		on_open = function(b, _)
			buf_ref = b
		end,
	})
end

-- ── ext_messages (vim.ui_attach) ──────────────────────────────────────────

-- Map message kind → vim.log.levels
local _KIND_LEVEL = {
	emsg = levels.ERROR,
	echoerr = levels.ERROR,
	lua_error = levels.ERROR,
	rpc_error = levels.ERROR,
	shell_err = levels.ERROR,
	wmsg = levels.WARN,
	echomsg = levels.INFO,
	echo = levels.INFO,
	[""] = levels.INFO,
	bufwrite = levels.INFO,
	undo = levels.INFO,
	shell_out = levels.DEBUG,
	lua_print = levels.DEBUG,
	verbose = levels.DEBUG,
}

--- Convert content fragments [{attr_id, text}, …] to a plain string.
local function _fragments_to_text(content)
	local parts = {}
	for _, frag in ipairs(content) do
		table.insert(parts, frag[2] or "")
	end
	return vim.trim(table.concat(parts))
end

local _in_ext = false
local _ui_attached = false
local _dedup_last = {} -- [text] = uv_hrtime of last dispatch
local _DEDUP_WINDOW = 500 -- ms — same text within this window is dropped

local function _dedup_check(text)
	local now = vim.uv.hrtime() / 1e6 -- ms
	local last = _dedup_last[text]
	if last and (now - last) < _DEDUP_WINDOW then
		return true
	end
	_dedup_last[text] = now
	-- keep table small
	if vim.tbl_count(_dedup_last) > 50 then
		local oldest, oldest_key = math.huge, nil
		for k, t in pairs(_dedup_last) do
			if t < oldest then
				oldest, oldest_key = t, k
			end
		end
		if oldest_key then
			_dedup_last[oldest_key] = nil
		end
	end
	return false
end

local function _attach_ui()
	if _ui_attached then
		return
	end
	_ui_attached = true

	local ns = api.nvim_create_namespace("lvim_utils_ext_messages")

	vim.ui_attach(ns, { ext_messages = true }, function(event, ...)
		if event == "msg_show" then
			local kind, content, _replace = ...

			-- capture args before scheduling (varargs don't survive yield)
			local text_raw = _fragments_to_text(content)

			if kind == "return_prompt" then
				vim.schedule(function()
					api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
				end)
				return
			end

			local behaviour = (_cfg.ext_kinds or {})[kind] or "history"
			if behaviour == "ignore" then
				return
			end

			vim.schedule(function()
				if _in_ext or _in_dispatch then
					return
				end
				_in_ext = true
				local ok, err = pcall(function()
					local text = vim.trim(text_raw)
					if text == "" then
						return
					end
					if _dedup_check(text) then
						return
					end

					local lvl = _KIND_LEVEL[kind] or levels.INFO
					local timeout = (lvl == levels.INFO or lvl == levels.DEBUG) and (_cfg.ext_echo_timeout or 3000)
						or (_cfg.timeout or 5000)

					_append_history(text, lvl, {})

					if behaviour == "toast" then
						_show_toast(text, lvl, { timeout = timeout })
					end
				end)
				_in_ext = false
				if not ok then
					io.stderr:write("[lvim-utils.notify] ext handler error: " .. tostring(err) .. "\n")
				end
			end)
		end
	end)
end

local _initialized = false

function M.setup(user_cfg)
	user_cfg = user_cfg or {}
	_cfg = vim.tbl_deep_extend("force", _cfg, user_cfg)

	-- Register highlight groups on first setup.
	if not _initialized then
		local colors = require("lvim-utils.config").colors
		local nc = {}
		for name, opts in pairs(colors) do
			if name:match("^LvimNotify") then
				nc[name] = opts
			end
		end
		hl.register(nc, true)
	end

	-- Build printer list: explicit printers list replaces defaults;
	-- otherwise ensure toast + history are present on first call.
	if user_cfg.printers then
		_printers = {}
		for _, p in ipairs(user_cfg.printers) do
			if p == "toast" then
				M.add_printer("toast", _show_toast)
			elseif p == "history" then
				M.add_printer("history", _append_history)
			elseif type(p) == "function" then
				M.add_printer(tostring(p), p)
			elseif type(p) == "table" and p.fn then
				M.add_printer(p.name or tostring(p), p.fn)
			end
		end
		if not M.has_printer("history") then
			M.add_printer("history", _append_history)
		end
	elseif not _initialized then
		M.add_printer("toast", _show_toast)
		M.add_printer("history", _append_history)
	end

	-- Intercept vim.notify on first setup.
	if not _initialized then
		vim.notify = function(msg, level, opts)
			_dispatch(msg, level, opts)
		end ---@diagnostic disable-line: duplicate-set-field
	end

	if _cfg.override_print then
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring(select(i, ...)))
			end
			_dispatch(table.concat(parts, "\t"), levels.DEBUG, { title = "print" })
		end
	end

	if _cfg.ext_messages then
		_attach_ui()
	end

	_initialized = true
end

return M
