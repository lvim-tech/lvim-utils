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

    -- message area (the segment zone)
    if cfg_ok and cfg.msgarea and cfg.msgarea.enable then
        ok("message area enabled (unified cmdline: " .. tostring(cfg.msgarea.unified == true) .. ")")
        info("msgarea renders via ui.surface (position = cmdline)")
        local ints = {}
        for name, on in pairs(cfg.msgarea.integrations or {}) do
            if on then
                ints[#ints + 1] = name
            end
        end
        info("msgarea integrations: " .. (next(ints) and table.concat(ints, ", ") or "none"))
        local ma_ok, ma = pcall(require, "lvim-utils.msgarea")
        if ma_ok and ma.segments then
            local names = vim.tbl_keys(ma.segments())
            if #names > 0 then
                info("msgarea segments: " .. table.concat(names, ", "))
            end
        end
    end

    -- picker / finder backends
    local function has(bin)
        return vim.fn.executable(bin) == 1
    end
    -- the LISTING engine for files / directories (config.picker.source.engine, default auto)
    local engine
    for _, c in ipairs({ "fd", "fdfind", "rg", "find" }) do
        if has(c) then
            engine = c
            break
        end
    end
    if engine then
        ok("finder listing engine: " .. engine .. (engine == "find" and " (no .gitignore support)" or ""))
    else
        warn("no file-listing tool found (fd / rg / find) — the files/directories finders cannot list")
    end
    if has("rg") then
        ok("ripgrep present — the grep finder is available")
    else
        info("ripgrep (rg) not found — the grep finder is disabled")
    end
    -- the fzf-TUI render backend for the heavy finders (config.picker.fzf_tui)
    local fzf_tui = not (cfg_ok and cfg.picker and cfg.picker.fzf_tui == false)
    if not fzf_tui then
        info("picker.fzf_tui = false — the heavy finders use the Lua tint list")
    elseif has("fzf") and has("mkfifo") then
        ok("fzf-TUI finder backend active (fzf + mkfifo present) — instant over huge trees")
    elseif has("fzf") then
        warn("fzf present but `mkfifo` is not — the heavy finders fall back to the tint list", {
            "mkfifo is part of coreutils; install it to enable the fzf-TUI backend",
        })
    else
        info("fzf not found — the heavy finders use the Lua tint list (fzf --filter ranking when available)")
    end
end

return M
