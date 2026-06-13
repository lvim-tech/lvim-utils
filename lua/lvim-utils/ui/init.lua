-- lua/lvim-utils/ui/init.lua
-- Public API for lvim-utils floating UI components.
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
--   M.select(opts)        – pick one item from a list
--   M.multiselect(opts)   – pick multiple items
--   M.input(opts)         – free-text input field
--   M.confirm(opts)       – yes/no dialog → callback(yes: boolean)
--   M.tabs(opts)          – tabbed view with typed rows or simple item lists
--   M.info(content, opts) – read-only markdown/text info window
--   M.close_info(win)     – programmatically close an info window

local hl = require("lvim-utils.highlight")
local colors = require("lvim-utils.config").colors
local popup = require("lvim-utils.ui.popup")

local M = {}

--- callback(confirmed, index)
---@param opts UiOpts
function M.select(opts)
	opts.mode = "select"
	popup.open(opts)
end

--- callback(confirmed, table<string, boolean>)
---@param opts UiOpts
function M.multiselect(opts)
	opts.mode = "multiselect"
	popup.open(opts)
end

--- callback(confirmed, string)
---@param opts UiOpts
function M.input(opts)
	opts.mode = "input"
	popup.open(opts)
end

--- Yes/no confirmation dialog (a two-item select). The default choice is listed first so
--- it is focused on open; cancelling (<Esc>) resolves to `false`.
---@param opts { prompt?: string, title?: string, yes?: string, no?: string, default_no?: boolean, callback: fun(yes: boolean) }
function M.confirm(opts, instance_cfg)
	opts = opts or {}
	local yes_label, no_label = opts.yes or "Yes", opts.no or "No"
	local items = opts.default_no and { no_label, yes_label } or { yes_label, no_label }
	local cb = opts.callback or function() end
	popup.open({
		mode = "select",
		title = opts.title or opts.prompt or " Confirm",
		items = items,
		callback = function(confirmed, index)
			cb(confirmed == true and items[index] == yes_label)
		end,
	}, instance_cfg)
end

--- callback(confirmed, result)
--- result = { tab, index, item } for simple tabs
--- result = table<name, value>   for typed-row tabs
--- on_change(row) called on every value change
---@param opts UiOpts
function M.tabs(opts)
	opts.mode = "tabs"
	return popup.open(opts)
end

--- Opens an info window through popup.open() with mode="info".
---@param content string|string[]
---@param opts?   table
---@return integer buf, integer win
function M.info(content, opts)
	opts = opts or {}
	local lines = type(content) == "string" and vim.split(content, "\n")
		or (type(content) == "table" and vim.list_extend({}, content) or {})
	local buf_ref, win_ref
	local user_on_open = opts.on_open
	opts.mode = "info"
	opts.content = lines
	opts.on_open = function(b, w)
		buf_ref = b
		win_ref = w
		if user_on_open then
			user_on_open(b, w)
		end
	end
	popup.open(opts)
	return buf_ref, win_ref
end

--- Programmatically close an info window.
---@param win integer
function M.close_info(win)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

--- Create an independent UI instance with its own config overrides.
--- Useful when multiple plugins share lvim-utils but need different colours/icons.
---
---@param instance_cfg table  Any subset of the ui config + highlights table.
---   highlights = { LvimUiTitle = { fg = "#..." }, ... }  -- per-instance hl overrides
---   icons      = { bool_on = "X", ... }                  -- per-instance icons
---   keys       = { ... }                                  -- per-instance keymaps
---   labels     = { ... }                                  -- per-instance labels
---@return { select: fun(opts: table), multiselect: fun(opts: table),
---          input: fun(opts: table), tabs: fun(opts: table),
---          info: fun(content: any, opts: table): integer, integer }
function M.new(instance_cfg)
	local inst = {}

	function inst.select(opts)
		opts.mode = "select"
		popup.open(opts, instance_cfg)
	end

	function inst.multiselect(opts)
		opts.mode = "multiselect"
		popup.open(opts, instance_cfg)
	end

	function inst.input(opts)
		opts.mode = "input"
		popup.open(opts, instance_cfg)
	end

	function inst.confirm(opts)
		M.confirm(opts, instance_cfg)
	end

	function inst.tabs(opts)
		opts.mode = "tabs"
		return popup.open(opts, instance_cfg)
	end

	function inst.info(content, opts)
		opts = opts or {}
		local lines = type(content) == "string" and vim.split(content, "\n")
			or (type(content) == "table" and vim.list_extend({}, content) or {})
		local buf_ref, win_ref
		local user_on_open = opts.on_open
		opts.mode = "info"
		opts.content = lines
		opts.on_open = function(b, w)
			buf_ref = b
			win_ref = w
			if user_on_open then
				user_on_open(b, w)
			end
		end
		popup.open(opts, instance_cfg)
		return buf_ref, win_ref
	end

	return inst
end

return M
