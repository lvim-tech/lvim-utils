-- lvim-utils: the BASE plugin of the lvim-tech set — the shared foundation every other plugin builds on:
--   • utils      — the shared helpers (merge, match_indices, …)
--   • colors     — the live palette (synced from lvim-colorscheme)
--   • highlight  — the group registrar (define / bind / self-theming on ColorScheme)
--   • cursor     — the canonical cursor-hide mechanism (by registered filetype)
--   • config     — the central highlight-group factory (read BY NAME by every split plugin) + the cursor config
--
-- `setup()` configures ONLY the base: it merges the palette + cursor overrides, self-themes the group map from
-- the fully-configured palette, and registers the cursor filetypes. Everything else (ui / picker / hud /
-- msgarea / image / dashboard / common) is its own plugin now — configure them via `require("<plugin>").setup()`
-- (or all at once through `require("lvim-nvim").setup({ ["lvim-<plugin>"] = {…} })`).
--
---@module "lvim-utils"

local M = {}

M.config = require("lvim-utils.config")
M.colors = require("lvim-utils.colors")
M.cursor = require("lvim-utils.cursor")
M.highlight = require("lvim-utils.highlight")

---Setup the base (lvim-utils). Only the palette + cursor + the self-themed group map are configured here.
---@param opts? { highlights?: table<string, table>, colors?: table, cursor?: table }
function M.setup(opts)
    opts = opts or {}

    -- 1. Palette overrides first — the highlight factory + every other module reads colors after this.
    if opts.colors then
        M.colors.setup(opts.colors)
    end

    -- 2. Merge the base config (cursor) so it reads the updated values.
    M.config.setup({ cursor = opts.cursor })

    -- 3. Self-theme the group map from the fully-configured palette via bind(): applied with `default = true`
    --    so a non-lvim colorscheme (or the user) can override, and re-applied automatically on palette /
    --    ColorScheme change. An explicit user `highlights` override applies hard (force). Then install the
    --    ColorScheme autocmd.
    M.highlight.bind(M.config.rebuild_highlights)
    if opts.highlights then
        M.highlight.register(opts.highlights, true)
    end
    M.highlight.setup()

    -- 4. Activate palette sync from lvim-colorscheme (idempotent).
    M.colors._activate()

    -- 5. cursor: pass the LIVE merged config (config.setup already merged opts.cursor into it) so the module
    --    registers the effective ft / panel_ft / hide_on_cmdline — not the raw pre-merge opts.
    if opts.cursor then
        M.cursor.setup(M.config.cursor)
    end
end

return M
