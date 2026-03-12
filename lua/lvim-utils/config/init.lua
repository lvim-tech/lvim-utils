-- lua/lvim-utils/config/init.lua
-- Central configuration hub. Loads each module's default config from its
-- own file (config/ui.lua, config/cursor.lua, config/gx.lua) and exposes
-- them as live tables that modules read at call time.
-- setup() deep-merges user overrides into the live tables.

local M = {}

-- Load defaults as independent deep copies so modules can mutate them freely.
M.ui     = vim.deepcopy(require("lvim-utils.config.ui"))
M.cursor = vim.deepcopy(require("lvim-utils.config.cursor"))
M.gx     = vim.deepcopy(require("lvim-utils.config.gx"))

---Merge user-provided options into each module's config.
---@param opts? { ui?: table, cursor?: table, gx?: table }
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
end

return M
