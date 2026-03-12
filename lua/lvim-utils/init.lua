-- lua/lvim-utils/init.lua
-- Entry point for lvim-utils. Exposes all sub-modules and provides a single
-- setup() call that configures every module from one options table.

local M = {}

M.config    = require("lvim-utils.config")
M.cursor    = require("lvim-utils.cursor")
M.highlight = require("lvim-utils.highlight")
M.ui        = require("lvim-utils.ui")
M.quit      = require("lvim-utils.quit")
M.gx        = require("lvim-utils.gx")

---Setup lvim-utils.
---@param opts? { highlights?: table<string, table>, ui?: table, cursor?: table, gx?: table }
function M.setup(opts)
  opts = opts or {}

  -- Merge all module configs first so each module reads updated values.
  M.config.setup({
    ui     = opts.ui,
    cursor = opts.cursor,
    gx     = opts.gx,
  })

  if opts.highlights then
    M.highlight.register(opts.highlights, true)
  end

  M.highlight.setup()

  if opts.gx then
    M.gx.setup()
  end
end

return M
