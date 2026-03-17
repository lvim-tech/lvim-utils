-- lua/lvim-utils/init.lua
-- Entry point for lvim-utils. Exposes all sub-modules and provides a single
-- setup() call that configures every module from one options table.

local M = {}

M.config  = require("lvim-utils.config")
M.colors  = require("lvim-utils.colors")
M.cursor  = require("lvim-utils.cursor")
M.highlight = require("lvim-utils.highlight")
M.ui = require("lvim-utils.ui")
M.quit = require("lvim-utils.quit")
M.gx = require("lvim-utils.gx")
M.notify = require("lvim-utils.notify")

---Setup lvim-utils.
---@param opts? { highlights?: table<string, table>, colors?: table, ui?: table, cursor?: table, gx?: table, notify?: table }
function M.setup(opts)
	opts = opts or {}

	-- Colors first — other modules may read palette at require time.
	if opts.colors then
		M.colors.setup(opts.colors)
	end

	-- Merge all module configs first so each module reads updated values.
	M.config.setup({
		ui = opts.ui,
		cursor = opts.cursor,
		gx = opts.gx,
		notify = opts.notify,
	})

	if opts.highlights then
		M.highlight.register(opts.highlights, true)
	end

	M.highlight.setup()

	if opts.gx then
		M.gx.setup()
	end

	if opts.notify then
		M.notify.setup(opts.notify)
	end
end

return M
