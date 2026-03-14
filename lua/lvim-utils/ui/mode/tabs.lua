-- lua/lvim-utils/ui/mode/tabs.lua
local util  = require("lvim-utils.ui.util")
local rows  = require("lvim-utils.ui.rows")

local api             = vim.api
local calc_pos        = util.calc_pos
local next_selectable = rows.next_selectable
local is_selectable   = rows.is_selectable
local first_selectable = rows.first_selectable

local M = {}

function M.attach(s)
	local function map(lhs, fn) vim.keymap.set("n", lhs, fn, s.ko) end
	local k = util.cfg().keys

	local function move_row(delta)
		local rrows = s.cur_rows()

		if not s.horizontal_actions then
			local nxt = next_selectable(rrows, s.row_cursor, delta)
			if not nxt then return end
			s.row_cursor = nxt
			if s.row_cursor < s.scroll + 1 then
				local top = s.row_cursor - 1
				while top > 0 and not is_selectable(rrows[top]) do top = top - 1 end
				s.scroll = top
			elseif s.row_cursor > s.scroll + s.content_height then
				s.scroll = s.row_cursor - s.content_height
			end
			s.render()
			return
		end

		local cur_r     = rrows[s.row_cursor]
		local on_action = cur_r and cur_r.type == "action"
		local cr        = s.cur_content_rows()

		if on_action then
			if delta == -1 then
				for i = #cr, 1, -1 do
					if is_selectable(cr[i]) then
						for ri, r in ipairs(rrows) do
							if r == cr[i] then
								s.row_cursor = ri
								if i > s.scroll + s.content_height then
									s.scroll = i - s.content_height
								end
								s.render()
								return
							end
						end
					end
				end
			end
			return
		end

		local cur_ci = 0
		for i, r in ipairs(cr) do
			if r == cur_r then cur_ci = i; break end
		end

		local i = cur_ci + delta
		while i >= 1 and i <= #cr do
			if is_selectable(cr[i]) then
				for ri, r in ipairs(rrows) do
					if r == cr[i] then
						s.row_cursor = ri
						if i < s.scroll + 1 then
							s.scroll = i - 1
						elseif i > s.scroll + s.content_height then
							s.scroll = i - s.content_height
						end
						s.render()
						return
					end
				end
			end
			i = i + delta
		end

		if delta > 0 then
			local ar = s.cur_action_rows()
			if #ar > 0 then
				for ri, r in ipairs(rrows) do
					if r == ar[1] then s.row_cursor = ri; s.render(); return end
				end
			end
		end
	end

	local function move_action(delta)
		if not s.horizontal_actions then return false end
		local rrows = s.cur_rows()
		local cur_r = rrows[s.row_cursor]
		if not cur_r or cur_r.type ~= "action" then return false end
		local ar     = s.cur_action_rows()
		local cur_ai = 1
		for i, r in ipairs(ar) do
			for ri, rr in ipairs(rrows) do
				if rr == r and ri == s.row_cursor then cur_ai = i; break end
			end
		end
		local new_ai = cur_ai + delta
		if new_ai < 1 or new_ai > #ar then return false end
		for ri, r in ipairs(rrows) do
			if r == ar[new_ai] then s.row_cursor = ri; s.render(); return true end
		end
		return false
	end

	local function activate_row()
		local rrows = s.cur_rows()
		local row   = rrows[s.row_cursor]
		if not row or not is_selectable(row) then return end
		local t = row.type or "string"

		if t == "bool" or t == "boolean" then
			row.value = not row.value
			if row.run then row.run(row.value) end
			if s.on_change then s.on_change(row) end
			s.render()
		elseif t == "select" then
			local opts2 = row.options or {}
			if #opts2 == 0 then return end
			local idx = 1
			for i, v in ipairs(opts2) do if v == row.value then idx = i; break end end
			row.value = opts2[(idx % #opts2) + 1]
			if row.run then row.run(row.value) end
			if s.on_change then s.on_change(row) end
			s.render()
		elseif t == "int" or t == "integer" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then return end
					local n = tonumber(input)
					if n and math.floor(n) == n then
						row.value = n
						if row.run then row.run(n) end
						if s.on_change then s.on_change(row) end
						s.render()
					end
				end
			)
		elseif t == "float" or t == "number" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then return end
					local n = tonumber(input)
					if n then
						row.value = n
						if row.run then row.run(n) end
						if s.on_change then s.on_change(row) end
						s.render()
					end
				end
			)
		elseif t == "string" or t == "text" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then return end
					row.value = input
					if row.run then row.run(input) end
					if s.on_change then s.on_change(row) end
					s.render()
				end
			)
		elseif t == "action" then
			if row.run then row.run(row.value, s.close) end
		end
	end

	local function prev_select_option()
		local rrows = s.cur_rows()
		local row   = rrows[s.row_cursor]
		if not row or row.type ~= "select" then return end
		local opts2 = row.options or {}
		if #opts2 == 0 then return end
		local idx = 1
		for i, v in ipairs(opts2) do if v == row.value then idx = i; break end end
		local prev = idx - 1
		if prev < 1 then prev = #opts2 end
		row.value = opts2[prev]
		if row.run then row.run(row.value) end
		if s.on_change then s.on_change(row) end
		s.render()
	end

	local function rows_snapshot()
		local snap = {}
		for _, t in ipairs(s.tabs) do
			for _, r in ipairs(t.rows or {}) do
				if r.name then snap[r.name] = r.value end
			end
		end
		return snap
	end

	local function first_tab_cursor()
		if s.horizontal_actions then
			local rrows = s.cur_rows()
			for i, r in ipairs(rrows) do
				if is_selectable(r) and r.type ~= "action" then return i end
			end
		end
		return first_selectable(s.cur_rows())
	end

	local function do_tab_switch()
		s.current_idx = 0
		s.scroll      = 0
		s.row_cursor  = first_tab_cursor()
		s.recalc_heights()
		if s.position ~= "cursor" then
			s._row, s._col = calc_pos(s.total_height, s.width, s.position)
		end
		pcall(api.nvim_win_set_config, s.win, {
			relative = "editor", height = s.total_height, row = s._row, col = s._col,
		})
		pcall(api.nvim_win_set_cursor, s.win, { 1, 0 })
		s.render()
	end

	-- keymaps
	map(k.tabs.next, function()
		local rr = s.cur_rows()
		local on_action = s.horizontal_actions and rr[s.row_cursor] and rr[s.row_cursor].type == "action"
		if on_action and move_action(1) then return end
		if s.active_tab < #s.tabs then s.active_tab = s.active_tab + 1; do_tab_switch() end
	end)
	map(k.tabs.prev, function()
		local rr = s.cur_rows()
		local on_action = s.horizontal_actions and rr[s.row_cursor] and rr[s.row_cursor].type == "action"
		if on_action and move_action(-1) then return end
		if s.active_tab > 1 then s.active_tab = s.active_tab - 1; do_tab_switch() end
	end)

	if s.tab_has_rows() then
		map(k.down,             function() move_row(1) end)
		map(k.up,               function() move_row(-1) end)
		map(k.confirm,          function() activate_row() end)
		map(k.list.next_option, function() activate_row() end)
		map(k.list.prev_option, function() prev_select_option() end)
		map(k.cancel,           function() s.close(true, rows_snapshot()) end)
		map(k.close,            function() s.close(false, nil) end)
	else
		local function move_item(delta)
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
		map(k.down,    function() move_item(1) end)
		map(k.up,      function() move_item(-1) end)
		map(k.confirm, function()
			local item = s.cur_items()[s.current_idx + 1]
			s.close(true, { tab = s.active_tab, index = s.current_idx + 1, item = item })
		end)
		map(k.cancel, function() s.close(false, nil) end)
		map(k.close,  function() s.close(false, nil) end)
	end
end

return M
