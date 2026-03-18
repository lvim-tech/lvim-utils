-- lua/lvim-utils/quit/init.lua
-- Quit dialog for lvim-utils.
-- Opens a tabs popup listing all unsaved normal buffers as toggle rows.
-- The user can choose which files to save before quitting, quit without
-- saving, or cancel.  When there are no unsaved buffers, quits immediately.
--
-- Public API:
--   M.open(opts?) – open the quit dialog (or quit immediately if nothing is dirty)

local ui = require("lvim-utils.ui")

local M = {}

-- ─── helpers ──────────────────────────────────────────────────────────────────

---Write a buffer to disk, creating parent dirs as needed.
---@param bufnr integer
---@param fname? string  Defaults to buffer name.
---@return boolean  true when file exists on disk after write.
local function try_write(bufnr, fname)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	fname = fname or vim.api.nvim_buf_get_name(bufnr)
	if fname == "" then
		return false
	end
	local dir = vim.fn.fnamemodify(fname, ":h")
	if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not pcall(vim.fn.writefile, lines, fname) then
		return false
	end
	pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
	return vim.loop.fs_stat(fname) ~= nil
end

--- Issue :qa or :qa! depending on whether any buffer is still dirty.
--- When `saved` is provided, only checks the buffers that were in the
--- original unsaved list; otherwise scans all loaded normal buffers.
---@param saved           table<integer, boolean>|nil  bufnr → write result map
---@param unsaved_buffers integer[]                    original list of dirty buffers
local function finalize_quit(saved, unsaved_buffers)
	local dirty = false
	if saved then
		for _, b in ipairs(unsaved_buffers) do
			if vim.api.nvim_buf_is_valid(b) and vim.bo[b].modified then
				if not saved[b] then
					dirty = true
					break
				end
			end
		end
	else
		for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
			if info.changed == 1 and vim.bo[info.bufnr].buftype == "" then
				dirty = true
				break
			end
		end
	end
	vim.cmd(dirty and "qa!" or "qa")
end

-- ─── public API ───────────────────────────────────────────────────────────────

---Open the quit dialog. Quits immediately when there are no unsaved buffers.
---@param opts? { confirm?: boolean }  confirm=false skips the dialog and forces :qa!
function M.open(opts)
	opts = opts or {}

	-- Collect unsaved normal buffers.
	local unsaved = {}
	for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
		local b = info.bufnr
		if info.changed == 1 and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "" then
			table.insert(unsaved, b)
		end
	end

	-- Fast path.
	if #unsaved == 0 then
		vim.cmd("qa")
		return
	end

	-- Build rows: one bool per unsaved buffer, then a separator, then actions.
	local rows = {}

	for _, b in ipairs(unsaved) do
		local name = vim.api.nvim_buf_get_name(b)
		if name == "" then
			name = "[No Name #" .. b .. "]"
		end
		table.insert(rows, {
			type = "bool",
			name = tostring(b),
			label = name,
			value = true, -- selected for saving by default
		})
	end

	table.insert(rows, { type = "spacer_line" })

	-- "Save Selected & Quit"
	table.insert(rows, {
		type = "action",
		label = "Save Selected & Quit",
		run = function(_, close_fn)
			-- Snapshot which buffers are selected before the popup closes.
			local named, unnamed = {}, {}
			for _, r in ipairs(rows) do
				if r.type == "bool" then
					local b = tonumber(r.name)
					if b and r.value and vim.api.nvim_buf_is_valid(b) and vim.bo[b].modified then
						if vim.api.nvim_buf_get_name(b) ~= "" then
							table.insert(named, b)
						else
							table.insert(unnamed, b)
						end
					end
				end
			end

			close_fn(true, nil)

			vim.schedule(function()
				local saved = {}

				-- Write named buffers immediately.
				for _, b in ipairs(named) do
					saved[b] = try_write(b)
					if not saved[b] then
						vim.notify("Failed to write: " .. vim.api.nvim_buf_get_name(b), vim.log.levels.ERROR)
					end
				end

				-- Prompt for a path for each unnamed buffer.
				local function prompt_unnamed(idx)
					if idx > #unnamed then
						finalize_quit(saved, unsaved)
						return
					end
					local b = unnamed[idx]
					if not vim.api.nvim_buf_is_valid(b) or not vim.bo[b].modified then
						saved[b] = true
						prompt_unnamed(idx + 1)
						return
					end
					vim.ui.input({ prompt = "Save [No Name #" .. b .. "] as: " }, function(input)
						if not input or input == "" then
							saved[b] = false
						else
							local path = vim.fn.expand(input)
							if not vim.startswith(path, "/") then
								path = vim.fn.getcwd() .. "/" .. path
							end
							if pcall(vim.api.nvim_buf_set_name, b, path) then
								saved[b] = try_write(b, path)
								if not saved[b] then
									vim.notify("Failed to write: " .. path, vim.log.levels.ERROR)
								end
							else
								saved[b] = false
								vim.notify("Failed to set buffer name", vim.log.levels.ERROR)
							end
						end
						prompt_unnamed(idx + 1)
					end)
				end

				prompt_unnamed(1)
			end)
		end,
	})

	-- "Quit without Saving"
	table.insert(rows, {
		type = "action",
		label = "Quit without Saving",
		run = function(_, close_fn)
			close_fn(true, nil)
			vim.schedule(function()
				vim.cmd("qa!")
			end)
		end,
	})

	-- "Cancel"
	table.insert(rows, {
		type = "action",
		label = "Cancel",
		run = function(_, close_fn)
			close_fn(false, nil)
		end,
	})

	ui.tabs({
		title = "Quit",
		subtitle = #unsaved .. " file(s) with unsaved changes",
		tabs = { { label = "Unsaved Files", rows = rows } },
		callback = function() end,
	})
end

return M
