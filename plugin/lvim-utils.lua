-- lvim-utils plugin guard.
-- Nothing auto-runs; lvim-utils is a library driven via require("lvim-utils").
-- This file exists so the plugin manager recognises the plugin.
if vim.g.loaded_lvim_utils then
	return
end
vim.g.loaded_lvim_utils = true
