-- lua/lvim-utils/ui/mode/tabs.lua
local util = require("lvim-utils.ui.util")
local rows = require("lvim-utils.ui.rows")

local api = vim.api
local calc_pos = util.calc_pos
local next_selectable = rows.next_selectable
local is_selectable = rows.is_selectable
local first_selectable = rows.first_selectable

local M = {}

function M.attach(s)
	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, s.ko)
	end
	local k = s.cfg.keys

	local function move_row(delta)
		local rrows = s.cur_rows()

		if not s.horizontal_actions then
			local nxt = next_selectable(rrows, s.row_cursor, delta)
			if not nxt then
				return
			end
			s.row_cursor = nxt
			if s.row_cursor < s.scroll + 1 then
				local top = s.row_cursor - 1
				while top > 0 and not is_selectable(rrows[top]) do
					top = top - 1
				end
				s.scroll = top
			elseif s.row_cursor > s.scroll + s.content_height then
				s.scroll = s.row_cursor - s.content_height
			end
			s.render()
			return
		end

		local cur_r = rrows[s.row_cursor]
		local on_action = cur_r and cur_r.type == "action"
		local cr = s.cur_content_rows()

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
			if r == cur_r then
				cur_ci = i
				break
			end
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
					if r == ar[1] then
						s.row_cursor = ri
						s.render()
						return
					end
				end
			end
		end
	end

	local function move_action(delta)
		if not s.horizontal_actions then
			return false
		end
		local rrows = s.cur_rows()
		local cur_r = rrows[s.row_cursor]
		if not cur_r or cur_r.type ~= "action" then
			return false
		end
		local ar = s.cur_action_rows()
		local cur_ai = 1
		local found = false
		for i, r in ipairs(ar) do
			if not found then
				for ri, rr in ipairs(rrows) do
					if rr == r and ri == s.row_cursor then
						cur_ai = i
						found = true
						break
					end
				end
			end
		end
		local new_ai = cur_ai + delta
		if new_ai < 1 or new_ai > #ar then
			return false
		end
		for ri, r in ipairs(rrows) do
			if r == ar[new_ai] then
				s.row_cursor = ri
				s.render()
				return true
			end
		end
		return false
	end

	-- Cycle a segmented row's active option and notify (run with activated=false).
	--- Move a segmented row's selection by `dir`, clamped (no wrap). Returns true when
	--- it moved; false at a boundary so the caller can fall through to tab switching.
	---@return boolean moved
	local function cycle_segment(row, dir)
		local opts = row.options or {}
		if #opts == 0 then
			return false
		end
		local idx = 1
		for i, v in ipairs(opts) do
			if v == row.value then
				idx = i
				break
			end
		end
		local new = idx + dir
		if new < 1 or new > #opts then
			return false -- at the first/last option — let the caller change tabs
		end
		row.value = opts[new]
		if row.run then
			row.run(row.value, nil, false)
		end
		if s.on_change then
			s.on_change(row)
		end
		s.render()
		return true
	end

	local function activate_row()
		local rrows = s.cur_rows()
		local row = rrows[s.row_cursor]
		if not row or not is_selectable(row) then
			return
		end
		-- Expandable rows (with children) toggle the accordion in place instead of
		-- acting: flip expanded, recompute heights, recentre and re-render.
		if row.children then
			row.expanded = not row.expanded
			-- Recompute heights, resize windows and clamp scroll/cursor so collapsing
			-- shrinks the window (no blank rows below) and scrolls back to the top.
			s.fit_view()
			s.render()
			return
		end

		local t = row.type or "string"

		if t == "bool" or t == "boolean" then
			row.value = not row.value
			if row.run then
				row.run(row.value)
			end
			if s.on_change then
				s.on_change(row)
			end
			s.render()
		elseif t == "select" then
			local opts2 = row.options or {}
			if #opts2 == 0 then
				return
			end
			local idx = 1
			for i, v in ipairs(opts2) do
				if v == row.value then
					idx = i
					break
				end
			end
			row.value = opts2[(idx % #opts2) + 1]
			if row.run then
				row.run(row.value)
			end
			if s.on_change then
				s.on_change(row)
			end
			s.render()
		elseif t == "int" or t == "integer" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					local n = tonumber(input)
					if n and math.floor(n) == n then
						row.value = n
						if row.run then
							row.run(n)
						end
						if s.on_change then
							s.on_change(row)
						end
						s.render()
					end
				end
			)
		elseif t == "float" or t == "number" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					local n = tonumber(input)
					if n then
						row.value = n
						if row.run then
							row.run(n)
						end
						if s.on_change then
							s.on_change(row)
						end
						s.render()
					end
				end
			)
		elseif t == "string" or t == "text" then
			vim.ui.input(
				{ prompt = (row.label or row.name or "") .. ": ", default = tostring(row.value or row.default or "") },
				function(input)
					if not input then
						return
					end
					row.value = input
					if row.run then
						row.run(input)
					end
					if s.on_change then
						s.on_change(row)
					end
					s.render()
				end
			)
		elseif t == "segmented" then
			if row.run then
				row.run(row.value, s.close, true)
			end
		elseif t == "action" then
			if row.run then
				row.run(row.value, s.close)
			end
		end
	end

	local function prev_select_option()
		local rrows = s.cur_rows()
		local row = rrows[s.row_cursor]
		if not row or row.type ~= "select" then
			return
		end
		local opts2 = row.options or {}
		if #opts2 == 0 then
			return
		end
		local idx = 1
		for i, v in ipairs(opts2) do
			if v == row.value then
				idx = i
				break
			end
		end
		local prev = idx - 1
		if prev < 1 then
			prev = #opts2
		end
		row.value = opts2[prev]
		if row.run then
			row.run(row.value)
		end
		if s.on_change then
			s.on_change(row)
		end
		s.render()
	end

	local function rows_snapshot()
		local snap = {}
		for _, t in ipairs(s.tabs) do
			for _, r in ipairs(t.rows or {}) do
				if r.name then
					snap[r.name] = r.value
				end
			end
		end
		return snap
	end

	local function first_tab_cursor()
		if s.horizontal_actions then
			local rrows = s.cur_rows()
			for i, r in ipairs(rrows) do
				if is_selectable(r) and r.type ~= "action" then
					return i
				end
			end
		end
		return first_selectable(s.cur_rows())
	end

	-- Per-tab saved position: tab_index → { row_cursor, scroll }
	local tab_state = {}

	local function do_tab_switch(from_tab)
		-- Save position of the tab we are leaving.
		if from_tab then
			tab_state[from_tab] = { row_cursor = s.row_cursor, scroll = s.scroll }
		end
		s.current_idx = 0
		-- Restore saved position for this tab, or default to first selectable.
		local saved = tab_state[s.active_tab]
		if saved then
			s.row_cursor = saved.row_cursor
			s.scroll = saved.scroll
		else
			s.row_cursor = first_tab_cursor()
			s.scroll = 0
		end
		s.recalc_heights()
		if s.position ~= "cursor" then
			s._row, s._col = calc_pos(s.total_height + (s._bh or 0), s.width + (s._bw or 0), s.position)
		end
		s.sync_layout()
		pcall(api.nvim_win_set_cursor, s.win, { 1, 0 })
		s.render()
		if s.on_item_change then
			local ci = s.cur_items()
			if ci and ci[s.current_idx + 1] then
				s.on_item_change(ci[s.current_idx + 1])
			end
		end
	end

	-- Tab-bar focus: when true, h/l switch between the tabs (Plugins / Treesitter /…)
	-- and j drops back into the content. Reached with k — or h on the first option —
	-- from the topmost content row.
	s.tab_focus = false

	--- Switch the active tab by `dir`, clamped. Returns false at the first/last tab.
	local function switch_tab(dir)
		local target = s.active_tab + dir
		if target < 1 or target > #s.tabs then
			return false
		end
		local from = s.active_tab
		s.active_tab = target
		do_tab_switch(from)
		return true
	end

	--- Move to the adjacent selectable row; if it is segmented, land on its first
	--- (or last) option. Returns false when there is no row to move to.

	-- keymaps
	map(k.tabs.next, function()
		local rr = s.cur_rows()
		if s.tab_focus then
			-- Last tab → drop down into the content; otherwise next tab.
			if not switch_tab(1) then
				s.tab_focus = false
				s.render()
			end
			return
		end
		local on_action = s.horizontal_actions and rr[s.row_cursor] and rr[s.row_cursor].type == "action"
		if on_action and move_action(1) then
			return
		end
		local seg = rr[s.row_cursor]
		if seg and seg.type == "segmented" then
			-- Cycle within the bar only (no flowing down to the next row).
			cycle_segment(seg, 1)
			return
		end
		if not s.lock_tabs then
			switch_tab(1)
		end
	end)
	map(k.tabs.prev, function()
		local rr = s.cur_rows()
		if s.tab_focus then
			switch_tab(-1) -- clamped at the first tab
			return
		end
		local on_action = s.horizontal_actions and rr[s.row_cursor] and rr[s.row_cursor].type == "action"
		if on_action and move_action(-1) then
			return
		end
		local seg = rr[s.row_cursor]
		if seg and seg.type == "segmented" then
			-- Cycle within the bar; at the first option focus the tab bar (no flowing
			-- up to the previous row).
			if not cycle_segment(seg, -1) and not s.lock_tabs then
				s.tab_focus = true
				s.render()
			end
			return
		end
		if not s.lock_tabs then
			switch_tab(-1)
		end
	end)

	-- Jump / page navigation (gg / G / <C-d> / <C-u>) for the vertical row list.
	local function set_cursor(idx)
		local rrows = s.cur_rows()
		if not rrows[idx] then
			return
		end
		s.row_cursor = idx
		if s.row_cursor < s.scroll + 1 then
			s.scroll = math.max(0, s.row_cursor - 1)
		elseif s.row_cursor > s.scroll + s.content_height then
			s.scroll = s.row_cursor - s.content_height
		end
		s.render()
	end
	local function jump_first()
		set_cursor(first_selectable(s.cur_rows()))
	end
	local function jump_last()
		local rrows = s.cur_rows()
		local i = #rrows
		while i >= 1 and not is_selectable(rrows[i]) do
			i = i - 1
		end
		if i >= 1 then
			set_cursor(i)
		end
	end
	local function page(dir)
		local step = math.max(1, math.floor(s.content_height / 2))
		local cur = s.row_cursor
		for _ = 1, step do
			local nxt = next_selectable(s.cur_rows(), cur, dir)
			if not nxt then
				break
			end
			cur = nxt
		end
		set_cursor(cur)
	end

	if s.tab_has_rows() then
		map(k.down, function()
			if s.tab_focus then
				s.tab_focus = false -- drop from the tab bar back into the content
				s.render()
				return
			end
			move_row(1)
		end)
		map(k.up, function()
			if s.tab_focus then
				return -- already on the tab bar
			end
			-- From the topmost selectable content row, focus the tab bar. This is "go
			-- up" navigation, so it stays available even when lock_tabs is set.
			if not next_selectable(s.cur_rows(), s.row_cursor, -1) then
				s.tab_focus = true
				s.render()
				return
			end
			move_row(-1)
		end)
		-- "t": toggle the tab bar. From the content, focus the tab bar (on the active
		-- tab, hiding the row's footer hints); press again to return to the saved
		-- content position (row_cursor is preserved while focused).
		map("t", function()
			s.tab_focus = not s.tab_focus
			s.render()
		end)
		map("gg", jump_first)
		map("G", jump_last)
		-- C-j / C-k skip past child/info rows to the next/prev primary row.
		local function jump_primary(dir)
			local rrows = s.cur_rows()
			local i = s.row_cursor + dir
			while i >= 1 and i <= #rrows do
				if is_selectable(rrows[i]) and not rrows[i].child then
					set_cursor(i)
					return
				end
				i = i + dir
			end
		end
		map("<C-j>", function()
			jump_primary(1)
		end)
		map("<C-k>", function()
			jump_primary(-1)
		end)
		map("<C-d>", function()
			page(1)
		end)
		map("<C-u>", function()
			page(-1)
		end)
		map(k.confirm, function()
			activate_row()
		end)
		map(k.list.next_option, function()
			activate_row()
		end)
		map(k.list.prev_option, function()
			prev_select_option()
		end)
		map(k.cancel, function()
			s.close(true, rows_snapshot())
		end)
		map(k.close, function()
			s.close(false, nil)
		end)
	else
		local function move_item(delta)
			local ci = s.cur_items()
			local new = s.current_idx + delta
			if new < 0 or new >= #ci then
				return
			end
			s.current_idx = new
			if s.current_idx < s.scroll then
				s.scroll = s.current_idx
			elseif s.current_idx >= s.scroll + s.content_height then
				s.scroll = s.current_idx - s.content_height + 1
			end
			s.render()
			if s.on_item_change then
				s.on_item_change(ci[s.current_idx + 1])
			end
		end
		map(k.down, function()
			move_item(1)
		end)
		map(k.up, function()
			move_item(-1)
		end)
		map(k.confirm, function()
			local item = s.cur_items()[s.current_idx + 1]
			s.close(true, { tab = s.active_tab, index = s.current_idx + 1, item = item })
		end)
		map(k.cancel, function()
			s.close(false, nil)
		end)
		map(k.close, function()
			s.close(false, nil)
		end)
	end

	-- Custom caller keymaps (e.g. footer action buttons): { lhs = fn | { fn, label } }.
	-- The fn receives s.close so an action can dismiss the popup: fn(close).
	if s.info_keymaps then
		for lhs, v in pairs(s.info_keymaps) do
			if type(lhs) == "string" then
				local fn = type(v) == "function" and v or (type(v) == "table" and v.fn)
				if type(fn) == "function" then
					map(lhs, function()
						fn(s.close)
					end)
				end
			end
		end
	end
end

return M
