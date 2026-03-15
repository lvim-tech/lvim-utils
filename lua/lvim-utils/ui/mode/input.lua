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

	-- Prevent <BS> at col 0 from joining the input line with the header above.
	vim.keymap.set("i", "<BS>", function()
		if api.nvim_win_get_cursor(s.win)[2] == 0 then return "" end
		return "<BS>"
	end, vim.tbl_extend("force", ko, { expr = true }))

	-- Grow the window when typed content exceeds width so Neovim never needs
	-- to scroll horizontally (which would shift header and footer too).
	-- Strategy: save the typed line, call s.render() to rebuild header/footer
	-- at the new width, then restore the typed line and cursor position.
	local aug = api.nvim_create_augroup("LvimInputWidth_" .. s.buf, { clear = true })
	api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group  = aug,
		buffer = s.buf,
		callback = function()
			if not api.nvim_win_is_valid(s.win) then return end
			local line = api.nvim_buf_get_lines(s.buf, s.header_height, s.header_height + 1, false)[1] or ""
			local need = vim.fn.strdisplaywidth(line) + 2
			if need <= s.width then return end
			s.width = math.min(need, vim.o.columns - 4)
			api.nvim_win_set_config(s.win, { width = s.width })
			-- s.render() rebuilds header/footer to the new width but also
			-- overwrites the input line and resets the cursor — fix both after.
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			s.render()
			api.nvim_buf_set_lines(s.buf, s.header_height, s.header_height + 1, false, { line })
			if ok then pcall(api.nvim_win_set_cursor, s.win, pos) end
		end,
	})
end

return M
