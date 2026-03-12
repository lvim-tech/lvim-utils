-- lua/lvim-utils/highlight/init.lua
-- Dynamic highlight group registration that survives colorscheme changes.
-- Groups registered here are re-applied automatically on every ColorScheme event.
--
-- Public API:
--   M.register(groups, force?) – register and immediately apply highlight groups
--   M.setup()                  – install the ColorScheme autocmd (call once)

local M = {}

--- Internal registry: name → opts table for all registered groups.
---@type table<string, table>
local registry = {}

--- Apply a highlight group only when the colorscheme has not already defined it.
--- This preserves user-set overrides while ensuring defaults exist.
---@param name string
---@param opts table
local function define_if_missing(name, opts)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl or vim.tbl_isempty(hl) then
    vim.api.nvim_set_hl(0, name, opts)
  end
end

--- Re-apply all registered highlight groups. Called on ColorScheme events.
local function apply_all()
  for name, opts in pairs(registry) do
    define_if_missing(name, opts)
  end
end

---Register highlight groups and apply them immediately.
---Can be called multiple times from different modules.
---@param groups table<string, table>
---@param force? boolean  Always apply, even if the group already exists (user overrides)
function M.register(groups, force)
  for name, opts in pairs(groups) do
    registry[name] = opts
    if force then
      vim.api.nvim_set_hl(0, name, opts)
    else
      define_if_missing(name, opts)
    end
  end
end

---Set up the ColorScheme autocmd so groups survive theme changes.
---Call once during plugin initialisation.
function M.setup()
  local aug = vim.api.nvim_create_augroup("LvimUtilsHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = aug,
    callback = apply_all,
    desc     = "Re-apply lvim-utils highlight groups after colorscheme change",
  })
end

return M
