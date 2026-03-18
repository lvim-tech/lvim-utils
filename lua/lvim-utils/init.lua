-- lua/lvim-utils/init.lua
-- Entry point for lvim-utils. Exposes all sub-modules and provides a single
-- setup() call that configures every module from one options table.

local M = {}

M.config = require("lvim-utils.config")
M.colors = require("lvim-utils.colors")
M.cursor = require("lvim-utils.cursor")
M.highlight = require("lvim-utils.highlight")
M.ui = require("lvim-utils.ui")
M.quit = require("lvim-utils.quit")
M.gx = require("lvim-utils.gx")
M.notify = require("lvim-utils.notify")

---Setup lvim-utils.
---@param opts? { highlights?: table<string, table>, colors?: table, ui?: table, cursor?: table, gx?: table, notify?: table }
function M.setup(opts)
	opts = opts or {}

	-- 1. Palette overrides first — other modules read colors after this.
	if opts.colors then
		M.colors.setup(opts.colors)
	end

	-- 2. Merge module configs so each module reads updated values.
	M.config.setup({
		ui = opts.ui,
		cursor = opts.cursor,
		gx = opts.gx,
		notify = opts.notify,
	})

	-- 3. Register UI highlight groups from the fully-configured palette,
	--    then install the ColorScheme autocmd that re-applies them.
	M.highlight.register(M.config.colors, true)
	if opts.highlights then
		M.highlight.register(opts.highlights, true)
	end
	M.highlight.setup()

	-- 4. Activate palette sync from lvim-colorscheme (idempotent).
	M.colors._activate()

	if opts.cursor then
		M.cursor.setup(opts.cursor)
	end

	if opts.gx then
		M.gx.setup()
	end

	-- notify = false opts out entirely; any other value (including nil) activates with defaults.
	if opts.notify ~= false then
		M.notify.setup(opts.notify or {})
	end
end

return M
