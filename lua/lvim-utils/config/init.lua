-- lua/lvim-utils/config/init.lua
-- Central configuration hub. Loads each module's default config from its
-- own file (config/ui.lua, config/cursor.lua, config/gx.lua) and exposes
-- them as live tables that modules read at call time.
-- setup() deep-merges user overrides into the live tables.

local M = {}

-- Load defaults as independent deep copies so modules can mutate them freely.
local _hl_factory = require("lvim-utils.config.highlight")
M.colors = vim.deepcopy(_hl_factory())
M.ui = vim.deepcopy(require("lvim-utils.config.ui"))
M.cursor = vim.deepcopy(require("lvim-utils.config.cursor"))
M.gx = vim.deepcopy(require("lvim-utils.config.gx"))
M.notify = vim.deepcopy(require("lvim-utils.config.notify"))
M.cmdline = vim.deepcopy(require("lvim-utils.config.cmdline"))
M.input = vim.deepcopy(require("lvim-utils.config.input"))

---Merge user-provided options into each module's config.
---@param opts? { ui?: table, cursor?: table, gx?: table, notify?: table, cmdline?: table, input?: table }
function M.setup(opts)
	opts = opts or {}
	if opts.ui then
		M.ui = vim.tbl_deep_extend("force", M.ui, opts.ui)
	end
	if opts.cursor then
		M.cursor = vim.tbl_deep_extend("force", M.cursor, opts.cursor)
	end
	if opts.gx then
		M.gx = vim.tbl_deep_extend("force", M.gx, opts.gx)
	end
	if opts.notify then
		M.notify = vim.tbl_deep_extend("force", M.notify, opts.notify)
	end
	if opts.cmdline then
		M.cmdline = vim.tbl_deep_extend("force", M.cmdline, opts.cmdline)
	end
	if opts.input then
		M.input = vim.tbl_deep_extend("force", M.input, opts.input)
	end
end

--- Rebuild the UI/notify highlight group map from the live palette and publish it as
--- `M.colors` for readers. Bound via `highlight.bind` in setup() so the groups self-theme:
--- applied with `default = true` and re-applied automatically on palette change.
---@param colors? table  the live palette (passed by highlight.bind)
---@return table<string, table>
function M.rebuild_highlights(colors)
	M.colors = _hl_factory(colors)
	return M.colors
end

return M
