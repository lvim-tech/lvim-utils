-- lua/lvim-utils/health.lua
-- `:checkhealth lvim-utils` — verifies the environment lvim-utils relies on: truecolor,
-- Neovim version, palette sync from lvim-colorscheme, self-themed UI groups, and possible
-- ext_cmdline conflicts.
---@module "lvim-utils.health"

local M = {}

local health = vim.health
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local info = health.info or health.report_info

--- Run the health checks.
function M.check()
    start("lvim-utils")

    -- Neovim version
    if vim.fn.has("nvim-0.10") == 1 then
        ok("Neovim " .. tostring(vim.version()))
    else
        warn("Neovim 0.10+ recommended (uses vim.uv, nvim_get_hl link=false, extmark cols)")
    end

    -- truecolor
    if vim.o.termguicolors then
        ok("'termguicolors' is set (required for the themed UI)")
    else
        warn("'termguicolors' is off — popup/notify colors will not render", {
            "set termguicolors",
        })
    end

    -- palette source
    local has_lcs = pcall(require, "lvim-colorscheme")
    if has_lcs then
        ok("lvim-colorscheme present — palette syncs from the active theme")
    else
        info("lvim-colorscheme not found — using the bundled muted palette (still works)")
    end

    -- self-themed UI groups present
    local hl = vim.api.nvim_get_hl(0, { name = "LvimUiNormal" })
    if hl and not vim.tbl_isempty(hl) then
        ok("UI highlight groups are themed (LvimUiNormal defined)")
    else
        info("UI highlight groups not applied yet — call require('lvim-utils').setup()")
    end

    -- ext_cmdline conflict (only relevant when the self-rendered cmdline is enabled)
    local cfg_ok, cfg = pcall(require, "lvim-utils.config")
    if cfg_ok and cfg.cmdline and cfg.cmdline.enable then
        if package.loaded["noice"] then
            warn("noice.nvim is loaded — both render ext_cmdline; expect conflicts", {
                "disable lvim-utils cmdline, or disable noice's cmdline",
            })
        else
            ok("self-rendered cmdline enabled, no competing ext_cmdline provider detected")
        end
    end
end

return M
