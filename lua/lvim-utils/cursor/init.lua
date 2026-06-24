-- lua/lvim-utils/cursor/init.lua
-- Cursor visibility management for lvim-utils popups.
-- Hides the cursor whenever a buffer with a registered filetype is visible
-- in any window. Uses a dedicated highlight group (LvimUtilsHiddenCursor)
-- with blend=100 and a 1-cell vertical bar shape, making the cursor
-- imperceptible in both GUI and TUI (termguicolors) environments.
--
-- Public API:
--   M.setup(opts)               – register filetypes and install autocmds
--   M.mark_input_buffer(buf, v) – exempt a buffer from cursor hiding
--   M.update()                  – force-refresh cursor state from outside

local M = {}

local api = vim.api

---@class CursorState
---@field fts            table<string, boolean>   Popup filetypes: hide whenever visible in ANY window
---@field panel_fts      table<string, boolean>   Panel filetypes: hide only while one is the CURRENT window
---@field hide_buffers   table<integer, boolean>  Buffers that hide the cursor while CURRENT (by handle, not
---                                                filetype — e.g. a hover/diagnostic float whose ft is shared)
---@field input_buffers  table<integer, boolean>  Buffers explicitly marked as input (never hidden)
---@field custom_buffers table<integer, string>   Buffers with a CUSTOM cursor: an `guicursor` fragment (e.g.
---                                                "t:ver25-LvimUiPickerCursor") appended to the baseline while current
---@field augroup        integer|nil              Autocmd group handle
---@field saved_guicursor string|nil             The user's BASELINE guicursor, saved on the first deviation (hide
---                                                or custom), restored when the cursor returns to normal
---@field hidden         boolean                  Whether the cursor is currently hidden
---@field custom         string|nil               The custom guicursor fragment currently applied (or nil)

---@type CursorState
local state = {
    fts = {},
    panel_fts = {}, -- "current-only" filetypes: hide the cursor ONLY while one is the CURRENT window (a
    -- persistent side panel like the outline), NOT globally whenever it is visible somewhere
    hide_buffers = {}, -- "current-only" by BUFFER HANDLE (for floats whose filetype can't be dedicated)
    input_buffers = {},
    custom_buffers = {}, -- buffer handle → a guicursor fragment applied (over the baseline) while that buf is current
    augroup = nil,
    saved_guicursor = nil,
    hidden = false,
    custom = nil, -- the custom guicursor fragment currently applied, or nil
    -- When true, HIDE the hardware cursor while the command-line is active (a self-rendered cmdline draws
    -- its own cursor in the float, so the buffer cursor is redundant — like the native cmdline, where the
    -- cursor lives in the cmdline, not the buffer). Default false: with the native cmdline keep it shown.
    hide_on_cmdline = false,
    in_cmdline = false, -- true between CmdlineEnter/CmdlineLeave (so update() keeps the cursor hidden then)
}

-- ─── highlight control ────────────────────────────────────────────────────────

local HIDDEN_GC = "a:ver1-LvimUtilsHiddenCursor"

--- The custom guicursor fragment registered for the CURRENT buffer (via `mark_cursor_buffer`), or nil.
---@return string|nil
local function current_custom()
    local ok, win = pcall(api.nvim_get_current_win)
    if not ok or not api.nvim_win_is_valid(win) then
        return nil
    end
    local ok2, buf = pcall(api.nvim_win_get_buf, win)
    if not ok2 or not buf then
        return nil
    end
    return state.custom_buffers[buf]
end

--- Hide the cursor by switching to a transparent 1-cell vertical bar. Saves the user's BASELINE guicursor on
--- the first deviation. No-op when already hidden.
local function hide_cursor()
    if state.hidden then
        return
    end
    if state.saved_guicursor == nil then
        state.saved_guicursor = vim.o.guicursor
    end
    api.nvim_set_hl(0, "LvimUtilsHiddenCursor", { blend = 100, nocombine = true })
    vim.o.guicursor = HIDDEN_GC
    state.hidden = true
    state.custom = nil
end

--- Show the cursor: the CURRENT buffer's CUSTOM cursor if it has one (the user's baseline + the registered
--- fragment, e.g. a thin blue bar for the finder input), else the plain baseline. Idempotent.
local function show_cursor()
    local frag = current_custom()
    if frag then
        if state.saved_guicursor == nil then
            state.saved_guicursor = vim.o.guicursor
        end
        local want = state.saved_guicursor .. "," .. frag
        if vim.o.guicursor ~= want then
            vim.o.guicursor = want
        end
        state.hidden, state.custom = false, frag
        return
    end
    if state.saved_guicursor ~= nil then
        vim.o.guicursor = state.saved_guicursor
        state.saved_guicursor = nil
    end
    state.hidden, state.custom = false, nil
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

---Return true when buf is marked as an input buffer (cursor must stay visible).
---@param buf integer
---@return boolean
local function is_input(buf)
    return state.input_buffers[buf] == true
end

---Return true when buf's filetype hides the cursor while buf is the CURRENT window — a popup ft OR a
---panel (current-only) ft. Input buffers are excluded even if their filetype matches.
---@param buf integer
---@return boolean
local function is_hidden_buffer(buf)
    if is_input(buf) then
        return false
    end
    if not api.nvim_buf_is_valid(buf) then
        return false
    end
    if state.hide_buffers[buf] == true then
        return true
    end
    local ft = vim.bo[buf].filetype
    return ft ~= nil and (state.fts[ft] == true or state.panel_fts[ft] == true)
end

---Return true when at least one visible window contains a POPUP-filetype buffer. Used to keep the cursor
---hidden even when focus moves to a non-popup window while a popup is still open. PANEL (current-only)
---filetypes are NOT counted — a persistent side panel must not hide the cursor in the code beside it.
---@return boolean
local function any_hidden_win_open()
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) then
            local ok, buf = pcall(api.nvim_win_get_buf, win)
            if
                ok
                and buf
                and api.nvim_buf_is_valid(buf)
                and not is_input(buf)
                and state.fts[vim.bo[buf].filetype] == true
            then
                return true
            end
        end
    end
    return false
end

-- ─── core update ──────────────────────────────────────────────────────────────

--- Recompute and apply the correct cursor visibility for the current context.
--- Decision tree:
---   1. Invalid window          → show
---   2. Current buf is input    → show
---   3. Current buf is hidden, OR any hidden window is open → hide
---   4. Otherwise               → show
local function update()
    -- While the command-line is active with hide_on_cmdline, KEEP the cursor hidden no matter which buffer
    -- is current — the cmdline FLOAT opening fires WinEnter/BufWinEnter (→ this update), and the current
    -- buffer is the editor (not a hidden ft), so without this guard update() would re-show the cursor.
    if state.in_cmdline and state.hide_on_cmdline then
        hide_cursor()
        return
    end

    local ok, win = pcall(api.nvim_get_current_win)
    if not ok or not api.nvim_win_is_valid(win) then
        show_cursor()
        return
    end

    local ok2, buf = pcall(api.nvim_win_get_buf, win)
    if not ok2 or not buf then
        show_cursor()
        return
    end

    if is_input(buf) then
        show_cursor()
        return
    end

    if is_hidden_buffer(buf) or any_hidden_win_open() then
        hide_cursor()
    else
        show_cursor()
    end
end

-- ─── public api ───────────────────────────────────────────────────────────────

--- Mark or unmark a buffer as an input buffer.
--- Input buffers are never hidden even if their filetype is registered.
--- Called by the UI module for text-input popups.
---@param bufnr integer
---@param value  boolean|nil  true to mark as input, nil/false to unmark
function M.mark_input_buffer(bufnr, value)
    state.input_buffers[bufnr] = value or nil
    vim.schedule(update)
end

--- Mark or unmark a buffer to HIDE the cursor while it is the current window — by buffer handle, for floats
--- (hover / diagnostic) whose filetype is shared (e.g. markdown) and so cannot be registered via `panel_ft`.
---@param bufnr integer
---@param value boolean|nil  true to hide while current, nil/false to stop
function M.mark_hide_buffer(bufnr, value)
    state.hide_buffers[bufnr] = value or nil
    vim.schedule(update)
end

--- Give a buffer a CUSTOM cursor while it is the current window: `fragment` is a `guicursor` fragment (e.g.
--- "t:ver25-LvimUiPickerCursor") appended to the user's baseline, so the cursor takes that shape/colour in
--- that buffer and reverts to normal everywhere else. Pass nil to clear. The owning module is also the one
--- that defines the referenced highlight group. Used by the fzf finder for its thin blue input caret.
---@param bufnr integer
---@param fragment string|nil
function M.mark_cursor_buffer(bufnr, fragment)
    state.custom_buffers[bufnr] = fragment or nil
    vim.schedule(update)
end

--- Force-refresh cursor visibility. Exported so the UI module can call it
--- immediately after nvim_open_win to prevent the one-frame cursor flash.
M.update = update

--- Hide (or stop hiding) the hardware cursor while the command-line is active — lvim-utils.cmdline turns
--- this on, because it draws its own cursor in the cmdline float. Read live by the CmdlineEnter autocmd.
---@param value boolean|nil
function M.set_cmdline_hide(value)
    state.hide_on_cmdline = value and true or false
    if not value then
        vim.schedule(update)
    end
end

-- ─── autocmds ─────────────────────────────────────────────────────────────────

--- (Re-)create the autocmd group that keeps cursor state in sync.
--- Tears down any existing group first to allow safe re-setup.
local function refresh_autocmds()
    if state.augroup then
        api.nvim_del_augroup_by_id(state.augroup)
    end

    state.augroup = api.nvim_create_augroup("LvimUtilsCursor", { clear = true })

    -- Window / buffer transitions: schedule to let Neovim settle first.
    api.nvim_create_autocmd({
        "WinEnter",
        "WinLeave",
        "WinClosed",
        "BufEnter",
        "BufWinEnter",
        "FileType",
    }, {
        group = state.augroup,
        callback = function()
            vim.schedule(update)
        end,
    })

    -- Clean up the input-buffer registry when a buffer is wiped.
    api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
        group = state.augroup,
        callback = function(ev)
            state.input_buffers[ev.buf] = nil
            state.hide_buffers[ev.buf] = nil
            vim.schedule(update)
        end,
    })

    -- A theme change wipes all highlight groups (`hi clear`), including the invisible-cursor
    -- group, so re-apply it while the cursor is meant to be hidden. Listen to BOTH events:
    -- `:colorscheme` fires `ColorScheme`, but a programmatic reload (lvim-colorscheme
    -- `set()`/`load()`, e.g. toggling a control-center setting) fires only the
    -- `User LvimColorscheme` event — without this the cursor reappears as a `ver1` bar.
    local function reapply_hidden_cursor()
        if state.hidden then
            api.nvim_set_hl(0, "LvimUtilsHiddenCursor", { blend = 100, nocombine = true })
        end
    end
    api.nvim_create_autocmd("ColorScheme", { group = state.augroup, callback = reapply_hidden_cursor })
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimColorscheme",
        callback = reapply_hidden_cursor,
    })

    -- Command-line: a self-rendered cmdline draws its own cursor in the float, so the hardware cursor in
    -- the buffer is redundant — hide it (`hide_on_cmdline`, set by lvim-utils.cmdline). With the native
    -- cmdline the cursor lives there, so default to showing it.
    api.nvim_create_autocmd("CmdlineEnter", {
        group = state.augroup,
        callback = function()
            state.in_cmdline = true
            if state.hide_on_cmdline then
                hide_cursor()
            else
                show_cursor()
            end
        end,
    })
    api.nvim_create_autocmd("CmdlineLeave", {
        group = state.augroup,
        callback = function()
            state.in_cmdline = false
            vim.schedule(update)
        end,
    })

    vim.schedule(update)
end

-- ─── setup ────────────────────────────────────────────────────────────────────

--- Initialise the cursor module.
--- Registers filetypes that should trigger cursor hiding and installs autocmds.
---@param opts? { filetypes?: string[], ft?: string[], panel_filetypes?: string[], panel_ft?: string[], hide_on_cmdline?: boolean }
function M.setup(opts)
    opts = opts or {}
    if opts.hide_on_cmdline ~= nil then
        state.hide_on_cmdline = opts.hide_on_cmdline and true or false
    end
    for _, ft in ipairs(opts.filetypes or opts.ft or {}) do
        state.fts[ft] = true
    end
    -- Persistent side panels: hide the cursor only while one is the CURRENT window (not globally).
    for _, ft in ipairs(opts.panel_filetypes or opts.panel_ft or {}) do
        state.panel_fts[ft] = true
    end
    refresh_autocmds()
end

return M
