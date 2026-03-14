-- lua/lvim-utils/ui/mode/input.lua
local util = require("lvim-utils.ui.util")
local api  = vim.api
local M    = {}

function M.attach(s)
	local k  = util.cfg().keys
	local ko = s.ko

	vim.schedule(function() vim.cmd("startinsert") end)

	vim.keymap.set("i", k.confirm, function()
		local l = api.nvim_buf_get_lines(s.buf, s.header_height, s.header_height + 1, false)
		vim.cmd("stopinsert")
		s.close(true, (l[1] or ""):gsub("^%s+", ""))
	end, ko)

	vim.keymap.set({ "i", "n" }, k.cancel, function()
		vim.cmd("stopinsert"); s.close(false, nil)
	end, ko)
end

return M
