-- lua/lvim-utils/ui/footer.lua
-- Footer text computation and footer highlight application.
local util = require("lvim-utils.ui.util")

local api = vim.api
local M = {}

-- ─── hints ────────────────────────────────────────────────────────────────────

--- Returns ordered list of {key, label} pairs for the footer hint.
---@param ctx table
---@return table[]
function M.hints(ctx)
	local c = ctx.cfg or util.cfg()
	local k = c.keys
	local l = c.labels
	local mode = ctx.mode
	local back = ctx.back_key and { key = ctx.back_key, label = "back" } or nil
	-- In the tabbed view, "t" toggles the tab bar (focus / back to content).
	local menu = (mode == "tabs" and ctx.has_rows) and { key = "t", label = "menu" } or nil
	local function with_back(hints)
		if not menu and not back then
			return hints
		end
		local out = {}
		for _, h in ipairs(hints) do
			table.insert(out, h)
		end
		if menu then
			table.insert(out, menu)
		end
		if back then
			table.insert(out, back)
		end
		return out
	end

	if mode == "input" then
		return {
			{ key = k.confirm, label = l.confirm },
			{ key = k.cancel, label = l.cancel },
		}
	elseif mode == "multiselect" then
		return {
			{ key = k.multiselect.toggle, label = l.toggle },
			{ key = k.multiselect.confirm, label = l.confirm },
			{ key = k.multiselect.cancel, label = l.cancel },
		}
	elseif mode == "tabs" then
		if ctx.tab_focus then
			-- On the tab bar: only tab navigation — the current row's hints are hidden.
			return {
				{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.tabs },
				{ key = k.down, label = l.navigate },
				{ key = "t", label = "menu" },
				{ key = k.cancel, label = l.close },
			}
		end
		if ctx.has_rows then
			if ctx.horizontal_actions then
				local cur = ctx.rows[ctx.row_cursor]
				if cur and cur.type == "action" then
					return with_back({
						{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.navigate },
						{ key = k.confirm, label = l.execute },
						{ key = k.cancel, label = l.close },
					})
				end
			end
			local row = ctx.rows[ctx.row_cursor]
			local t = row and row.type or ""
			if t == "bool" or t == "boolean" then
				return with_back({
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.toggle },
					{ key = k.cancel, label = l.close },
				})
			elseif t == "select" then
				return with_back({
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm .. "/" .. k.list.prev_option, label = l.cycle },
					{ key = k.cancel, label = l.close },
				})
			elseif t == "int" or t == "integer" or t == "float" or t == "number" or t == "string" or t == "text" then
				return with_back({
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.edit },
					{ key = k.cancel, label = l.close },
				})
			elseif t == "action" then
				return with_back({
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.execute },
					{ key = k.cancel, label = l.close },
				})
			else
				return with_back({
					{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.tabs },
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.cancel, label = l.close },
				})
			end
		else
			return with_back({
				{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.tabs },
				{ key = k.down .. "/" .. k.up, label = l.navigate },
				{ key = k.confirm, label = l.confirm },
				{ key = k.cancel, label = l.cancel },
			})
		end
	elseif mode == "info" then
		return with_back({
			{ key = k.down .. "/" .. k.up, label = l.navigate },
			{ key = k.cancel, label = l.close },
		})
	else -- select
		return with_back({
			{ key = k.down .. "/" .. k.up, label = l.navigate },
			{ key = k.select.confirm, label = l.confirm },
			{ key = k.select.cancel, label = l.cancel },
		})
	end
end

-- ─── assemble ─────────────────────────────────────────────────────────────────

--- Assemble hint list into a text string and byte ranges.
---@param hints table[]
---@return string  text
---@return table[] ranges  {s, e, kind="key"|"label"}
local function assemble(hints)
	local text = ""
	local ranges = {}
	for i, h in ipairs(hints) do
		-- Key and label are each their own padded box: 1 space front and back inside the span.
		local key_s = #text
		text = text .. " " .. h.key .. " "
		table.insert(ranges, { s = key_s, e = #text, kind = "key", hl = h.key_hl })
		local lbl_s = #text
		text = text .. " " .. h.label .. " "
		table.insert(ranges, { s = lbl_s, e = #text, kind = "label", hl = h.label_hl })
		if i < #hints then
			text = text .. " " -- gap between hints (plus each badge's own padding)
		end
	end
	return text, ranges
end

-- ─── max_width ────────────────────────────────────────────────────────────────

--- Maximum possible footer width, used for layout calculation before render.
---@param mode     string
---@param has_rows boolean
---@return integer
function M.max_width(mode, has_rows, cfg_override)
	local row_types = (mode == "tabs" and has_rows) and { "bool", "select", "int", "action", "" } or { nil }
	local max_w = 0
	for _, t in ipairs(row_types) do
		local pseudo = {
			mode = mode,
			has_rows = has_rows,
			horizontal_actions = false,
			row_cursor = 1,
			rows = t and { { type = t } } or {},
			cfg = cfg_override,
		}
		local text = assemble(M.hints(pseudo))
		max_w = math.max(max_w, util.dw(text))
	end
	if max_w == 0 then
		local pseudo = {
			mode = mode,
			has_rows = has_rows,
			horizontal_actions = false,
			row_cursor = 1,
			rows = {},
			cfg = cfg_override,
		}
		local text = assemble(M.hints(pseudo))
		max_w = util.dw(text)
	end
	return max_w
end

-- ─── compose (single line / column grid) ─────────────────────────

--- Lay the hints out into footer line(s). When they fit on one line it stays a single
--- centred row (classic behaviour, unchanged). When they overflow the popup width they
--- wrap into an aligned column grid: every cell is padded to the widest "key label" so
--- the columns line up across rows. Returns the hint line strings (not the empty /
--- separator rows) and ranges tagged with their 1-based row.
---@param ctx table
---@return string[] lines
---@return table[]  ranges  {row, s, e, kind, hl}
local function compose(ctx)
	local hints = ctx.hints or M.hints(ctx)
	local width = ctx.width

	-- classic single centred line when everything fits (or only one hint)
	local text, ranges = assemble(hints)
	if #hints <= 1 or util.dw(text) <= width then
		local offset = math.max(0, math.floor((width - util.dw(text)) / 2))
		local out = {}
		for _, r in ipairs(ranges) do
			out[#out + 1] = { row = 1, s = offset + r.s, e = offset + r.e, kind = r.kind, hl = r.hl }
		end
		return { util.center(text, width) }, out
	end

	-- overflow -> aligned column grid (row-major fill, PER-COLUMN widths so the grid packs
	-- tighter than a uniform cell width while columns still line up across rows).
	local GUT = 3 -- gap between columns
	local n = #hints
	local cellw = {} -- display width of each "key label" cell
	for i, h in ipairs(hints) do
		-- " <key> " + " <label> " (each padded 1 space front + back)
		cellw[i] = util.dw(h.key) + util.dw(h.label) + 4
	end

	-- For a given column count, each column's width is the max cell among the hints that
	-- land in it (row-major: hint i → column (i-1) % ncols). Use the most columns whose
	-- summed widths (+ gutters) still fit the popup.
	local function layout(ncols)
		local colw = {}
		for i = 1, n do
			local col = (i - 1) % ncols
			colw[col] = math.max(colw[col] or 0, cellw[i])
		end
		local total = GUT * (ncols - 1)
		for c = 0, ncols - 1 do
			total = total + (colw[c] or 0)
		end
		return colw, total
	end

	local ncols = n
	local colw, total = layout(ncols)
	while ncols > 1 and total > width do
		ncols = ncols - 1
		colw, total = layout(ncols)
	end
	local nrows = math.ceil(n / ncols)
	local lead = math.max(0, math.floor((width - total) / 2))

	local line_text = {}
	for i = 1, nrows do
		line_text[i] = string.rep(" ", lead)
	end
	local out = {}
	for i, h in ipairs(hints) do
		local row = math.floor((i - 1) / ncols) + 1
		local col = (i - 1) % ncols
		local cur = line_text[row]
		local key_s = #cur
		cur = cur .. " " .. h.key .. " " -- key badge: 1 space front + back
		out[#out + 1] = { row = row, s = key_s, e = #cur, kind = "key", hl = h.key_hl }
		local lbl_s = #cur
		cur = cur .. " " .. h.label .. " " -- label badge: 1 space front + back
		out[#out + 1] = { row = row, s = lbl_s, e = #cur, kind = "label", hl = h.label_hl }
		if col < ncols - 1 then
			cur = cur .. string.rep(" ", (colw[col] or 0) - cellw[i] + GUT)
		end
		line_text[row] = cur
	end
	return line_text, out
end

-- ─── build / hl ─────────────────────────────────────────────────────────────

--- Build the footer lines (empty + separator + 1..n hint rows) and per-row ranges.
---@param ctx table  Pass ctx.hints directly to skip mode-based hint resolution.
---@return string[] lines
---@return table[]  hint_ranges  {row, s, e, kind, hl}
function M.build(ctx)
	local grid, ranges = compose(ctx)
	local lines = { "", string.rep("─", ctx.width) }
	for _, l in ipairs(grid) do
		lines[#lines + 1] = l
	end
	return lines, ranges
end

--- Number of hint rows the footer will render (1 normally, more when wrapped). The popup
--- uses this to reserve the footer window height before render.
---@param ctx table
---@return integer
function M.hint_rows(ctx)
	local grid = compose(ctx)
	return #grid
end

--- Apply footer highlights: separator line, base footer hl, key/label extmarks.
---@param buf         integer
---@param total_lines integer
---@param hint_ranges table[]
---@param ctx         table
function M.apply_hl(buf, total_lines, hint_ranges, ctx)
	local NS = util.NS
	local resolve_hl = ctx.resolve_hl
	local cfg = ctx.cfg
	local footer_hl = cfg.footer_hl or {}

	-- the hint grid occupies the last `nrows` lines; the separator sits just above it
	local nrows = 1
	for _, r in ipairs(hint_ranges or {}) do
		nrows = math.max(nrows, r.row or 1)
	end
	local first = total_lines - nrows -- 0-based line of grid row 1
	util.hl_line(buf, first - 1, "LvimUiSeparator")

	-- No full-width footer background: it drew a lighter bar from edge to edge. The footer line
	-- keeps the panel background; only the key/label hint spans below carry a tint.

	for _, r in ipairs(hint_ranges or {}) do
		local lnum = first + (r.row or 1) - 1
		local line = api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
		local default = r.kind == "key" and (footer_hl.key or "LvimUiFooterKey")
			or (footer_hl.label or "LvimUiFooterLabel")
		local group = resolve_hl(r.hl or default)
		-- clamp to the rendered line so a narrow popup can never produce an out-of-range col
		local s_col = math.max(0, math.min(r.s, #line))
		local e_col = math.max(0, math.min(r.e, #line))
		if e_col > s_col then
			api.nvim_buf_set_extmark(buf, NS, lnum, s_col, {
				end_col = e_col,
				hl_group = group,
				priority = 300,
			})
		end
	end
end

return M
