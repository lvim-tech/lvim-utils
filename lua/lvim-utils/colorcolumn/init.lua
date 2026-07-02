-- lvim-utils.colorcolumn: keep 'colorcolumn' meaningful under 'wrap'.
--
-- Neovim draws colorcolumn at a TEXT (virtual) column. With 'wrap' on and a window NARROWER than that column,
-- the column cannot land on the first screen row — it falls onto a WRAPPED continuation row at screen col
-- (column − width), i.e. a stray highlighted cell near the left edge of wrapped lines instead of a vertical
-- guide. This module removes that artefact: per window, while 'wrap' is on it drops the colorcolumn entries
-- that would not fit (a lone 80/120 in a too-narrow window becomes none) and restores them once the window is
-- wide enough or 'wrap' is off.
--
-- The DESIRED value is read from the GLOBAL 'colorcolumn' (vim.go.colorcolumn) and only WINDOW-LOCAL values
-- are ever written, so the source of truth is never clobbered. That global is exactly what a host like
-- lvim-control-center keeps in sync (its panel reads its own DB, not the live option), so toggling here cannot
-- lose the saved setting; with NO host present a plain `:set colorcolumn=…` populates the same global, so the
-- module works standalone. Filetypes listed in `exclude_ft` (side panels such as neo-tree) are forced off.
--
-- Public API:
--   M.setup(opts)  – install the autocmds; opts.enabled toggles the feature, opts.exclude_ft skips filetypes
--   M.refresh()    – force a (coalesced) re-apply across all windows
---@module "lvim-utils.colorcolumn"

local M = {}

local api = vim.api

---@class ColorColumnState
---@field augroup    integer|nil              Autocmd group handle (nil while disabled)
---@field enabled    boolean                  Master toggle (config)
---@field exclude_ft table<string, boolean>   Filetypes whose windows are forced to no colorcolumn
---@field applying   boolean                  True while WE write a window-local value (suppress our own OptionSet feedback)
---@field scheduled  boolean                  A coalesced refresh is already pending for this tick
---@type ColorColumnState
local state = {
    augroup = nil,
    enabled = true,
    exclude_ft = {},
    applying = false,
    scheduled = false,
}

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- The desired (un-filtered) colorcolumn: the GLOBAL option, kept in sync by the host (control-center) or a
--- plain `:set`. Never written by this module, so it cannot be lost.
---@return string
local function desired()
    return api.nvim_get_option_value("colorcolumn", { scope = "global" })
end

--- TEXT columns available in a window: its width minus the gutters (number / sign / fold).
---@param win integer
---@return integer
local function text_width(win)
    local info = vim.fn.getwininfo(win)[1]
    if not info then
        return api.nvim_win_get_width(win)
    end
    return info.width - info.textoff
end

--- Resolve one colorcolumn entry ("120", "+1", "-2") to an absolute screen column, or nil when Neovim would
--- not draw it (a relative entry while 'textwidth' is 0).
---@param entry string
---@param tw integer  the window buffer's 'textwidth'
---@return integer|nil
local function resolve_col(entry, tw)
    local sign, digits = entry:match("^([+-]?)(%d+)$")
    if not digits then
        return nil
    end
    local n = tonumber(digits)
    if sign == "" then
        return n
    end
    if tw == 0 then
        return nil -- relative columns are not shown without 'textwidth'
    end
    return sign == "+" and (tw + n) or (tw - n)
end

--- The effective window-local colorcolumn for `win`: "" for excluded filetypes; under 'wrap' only the entries
--- that fit on the first screen row (col ≤ text width); the full desired otherwise.
---@param win integer
---@return string
local function effective(win)
    -- FLOATING windows are UI surfaces (the lvim-utils pickers / panels / popups, hover floats, …), not editing
    -- windows — never draw a colorcolumn in them (it would leak the editor's text guide into the chrome).
    local ok_cfg, wcfg = pcall(api.nvim_win_get_config, win)
    if ok_cfg and wcfg.relative and wcfg.relative ~= "" then
        return ""
    end
    local buf = api.nvim_win_get_buf(win)
    if state.exclude_ft[vim.bo[buf].filetype] then
        return ""
    end
    local d = desired()
    if d == "" or not api.nvim_get_option_value("wrap", { win = win }) then
        return d
    end
    local width = text_width(win)
    local tw = vim.bo[buf].textwidth
    local kept = {}
    for entry in vim.gsplit(d, ",", { plain = true, trimempty = true }) do
        local col = resolve_col(entry, tw)
        -- keep entries that fit on row 1, and undrawn relative entries (nil) which cause no artefact
        if col == nil or col <= width then
            kept[#kept + 1] = entry
        end
    end
    return table.concat(kept, ",")
end

--- Apply the effective colorcolumn to one window (WINDOW-LOCAL only). No-op when already correct.
---@param win integer
local function apply(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local want = effective(win)
    -- Write through `nvim_win_call` + `opt_local` — the only true `:setlocal`, leaving the GLOBAL desired
    -- untouched. (Assigning "" via vim.wo[win]/vim.wo, or nvim_set_option_value({win=win}) on the current
    -- window, behaves like `:set` and WIPES the global — our source of truth — so a later pass would re-read
    -- "" and blank every window: a self-erasing loop.)
    if vim.wo[win].colorcolumn ~= want then
        state.applying = true
        api.nvim_win_call(win, function()
            vim.opt_local.colorcolumn = want
        end)
        state.applying = false
    end
end

--- Re-apply the effective value across every window.
local function refresh_all()
    state.scheduled = false
    if not state.enabled then
        return
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        apply(win)
    end
end

--- Coalesce refreshes: many events in one tick collapse to a single pass after Neovim has settled.
local function request_refresh()
    if state.scheduled or not state.enabled then
        return
    end
    state.scheduled = true
    vim.schedule(refresh_all)
end

--- Hand every window back the FULL desired value (excluded filetypes stay off) — used when the feature is
--- turned off, so any window we had blanked is no longer stuck empty.
local function restore_all()
    local d = desired()
    state.applying = true
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) then
            local buf = api.nvim_win_get_buf(win)
            local want = state.exclude_ft[vim.bo[buf].filetype] and "" or d
            api.nvim_win_call(win, function()
                vim.opt_local.colorcolumn = want
            end)
        end
    end
    state.applying = false
end

-- ─── public api ───────────────────────────────────────────────────────────────

--- Force a (coalesced) re-apply across all windows. Exported for hosts that change layout or options
--- imperatively and want the guide recomputed.
M.refresh = request_refresh

-- ─── autocmds ─────────────────────────────────────────────────────────────────

--- (Re-)create the autocmd group. Tears down any existing group first so re-setup is safe; installs nothing
--- while disabled.
local function refresh_autocmds()
    if state.augroup then
        api.nvim_del_augroup_by_id(state.augroup)
        state.augroup = nil
    end
    if not state.enabled then
        return
    end

    state.augroup = api.nvim_create_augroup("LvimUtilsColorColumn", { clear = true })

    -- Focus / display / size changes that can alter a window's text width or its filetype.
    api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "WinResized", "VimResized", "FileType" }, {
        group = state.augroup,
        callback = request_refresh,
    })

    -- Option changes that move the guide or the gutters: the desired colorcolumn (global), 'wrap', and the
    -- gutter-width options. Our OWN window-local writes also fire OptionSet colorcolumn — those are ignored.
    api.nvim_create_autocmd("OptionSet", {
        group = state.augroup,
        pattern = {
            "colorcolumn",
            "wrap",
            "number",
            "relativenumber",
            "numberwidth",
            "signcolumn",
            "foldcolumn",
            "textwidth",
        },
        callback = function()
            if state.applying then
                return
            end
            request_refresh()
        end,
    })

    request_refresh()
end

-- ─── setup ────────────────────────────────────────────────────────────────────

--- Initialise the colorcolumn manager.
---@param opts? { enabled?: boolean, exclude_ft?: string[] }
function M.setup(opts)
    opts = opts or {}
    if opts.enabled ~= nil then
        state.enabled = opts.enabled and true or false
    end
    if opts.exclude_ft then
        state.exclude_ft = {}
        for _, ft in ipairs(opts.exclude_ft) do
            state.exclude_ft[ft] = true
        end
    end
    refresh_autocmds()
    if not state.enabled then
        restore_all()
    end
end

return M
