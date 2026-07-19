-- lvim-utils.colors: public color palette for lvim-utils and external plugins — bundled muted dark/light
-- palettes plus blend/lighten/darken helpers, overridable via setup(). The bundled values are used only when
-- lvim-colorscheme is not driving the colors.
--
-- Usage:
--   local c = require("lvim-utils.colors")
--   c.red        -- "#cb4f4f"
--   c.bg_light   -- "#2c3339"
--   c.git.add    -- "#5f7240"
--   c.blend(c.teal, c.bg, 0.3)
--
-- Override via setup():
--   require("lvim-utils").setup({ colors = { red = "#ff0000" } })
--
---@module "lvim-utils.colors"

local M = {}

local hl = require("lvim-utils.highlight")

-- ── default palettes ──────────────────────────────────────────────────────
-- Bundled muted palettes, used when lvim-colorscheme is not driving the colors.
-- Field names go light → dark in dark mode; the LIGHT palette assigns each field
-- by its UI ROLE (e.g. bg_dark = the popup background) rather than by literal
-- lightness, so the same UI groups read correctly on a light background.

---@type table
local _base_dark = {
    none = "NONE",
    black = "#000000",
    white = "#ffffff",

    bg_light = "#2c3339",
    bg_soft_light = "#272e33",
    bg = "#23292d",
    bg_soft_dark = "#1f2427",
    bg_dark = "#1a1f21",
    bg_highlight = "#455156",

    fg_light = "#646c62",
    fg_soft_light = "#5f675d",
    fg = "#5a6158",
    fg_soft_dark = "#555c53",
    fg_dark = "#50574e",

    comment = "#565c53",
    terminal_bg = "#7a8478",

    blue = "#42728b",
    blue_dark = "#3a6479",
    green = "#75783a",
    green_dark = "#656831",
    cyan = "#527a57",
    cyan_dark = "#486b4c",
    magenta = "#bb755e",
    magenta_dark = "#b3664c",
    orange = "#cc7942",
    orange_dark = "#b86d3c",
    yellow = "#af9e6b",
    yellow_dark = "#a6935a",
    purple = "#635d71",
    purple_dark = "#575163",
    red = "#cb4f4f",
    red_dark = "#c53b3b",
    teal = "#357b6d",
    teal_dark = "#2d695d",

    git = {
        add = "#75783a",
        change = "#af9e6b",
        delete = "#cb4f4f",
        change_delete = "#cc7942",
        untracked = "#42728b",
        add_nr = "#54562a",
        change_nr = "#7e724d",
        delete_nr = "#923939",
        change_delete_nr = "#935730",
        untracked_nr = "#305264",
    },
}

---@type table
local _base_light = {
    none = "NONE",
    black = "#000000",
    white = "#ffffff",

    -- bg_dark = popup background (lightest); bg_light = most prominent surface
    bg_light = "#e3ddc8",
    bg_soft_light = "#e9e3d0",
    bg = "#efe9d6",
    bg_soft_dark = "#ece6d3",
    bg_dark = "#f8f5e9",
    bg_highlight = "#dce4c4",

    -- fg = body text (dark); fg_dark = dimmest (lightest)
    fg_light = "#4a5048",
    fg_soft_light = "#525850",
    fg = "#5a6158",
    fg_soft_dark = "#787e72",
    fg_dark = "#9aa090",

    comment = "#9aa094",
    terminal_bg = "#d0c9b0",

    blue = "#3a708a",
    blue_dark = "#335f76",
    green = "#6a7d2e",
    green_dark = "#5c6c28",
    cyan = "#3f7a5f",
    cyan_dark = "#356a52",
    magenta = "#a3568e",
    magenta_dark = "#8f4a7c",
    orange = "#c06a2e",
    orange_dark = "#a85d28",
    yellow = "#9a8420",
    yellow_dark = "#857218",
    purple = "#6a5d8a",
    purple_dark = "#5d527a",
    red = "#c34540",
    red_dark = "#b03b36",
    teal = "#2f7a6a",
    teal_dark = "#286a5c",

    git = {
        add = "#6a7d2e",
        change = "#9a8420",
        delete = "#c34540",
        change_delete = "#c06a2e",
        untracked = "#3a708a",
        add_nr = "#4c5a21",
        change_nr = "#6f5f17",
        delete_nr = "#8c322e",
        change_delete_nr = "#8a4c21",
        untracked_nr = "#2a5163",
    },
}

--- User overrides from setup(), re-applied on top of whichever base is active so they
--- survive background flips and palette syncs.
local _overrides = {}

--- The live palette. Readers reach it through the metatable on M.
local _p = {}

local function _compute()
    _p.fg_dim = _p.fg_dim or _p.fg_dark
    _p.fg_muted = _p.fg_muted or _p.comment
    _p.bg_input = _p.bg_input or _p.bg_soft_dark
    -- Float/panel background: synced from lvim-colorscheme (it follows `styles.floats` + the
    -- transparent state). Falls back to the panel bg_dark when no theme has driven it.
    _p.bg_float = _p.bg_float or _p.bg_dark
    -- Git line-number ("*_nr") variants: every theme SHIPS them, but a theme (or a user `git` override) that
    -- sets only the sign colors gets the darker line-number variant derived here, so `c.git.<state>_nr` is
    -- always present.
    if _p.git then
        for _, st in ipairs({ "add", "change", "delete", "change_delete", "untracked", "staged", "conflict" }) do
            if _p.git[st] and _p.git[st .. "_nr"] == nil then
                _p.git[st .. "_nr"] = hl.darken(_p.git[st], 0.28)
            end
        end
    end
end

--- Rebuild `_p` from the base for the current `&background` plus the user overrides.
local function _apply_base()
    local base = (vim.o.background == "light") and _base_light or _base_dark
    for k, v in pairs(base) do
        _p[k] = (type(v) == "table") and vim.deepcopy(v) or v
    end
    _p.fg_dim, _p.fg_muted, _p.bg_input = _overrides.fg_dim, _overrides.fg_muted, _overrides.bg_input
    for k, v in pairs(_overrides) do
        _p[k] = v
    end
    _compute()
end

_apply_base()

-- ── color helpers (re-exported from highlight module) ─────────────────────

M.blend = hl.blend
M.lighten = hl.lighten
M.darken = hl.darken

-- ── palette access ────────────────────────────────────────────────────────

setmetatable(M, {
    __index = function(_, k)
        return _p[k]
    end,
})

-- ── lvim-colorscheme sync ─────────────────────────────────────────────────

local _on_change_cbs = {}

---Register a callback that fires whenever the palette is synced from lvim-colorscheme.
---@param fn function
---@return fun() unsubscribe
function M.on_change(fn)
    table.insert(_on_change_cbs, fn)
    return function()
        for i, cb in ipairs(_on_change_cbs) do
            if cb == fn then
                table.remove(_on_change_cbs, i)
                break
            end
        end
    end
end

local function _fire_change()
    for _, fn in ipairs(_on_change_cbs) do
        pcall(fn)
    end
end

local _LCS_FLAT_KEYS = {
    "bg_light",
    "bg_soft_light",
    "bg",
    "bg_soft_dark",
    "bg_dark",
    "bg_float",
    "bg_highlight",
    "fg_light",
    "fg_soft_light",
    "fg",
    "fg_soft_dark",
    "fg_dark",
    "comment",
    "terminal_bg",
    "blue",
    "blue_dark",
    "green",
    "green_dark",
    "cyan",
    "cyan_dark",
    "magenta",
    "magenta_dark",
    "orange",
    "orange_dark",
    "yellow",
    "yellow_dark",
    "purple",
    "purple_dark",
    "red",
    "red_dark",
    "teal",
    "teal_dark",
}

--- True once lvim-colorscheme has driven the palette at least once; when set, the
--- background autocmd defers to lvim-colorscheme (which handles light/dark itself).
local _lcs_synced = false

local function _sync_from_lcs()
    local ok, lcs = pcall(require, "lvim-colorscheme")
    if not ok then
        return
    end
    local lc = lcs.colors
    if not lc then
        return
    end
    for _, k in ipairs(_LCS_FLAT_KEYS) do
        if lc[k] then
            _p[k] = lc[k]
        end
    end
    if lc.git then
        _p.git = vim.deepcopy(lc.git)
    end
    -- Follow lvim-colorscheme's `transparent` so the UI panels can drop their background too.
    local ok_cfg, lcfg = pcall(require, "lvim-colorscheme.config")
    _p.transparent = (ok_cfg and lcfg.transparent == true) or false
    -- user overrides stay sticky on top of the synced theme
    _p.fg_dim, _p.fg_muted, _p.bg_input = _overrides.fg_dim, _overrides.fg_muted, _overrides.bg_input
    for k, v in pairs(_overrides) do
        _p[k] = v
    end
    _compute()
    _lcs_synced = true
end

---Sync palette from lvim-colorscheme (if available) and notify all on_change listeners.
function M.sync_from_lcs()
    _sync_from_lcs()
    _fire_change()
end

-- ── setup ─────────────────────────────────────────────────────────────────

---Override palette colors. Overrides are remembered and re-applied on top of the active
---base, so they survive background flips and palette syncs. Derived colors (fg_dim,
---fg_muted, bg_input) are recomputed unless explicitly provided.
---
---Defined AFTER the sync section so it can re-apply on top of an already-synced theme: if
---lvim-colorscheme has already driven the palette, re-run the sync (which re-lays the overrides
---over the synced values) instead of reverting to the bundled base — otherwise a late set() would
---throw the live theme away until the next `User LvimColorscheme`. Always fires on_change so
---already-bound highlight factories re-render with the new palette.
---@param overrides table<string, string>
function M.setup(overrides)
    if not overrides then
        return
    end
    for k, v in pairs(overrides) do
        _overrides[k] = v
    end
    if _lcs_synced then
        _sync_from_lcs()
    else
        _apply_base()
    end
    _fire_change()
end

local _activated = false

---Activate palette syncing from lvim-colorscheme. Idempotent — call once from setup().
function M._activate()
    if _activated then
        return
    end
    _activated = true
    vim.schedule(function()
        local ok, lcs = pcall(require, "lvim-colorscheme")
        if ok and lcs.colors then
            M.sync_from_lcs()
        end
    end)
    local aug = vim.api.nvim_create_augroup("LvimUtilsColors", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = aug,
        pattern = "LvimColorscheme",
        callback = function()
            M.sync_from_lcs()
        end,
        desc = "Sync lvim-utils palette from lvim-colorscheme on theme change",
    })
    -- Standalone (no lvim-colorscheme): swap the bundled light/dark base on a background
    -- flip and notify listeners. When lvim-colorscheme drives the palette it handles its
    -- own light/dark, so we defer to it.
    vim.api.nvim_create_autocmd("OptionSet", {
        group = aug,
        pattern = "background",
        callback = function()
            if _lcs_synced then
                return
            end
            _apply_base()
            _fire_change()
        end,
        desc = "Rebuild the bundled lvim-utils palette for the new &background",
    })
end

return M
