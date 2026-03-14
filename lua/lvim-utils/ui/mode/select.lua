-- lua/lvim-utils/ui/mode/select.lua
local util = require("lvim-utils.ui.util")
local M    = {}

function M.attach(s)
	local function map(lhs, fn) vim.keymap.set("n", lhs, fn, s.ko) end
	local k = util.cfg().keys

	local function move(delta)
		local ci  = s.cur_items()
		local new = s.current_idx + delta
		if new < 0 or new >= #ci then return end
		s.current_idx = new
		if s.current_idx < s.scroll then
			s.scroll = s.current_idx
		elseif s.current_idx >= s.scroll + s.content_height then
			s.scroll = s.current_idx - s.content_height + 1
		end
		s.render()
	end

	map(k.down,           function() move(1) end)
	map(k.up,             function() move(-1) end)
	map(k.select.confirm, function() s.close(true, s.current_idx + 1) end)
	map(k.select.cancel,  function() s.close(false, nil) end)
	map(k.close,          function() s.close(false, nil) end)
end

return M
