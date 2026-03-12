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
---@field fts            table<string, boolean>   Registered filetypes that trigger hiding
---@field input_buffers  table<integer, boolean>  Buffers explicitly marked as input (never hidden)
---@field augroup        integer|nil              Autocmd group handle
---@field saved_guicursor string|nil             Original guicursor value saved before hiding
---@field hidden         boolean                  Whether the cursor is currently hidden

---@type CursorState
local state = {
	fts            = {},
	input_buffers  = {},
	augroup        = nil,
	saved_guicursor = nil,
	hidden          = false,
}

-- ─── highlight control ────────────────────────────────────────────────────────

--- Hide the cursor by switching to a transparent 1-cell vertical bar.
--- Sets guicursor to "a:ver1-LvimUtilsHiddenCursor" and applies blend=100
--- on the dedicated HL group. No-op when already hidden.
local function hide_cursor()
	if state.hidden then return end
	state.saved_guicursor = vim.o.guicursor
	api.nvim_set_hl(0, "LvimUtilsHiddenCursor", { blend = 100, nocombine = true })
	vim.o.guicursor = "a:ver1-LvimUtilsHiddenCursor"
	state.hidden = true
end

--- Restore the cursor to the shape that was active before hide_cursor().
--- No-op when the cursor is already visible.
local function show_cursor()
	if not state.hidden then return end
	if state.saved_guicursor then
		vim.o.guicursor  = state.saved_guicursor
		state.saved_guicursor = nil
	end
	state.hidden = false
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

---Return true when buf is marked as an input buffer (cursor must stay visible).
---@param buf integer
---@return boolean
local function is_input(buf)
	return state.input_buffers[buf] == true
end

---Return true when buf has a filetype registered for cursor hiding.
---Input buffers are excluded even if their filetype matches.
---@param buf integer
---@return boolean
local function is_hidden_buffer(buf)
	if is_input(buf) then return false end
	if not api.nvim_buf_is_valid(buf) then return false end
	local ft = vim.bo[buf].filetype
	return ft ~= nil and state.fts[ft] == true
end

---Return true when at least one visible window contains a hidden-filetype buffer.
---Used to keep the cursor hidden even when focus moves to a non-popup window
---while a popup is still open.
---@return boolean
local function any_hidden_win_open()
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_is_valid(win) then
			local ok, buf = pcall(api.nvim_win_get_buf, win)
			if ok and buf and is_hidden_buffer(buf) then return true end
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

--- Force-refresh cursor visibility. Exported so the UI module can call it
--- immediately after nvim_open_win to prevent the one-frame cursor flash.
M.update = update

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
		"WinEnter", "WinLeave", "WinClosed",
		"BufEnter", "BufWinEnter",
		"FileType",
	}, {
		group    = state.augroup,
		callback = function() vim.schedule(update) end,
	})

	-- Clean up the input-buffer registry when a buffer is wiped.
	api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
		group    = state.augroup,
		callback = function(ev)
			state.input_buffers[ev.buf] = nil
			vim.schedule(update)
		end,
	})

	-- ColorScheme resets all HL groups; re-apply the hidden cursor group if needed.
	api.nvim_create_autocmd("ColorScheme", {
		group    = state.augroup,
		callback = function()
			if state.hidden then
				api.nvim_set_hl(0, "LvimUtilsHiddenCursor", { blend = 100, nocombine = true })
			end
		end,
	})

	-- Always show the cursor while the command-line is active.
	api.nvim_create_autocmd("CmdlineEnter", {
		group    = state.augroup,
		callback = show_cursor,
	})
	api.nvim_create_autocmd("CmdlineLeave", {
		group    = state.augroup,
		callback = function() vim.schedule(update) end,
	})

	vim.schedule(update)
end

-- ─── setup ────────────────────────────────────────────────────────────────────

--- Initialise the cursor module.
--- Registers filetypes that should trigger cursor hiding and installs autocmds.
---@param opts? { filetypes?: string[], ft?: string[] }
function M.setup(opts)
	opts = opts or {}
	for _, ft in ipairs(opts.filetypes or opts.ft or {}) do
		state.fts[ft] = true
	end
	refresh_autocmds()
end

return M
