-- lvim-utils.health: `:checkhealth lvim-utils` — verifies the environment the BASE relies on: truecolor,
-- Neovim version, palette sync from lvim-colorscheme, and the self-themed group map. The former module checks
-- (cmdline / msgarea / picker / dashboard / …) now live in each split plugin's own `:checkhealth`.
---@module "lvim-utils.health"

local M = {}

local health = vim.health

--- Run the health checks.
function M.check()
    health.start("lvim-utils")

    -- Neovim version
    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.warn("Neovim 0.12+ required")
    end

    -- truecolor
    if vim.o.termguicolors then
        health.ok("'termguicolors' is set (required for the themed UI)")
    else
        health.warn("'termguicolors' is off — popup/notify colors will not render", {
            "set termguicolors",
        })
    end

    -- palette source
    local has_lcs = pcall(require, "lvim-colorscheme")
    if has_lcs then
        health.ok("lvim-colorscheme present — palette syncs from the active theme")
    else
        health.info("lvim-colorscheme not found — using the bundled muted palette (still works)")
    end

    -- self-themed group map present (the central factory every split plugin reads by name)
    local hl = vim.api.nvim_get_hl(0, { name = "LvimUiNormal" })
    if hl and not vim.tbl_isempty(hl) then
        health.ok("highlight group map is themed (LvimUiNormal defined)")
    else
        health.info("highlight groups not applied yet — call require('lvim-utils').setup()")
    end
end

return M
