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
--   M.tabs(opts)          – tabbed view with typed rows or simple item lists
--   M.info(content, opts) – read-only markdown/text info window
--   M.close_info(win)     – programmatically close an info window

local hl     = require("lvim-utils.highlight")
local colors = require("lvim-utils.config").colors
local popup  = require("lvim-utils.ui.popup")
local info   = require("lvim-utils.ui.info")

local M = {}

-- Register with force=false so:
--   • colorscheme-defined LvimUi* groups take precedence (define_if_missing)
--   • setup({ highlights = {} }) with force=true overrides everything
--   • M.new({ highlights = {} }) overrides per-instance at call time
-- force=true: always apply on load — colorscheme's highlight clear cannot leave
-- LvimUi* groups undefined. setup({ highlights }) also uses force=true, so it
-- still wins. M.new({ highlights }) overrides per-instance at call time.
hl.register(colors, true)
-- Survive :colorscheme changes (safe to call multiple times).
hl.setup()

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

--- callback(confirmed, result)
--- result = { tab, index, item } for simple tabs
--- result = table<name, value>   for typed-row tabs
--- on_change(row) called on every value change
---@param opts UiOpts
function M.tabs(opts)
	opts.mode = "tabs"
	popup.open(opts)
end

M.info       = info.info
M.close_info = info.close_info

--- Create an independent UI instance with its own config overrides.
--- Useful when multiple plugins share lvim-utils but need different colours/icons.
---
---@param instance_cfg table  Any subset of the ui config + highlights table.
---   highlights = { LvimUiTitle = { fg = "#..." }, ... }  -- per-instance hl overrides
---   icons      = { bool_on = "X", ... }                  -- per-instance icons
---   keys       = { ... }                                  -- per-instance keymaps
---   labels     = { ... }                                  -- per-instance labels
---@return { select: fun(opts: table), multiselect: fun(opts: table),
---          input: fun(opts: table), tabs: fun(opts: table) }
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

	function inst.tabs(opts)
		opts.mode = "tabs"
		popup.open(opts, instance_cfg)
	end

	return inst
end

return M
