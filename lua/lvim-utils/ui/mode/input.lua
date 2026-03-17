-- lua/lvim-utils/ui/mode/input.lua
local api = vim.api
local M    = {}

function M.attach(s)
	local k  = s.cfg.keys
	local ko = s.ko

	vim.schedule(function() vim.cmd("startinsert") end)

	vim.keymap.set("i", k.confirm, function()
		local l = api.nvim_buf_get_lines(s.buf, s.header_height, s.header_height + 1, false)
		vim.cmd("stopinsert")
		s.close(true, vim.trim(l[1] or ""))
	end, ko)

	vim.keymap.set({ "i", "n" }, k.cancel, function()
		vim.cmd("stopinsert"); s.close(false, nil)
	end, ko)

	-- Byte column of the first editable character: the buffer line is
	-- "  " .. placeholder .. typed_text. The 2-space indent is purely visual
	-- and must not be entered; everything after it (including the placeholder
	-- itself) is freely editable — placeholder is an initial/default value,
	-- not a locked prefix.
	local min_col = 2

	-- <BS>: block if already at the start of user input (not just col 0).
	vim.keymap.set("i", "<BS>", function()
		if api.nvim_win_get_cursor(s.win)[2] <= min_col then return "" end
		return "<BS>"
	end, vim.tbl_extend("force", ko, { expr = true }))

	-- <Left>: block from entering the placeholder / prefix region.
	vim.keymap.set("i", "<Left>", function()
		if api.nvim_win_get_cursor(s.win)[2] <= min_col then return "" end
		return "<Left>"
	end, vim.tbl_extend("force", ko, { expr = true }))

	-- <Home>: jump to start of user input, not start of buffer line.
	vim.keymap.set("i", "<Home>", function()
		pcall(api.nvim_win_set_cursor, s.win, { 1, min_col })
	end, ko)

	-- Width is fixed: text scrolls horizontally inside the window (like an
	-- HTML <input>). Neovim handles horizontal scrolling automatically when
	-- wrap=false and the cursor moves past the window edge.
end

return M
