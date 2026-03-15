-- lua/lvim-utils/ui/mode/info.lua
-- Info mode: read-only (default) or editable floating window.
local api = vim.api
local M = {}

local function make_readonly(buf, ko)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modified = false
	vim.bo[buf].buftype = "nofile"
	for _, k in ipairs({ "a", "i", "o", "A", "I", "O", "c", "C", "d", "D", "s", "S", "r", "R", "x", "X", "p", "P", "<Del>" }) do
		vim.keymap.set("n", k, "<Nop>", ko)
	end
	for _, k in ipairs({ "d", "c", "x", "p" }) do
		vim.keymap.set("v", k, "<Nop>", ko)
	end
end

local function setup_horizontal_lock(buf, win)
	local aug = api.nvim_create_augroup("LvimInfoHLock_" .. buf, { clear = true })
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = aug,
		buffer = buf,
		callback = function()
			if not api.nvim_win_is_valid(win) then
				return
			end
			local pos = api.nvim_win_get_cursor(win)
			if pos[2] > 0 then
				api.nvim_win_set_cursor(win, { pos[1], 0 })
			end
		end,
	})
end

function M.attach(s)
	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, s.ko)
	end
	local cfg = s.cfg

	-- shared syncing flag (used by move and editable handlers)
	local syncing = false

	-- cursor + scroll navigation (same logic for both readonly and editable)
	s.info_line = 1
	local function move(delta)
		local total = math.max(1, #s.items)
		s.info_line = math.max(1, math.min(s.info_line + delta, total))
		if s.info_line > s.scroll + s.content_height then
			s.scroll = s.info_line - s.content_height
		end
		if s.info_line <= s.scroll then
			s.scroll = s.info_line - 1
		end
		syncing = true
		s.render()
		syncing = false
		if not s.info_readonly then
			local row = s.header_height + (s.info_line - s.scroll)
			pcall(api.nvim_win_set_cursor, s.win, { row, 0 })
		end
	end
	map(cfg.keys.down, function()
		move(1)
	end)
	map(cfg.keys.up, function()
		move(-1)
	end)

	-- extended navigation
	local function half() return math.max(1, math.floor(s.content_height / 2)) end
	map("gg", function() move(1 - s.info_line) end)
	map("G",  function() move(#s.items - s.info_line) end)
	map("<C-d>", function() move(half()) end)
	map("<C-u>", function() move(-half()) end)
	map("<C-f>", function() move(s.content_height) end)
	map("<C-b>", function() move(-s.content_height) end)

	-- close
	for _, k in ipairs(s.close_keys) do
		map(k, function()
			s.close(false, nil)
		end)
	end

	-- readonly
	if s.info_readonly then
		make_readonly(s.buf, s.ko)
		setup_horizontal_lock(s.buf, s.win)
		for _, km in ipairs({ { "l", "<Nop>" }, { "<Right>", "<Nop>" }, { "$", "<Nop>" }, { "^", "0" } }) do
			map(km[1], km[2])
		end
	else
		local ok, cursor_mod = pcall(require, "lvim-utils.cursor")
		if ok then
			cursor_mod.mark_input_buffer(s.buf, true)
		end
	end

	-- extra window options
	api.nvim_set_option_value("concealcursor", "nvic", { win = s.win })
	api.nvim_set_option_value("conceallevel", 2, { win = s.win })

	-- folds
	if s.info_folds and #s.info_folds > 0 then
		api.nvim_set_option_value("foldmethod", "manual", { win = s.win })
		api.nvim_set_option_value("foldenable", true, { win = s.win })
		local sorted = vim.tbl_filter(function(f)
			return f.start_line and f.end_line
		end, s.info_folds)
		table.sort(sorted, function(a, b)
			return (a.end_line - a.start_line) < (b.end_line - b.start_line)
		end)
		for _, fold in ipairs(sorted) do
			pcall(api.nvim_win_call, s.win, function()
				vim.cmd(string.format([[%d,%dfold]], fold.start_line + 1, fold.end_line + 1))
			end)
		end
	end

	-- editable: all structural changes (add/remove lines) go through our
	-- handlers so s.items stays in sync and the buffer never grows beyond
	-- header + content_height + footer. Character edits on existing lines
	-- are handled natively; we sync just the changed line on TextChanged.
	if not s.info_readonly then
		local aug = api.nvim_create_augroup("LvimInfoEdit_" .. s.buf, { clear = true })

		-- clamp cursor to content area
		api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = aug,
			buffer = s.buf,
			callback = function()
				if not api.nvim_win_is_valid(s.win) then
					return
				end
				local total = api.nvim_buf_line_count(s.buf)
				local pos = api.nvim_win_get_cursor(s.win)
				local clamped = math.max(s.header_height + 1, math.min(pos[1], total - s.footer_height))
				if clamped ~= pos[1] then
					api.nvim_win_set_cursor(s.win, { clamped, pos[2] })
				end
			end,
		})

		-- 1-based index of cursor line within s.items (accounts for scroll)
		local function item_idx()
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			if not ok then
				return 1
			end
			return s.scroll + math.max(1, pos[1] - s.header_height)
		end

		-- insert a line into s.items, scroll if needed, render, position cursor
		local function insert_at(idx, text)
			idx = math.max(1, math.min(idx, #s.items + 1))
			table.insert(s.items, idx, text or "")
			if idx > s.scroll + s.content_height then
				s.scroll = idx - s.content_height
			elseif idx <= s.scroll then
				s.scroll = math.max(0, idx - 1)
			end
			s.info_line = idx
			syncing = true
			s.render()
			syncing = false
			local row = s.header_height + (idx - s.scroll)
			pcall(api.nvim_win_set_cursor, s.win, { row, 0 })
		end

		-- o: open line below
		map("o", function()
			local li = item_idx()
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			if ok then
				s.items[li] = api.nvim_buf_get_lines(s.buf, pos[1] - 1, pos[1], false)[1] or ""
			end
			insert_at(li + 1, "")
			vim.cmd("startinsert!")
		end)

		-- O: open line above
		map("O", function()
			insert_at(item_idx(), "")
			vim.cmd("startinsert!")
		end)

		-- <CR> in insert mode: split current line at cursor column
		vim.keymap.set("i", "<CR>", function()
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			if not ok then
				return
			end
			local li = s.scroll + math.max(1, pos[1] - s.header_height)
			local col = pos[2]
			local cur = api.nvim_buf_get_lines(s.buf, pos[1] - 1, pos[1], false)[1] or ""
			s.items[li] = cur:sub(1, col)
			insert_at(li + 1, cur:sub(col + 1))
			-- still in insert mode after render(); just reposition cursor
		end, s.ko)

		-- dd: delete current line from s.items
		map("dd", function()
			if #s.items == 0 then
				return
			end
			local li = item_idx()
			table.remove(s.items, li)
			s.scroll = math.max(0, math.min(s.scroll, math.max(0, #s.items - s.content_height)))
			s.info_line = math.max(1, math.min(li, #s.items))
			syncing = true
			s.render()
			syncing = false
			local row = s.header_height + math.max(1, s.info_line - s.scroll)
			pcall(api.nvim_win_set_cursor, s.win, { row, 0 })
		end)

		-- visual d: delete selected lines from s.items
		vim.keymap.set("v", "d", function()
			local ok, cur = pcall(api.nvim_win_get_cursor, s.win)
			if not ok then return end
			local vstart = vim.fn.line("v")
			local vend   = cur[1]
			if vstart > vend then vstart, vend = vend, vstart end
			local i1 = math.max(1, s.scroll + (vstart - s.header_height))
			local i2 = math.min(#s.items, s.scroll + (vend   - s.header_height))
			for _ = i1, i2 do
				table.remove(s.items, i1)
			end
			s.scroll = math.max(0, math.min(s.scroll, math.max(0, #s.items - s.content_height)))
			s.info_line = math.max(1, math.min(i1, #s.items))
			syncing = true
			s.render()
			syncing = false
			local row = s.header_height + math.max(1, s.info_line - s.scroll)
			pcall(api.nvim_win_set_cursor, s.win, { row, 0 })
		end, s.ko)

		-- sync all visible content lines from buffer → s.items, then re-render
		-- to restore header/footer extmarks (lost after undo/redo).
		local function sync_visible()
			local total    = api.nvim_buf_line_count(s.buf)
			local cnt      = math.min(total - s.footer_height, s.header_height + s.content_height)
			local buf_lines = api.nvim_buf_get_lines(s.buf, s.header_height, cnt, false)
			for i, line in ipairs(buf_lines) do
				s.items[s.scroll + i] = line
			end
			syncing = true
			local ok, pos = pcall(api.nvim_win_get_cursor, s.win)
			s.render()
			syncing = false
			if ok then pcall(api.nvim_win_set_cursor, s.win, pos) end
		end

		api.nvim_create_autocmd("TextChanged", {
			group = aug,
			buffer = s.buf,
			callback = function()
				if not syncing then
					sync_visible()
				end
			end,
		})

		api.nvim_create_autocmd("TextChangedI", {
			group = aug,
			buffer = s.buf,
			callback = function()
				if syncing then
					return
				end
				sync_visible()
				vim.schedule(function()
					if api.nvim_buf_is_valid(s.buf) then
						s.recalc_win_height()
					end
				end)
			end,
		})
	end

	-- markview: render only content rows (header_height .. header_height+content_height)
	-- so header/footer are not touched, and hybrid_mode is bypassed entirely.
	if s.info_markview then
		local p_ok, mv_parser   = pcall(require, "markview.parser")
		local r_ok, mv_renderer = pcall(require, "markview.renderer")
		local a_ok, mv_actions  = pcall(require, "markview.actions")
		if p_ok and r_ok then
			vim.bo[s.buf].filetype = "markdown"
			local function mv_render()
				if a_ok then pcall(mv_actions.clear, s.buf) end
				local start_row = s.header_height
				local end_row   = s.header_height + s.content_height
				local ok2, content = pcall(mv_parser.parse, s.buf, start_row, end_row, true)
				if ok2 and content then
					pcall(mv_renderer.render, s.buf, content)
				end
			end
			local orig_render = s.render
			s.render = function()
				orig_render()
				mv_render()
			end
			mv_render()
		end
	end

	-- custom keymaps: { ["<key>"] = fn } or { ["<key>"] = { fn = fn, label = "..." } }
	if s.info_keymaps then
		for lhs, v in pairs(s.info_keymaps) do
			if type(lhs) == "string" then
				local fn = type(v) == "function" and v or (type(v) == "table" and v.fn)
				if type(fn) == "function" then
					vim.keymap.set("n", lhs, fn, s.ko)
				end
			end
		end
	end

	-- initial cursor
	pcall(api.nvim_win_set_cursor, s.win, { s.header_height + 1, 0 })
end

return M
