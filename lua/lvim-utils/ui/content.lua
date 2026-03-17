-- lua/lvim-utils/ui/content.lua
-- Content section: rows (tabs mode), select/multiselect items, input placeholder.
-- Also covers the horizontal action bar in tabs mode.
local util = require("lvim-utils.ui.util")
local rows = require("lvim-utils.ui.rows")

local api = vim.api
local M = {}

-- ─── item range helpers ───────────────────────────────────────────────────────

--- Compute byte ranges for all parts of a rendered item line.
--- Returns checkbox_s, checkbox_e, icon_s, icon_e, text_s, text_e (0-based).
--- checkbox_s/e are nil for non-multiselect items.
---@return integer|nil, integer|nil, integer|nil, integer|nil, integer, integer
local function item_byte_ranges(item, ctx, ico)
	local icon = rows.item_icon(item)
	local lbl = rows.item_label(item)

	local indent = 2
	local checkbox_s, checkbox_e

	if ctx.mode == "multiselect" then
		local check = ctx.selected[item] and (type(item) == "table" and item.checked_icon or ico.multi_selected)
			or (type(item) == "table" and item.unchecked_icon or ico.multi_empty)
		checkbox_s = indent
		checkbox_e = indent + #check
	elseif ctx.current_item ~= nil and item == ctx.current_item then
		indent = 0
	end

	local prefix = checkbox_e and (checkbox_e + 1) or indent
	local icon_s, icon_e, text_s
	if icon then
		icon_s = prefix
		icon_e = icon_s + #icon
		text_s = icon_e + 1
	else
		text_s = prefix
	end
	return checkbox_s, checkbox_e, icon_s, icon_e, text_s, text_s + #lbl
end

--- Resolve the checkbox HlDef: per-item split > config checkbox_hl.
---@param item      string|SelectItem
---@param is_active boolean
---@param selected  boolean
---@param cfg       table
---@return HlDef|nil
local function resolve_checkbox_hl(item, is_active, selected, cfg)
	local ihl = rows.item_hl(item)
	local state = ihl and (is_active and ihl.active or ihl.inactive)
	if rows.item_hl_is_split(state) then
		---@cast state {checkbox?: HlDef, icon?: HlDef, text?: HlDef}
		return state.checkbox
	end
	local def = cfg.checkbox_hl
	if def then
		return selected and def.selected or def.empty
	end
	return selected and "LvimUiCheckboxSelected" or "LvimUiCheckboxEmpty"
end

--- Resolve the icon HlDef: per-item split > config item_hl.
---@param item      string|SelectItem
---@param is_active boolean
---@param cfg       table
---@return HlDef|nil
local function resolve_icon_hl(item, is_active, cfg)
	local ihl = rows.item_hl(item)
	local state = ihl and (is_active and ihl.active or ihl.inactive)
	if rows.item_hl_is_split(state) then
		---@cast state {checkbox?: HlDef, icon?: HlDef, text?: HlDef}
		return state.icon
	end
	local def = cfg.item_hl
	if def then
		local ds = is_active and def.active or def.inactive
		if ds and ds.icon then
			return ds.icon
		end
	end
	return is_active and "LvimUiItemIconActive" or "LvimUiItemIconInactive"
end

--- Resolve the text HlDef: per-item split > config item_hl > flat fallback.
---@param item      string|SelectItem
---@param is_active boolean
---@param cfg       table
---@return HlDef|nil
local function resolve_text_hl(item, is_active, cfg)
	local ihl = rows.item_hl(item)
	local state = ihl and (is_active and ihl.active or ihl.inactive)
	if rows.item_hl_is_split(state) then
		---@cast state {checkbox?: HlDef, icon?: HlDef, text?: HlDef}
		return state.text
	end
	if state then
		return state
	end -- flat HlDef → whole line / text
	local def = cfg.item_hl
	if def then
		local ds = is_active and def.active or def.inactive
		if ds and ds.text then
			return ds.text
		end
	end
	return is_active and "LvimUiItemTextActive" or "LvimUiItemTextInactive"
end

-- ─── build ────────────────────────────────────────────────────────────────────

--- Build content lines for the current mode.
--- Returns lines[], action_bar_ranges[], action_bar_offset.
--- action_bar_ranges entries: { s, e, row_abs }
---@param ctx table
---@return string[], table[], integer
function M.build(ctx)
	local lines = {}
	local action_bar_ranges = {}
	local action_bar_offset = 0
	local ico = ctx.cfg.icons or rows.icons()

	if ctx.mode == "input" then
		table.insert(lines, util.lpad(ctx.placeholder, ctx.width, 2))
	elseif ctx.mode == "tabs" and ctx.has_rows then
		local drows = ctx.horizontal_actions and ctx.content_rows or ctx.rows
		for i = 1, ctx.content_height do
			local row = drows[ctx.scroll + i]
			table.insert(lines, row and util.lpad(rows.row_display(row, ico), ctx.width, 2) or "")
		end

		-- horizontal action bar
		if ctx.horizontal_actions and ctx.action_bar_ht > 0 then
			local bar, col_b, col_w = "", 0, 0
			for i, ar in ipairs(ctx.action_rows) do
				local icon_str = ico.action
				local lbl_str = ar.label or ""
				local seg = " " .. icon_str .. " " .. lbl_str .. " "
				local s_b = col_b
				local row_abs = 0
				for ri, r in ipairs(ctx.rows) do
					if r == ar then
						row_abs = ri
						break
					end
				end
				table.insert(action_bar_ranges, {
					s = s_b,
					e = col_b + #seg,
					row_abs = row_abs,
					icon_s = s_b + 1,
					icon_e = s_b + 1 + #icon_str,
					text_s = s_b + 1 + #icon_str + 1,
					text_e = s_b + 1 + #icon_str + 1 + #lbl_str,
				})
				bar = bar .. seg
				col_b = col_b + #seg
				col_w = col_w + util.dw(seg)
				if i < #ctx.action_rows then
					local sep = "  │  "
					bar = bar .. sep
					col_b = col_b + #sep
					col_w = col_w + util.dw(sep)
				end
			end
			action_bar_offset = math.floor((ctx.width - col_w) / 2)
			table.insert(lines, util.center(bar, ctx.width))
		end
	elseif ctx.mode == "info" then
		for i = 1, ctx.content_height do
			table.insert(lines, ctx.items[ctx.scroll + i] or "")
		end
	else
		-- select / multiselect
		for i = 1, ctx.content_height do
			local item = ctx.items[ctx.scroll + i]
			if item then
				local lbl = rows.item_label(item)
				local icon = rows.item_icon(item)
				local icon_part = icon and (icon .. " ") or ""
				local line
				if ctx.mode == "multiselect" then
					local check = ctx.selected[item]
							and (type(item) == "table" and item.checked_icon or ico.multi_selected)
						or (type(item) == "table" and item.unchecked_icon or ico.multi_empty)
					line = util.lpad(check .. " " .. icon_part .. lbl, ctx.width, 2)
				elseif ctx.current_item ~= nil and item == ctx.current_item then
					line = util.lpad(ico.current .. " " .. icon_part .. lbl, ctx.width, 0)
				else
					line = util.lpad(icon_part .. lbl, ctx.width, 2)
				end
				table.insert(lines, line)
			else
				table.insert(lines, "")
			end
		end
	end

	return lines, action_bar_ranges, action_bar_offset
end

-- ─── apply_hl ─────────────────────────────────────────────────────────────────

--- Apply content highlights: cursor line, spacers, per-row/item hl, action bar.
---@param buf               integer
---@param ctx               table
---@param action_bar_ranges table[]
---@param action_bar_offset integer
function M.apply_hl(buf, ctx, action_bar_ranges, action_bar_offset)
	local NS = util.NS
	local resolve_hl = ctx.resolve_hl
	local hl_line = util.hl_line
	local cfg = ctx.cfg
	local ico = (cfg and cfg.icons) or rows.icons()

	if ctx.mode == "info" then
		if ctx.info_highlights then
			for _, hl in ipairs(ctx.info_highlights) do
				local row = ctx.header_height + hl.line - ctx.scroll
				if row >= ctx.header_height and row < ctx.header_height + ctx.content_height then
					local line_text  = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
					local col_start  = math.min(hl.col_start or 0, #line_text)
					local col_end    = (hl.col_end == nil or hl.col_end == -1) and #line_text or math.min(hl.col_end, #line_text)
					if col_start < col_end then
						api.nvim_buf_set_extmark(buf, NS, row, col_start, {
							end_col  = col_end,
							hl_group = resolve_hl(hl.group),
							priority = 210,
						})
					end
				end
			end
		end
	elseif ctx.mode == "input" then
		hl_line(buf, ctx.header_height, "LvimUiInput")
	elseif ctx.mode == "tabs" and ctx.has_rows then
		local drows = ctx.horizontal_actions and ctx.content_rows or ctx.rows
		local active_row = ctx.rows[ctx.row_cursor]

		for i = 1, ctx.content_height do
			local row = drows[ctx.scroll + i]
			local row_idx = ctx.header_height + i - 1
			if row then
				if row == active_row then
					local _line = api.nvim_buf_get_lines(buf, row_idx, row_idx + 1, false)[1] or ""
					api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
						end_col = #_line,
						hl_eol = true,
						hl_group = "LvimUiCursorLine",
						priority = 100,
					})
				elseif not rows.is_selectable(row) then
					hl_line(buf, row_idx, "LvimUiSpacer")
				end
				-- icon / text hl for selectable rows
				if rows.is_selectable(row) then
					local is_active = (row == active_row)
					local icon_str, sep_bytes = rows.row_icon_info(row, ico)
					local row_content = rows.row_display(row, ico)
					local icon_hl = is_active and "LvimUiRowIconActive" or "LvimUiRowIconInactive"
					local text_hl = is_active and "LvimUiRowTextActive" or "LvimUiRowTextInactive"
					if #icon_str > 0 then
						api.nvim_buf_set_extmark(buf, NS, row_idx, 2, {
							end_col = 2 + #icon_str,
							hl_group = resolve_hl(icon_hl),
							priority = 200,
						})
					end
					local text_s = 2 + #icon_str + sep_bytes
					if text_s < 2 + #row_content then
						api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
							end_col = 2 + #row_content,
							hl_group = resolve_hl(text_hl),
							priority = 200,
						})
					end
				end
				-- per-row flat hl override (priority 300 overrides icon/text defaults)
				if row.hl then
					local row_hl = (row == active_row) and row.hl.active or row.hl.inactive
					if row_hl then
						local row_content = rows.row_display(row, ico)
						api.nvim_buf_set_extmark(buf, NS, row_idx, 2, {
							end_col = 2 + #row_content,
							hl_group = resolve_hl(row_hl),
							priority = 300,
						})
					end
				end
			end
		end

		-- action bar: one extmark per button
		if ctx.horizontal_actions and #action_bar_ranges > 0 then
			local bar_lnum = ctx.header_height + ctx.content_height
			for _, seg in ipairs(action_bar_ranges) do
				local is_active = seg.row_abs == ctx.row_cursor
				local gbtn = cfg.button_hl
				local btn_hl = gbtn and (is_active and gbtn.active or gbtn.inactive)
				api.nvim_buf_set_extmark(buf, NS, bar_lnum, action_bar_offset + seg.s, {
					end_col = action_bar_offset + seg.e,
					hl_group = resolve_hl(btn_hl or (is_active and "LvimUiButtonActive" or "LvimUiButtonInactive")),
					priority = is_active and 900 or 200,
				})
				api.nvim_buf_set_extmark(buf, NS, bar_lnum, action_bar_offset + seg.icon_s, {
					end_col = action_bar_offset + seg.icon_e,
					hl_group = resolve_hl(is_active and "LvimUiButtonIconActive" or "LvimUiButtonIconInactive"),
					priority = is_active and 1000 or 300,
				})
				api.nvim_buf_set_extmark(buf, NS, bar_lnum, action_bar_offset + seg.text_s, {
					end_col = action_bar_offset + seg.text_e,
					hl_group = resolve_hl(is_active and "LvimUiButtonTextActive" or "LvimUiButtonTextInactive"),
					priority = is_active and 1000 or 300,
				})
			end
		end
	else
		-- select / multiselect
		for i = 1, ctx.content_height do
			local global = ctx.scroll + i - 1
			local row_idx = ctx.header_height + i - 1
			local item = ctx.items[global + 1]
			if item then
				local is_active = (global == ctx.current_idx)
				local _line = api.nvim_buf_get_lines(buf, row_idx, row_idx + 1, false)[1] or ""

				-- cursor line
				if is_active then
					api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
						end_col = #_line,
						hl_eol = true,
						hl_group = "LvimUiCursorLine",
						priority = 100,
					})
				end

				local checkbox_s, checkbox_e, icon_s, icon_e, text_s, text_e = item_byte_ranges(item, ctx, ico)

				-- checkbox hl (multiselect only)
				if checkbox_s then
					local selected = ctx.selected[item] and true or false
					local checkbox_hl = resolve_checkbox_hl(item, is_active, selected, cfg)
					if checkbox_hl then
						api.nvim_buf_set_extmark(buf, NS, row_idx, checkbox_s, {
							end_col = checkbox_e,
							hl_group = resolve_hl(checkbox_hl),
							priority = 200,
						})
					end
				end

				-- icon hl: per-item split override or config default
				local icon_hl = resolve_icon_hl(item, is_active, cfg)
				if icon_hl and icon_s then
					api.nvim_buf_set_extmark(buf, NS, row_idx, icon_s, {
						end_col = icon_e,
						hl_group = resolve_hl(icon_hl),
						priority = 200,
					})
				end

				-- text hl: split.text → text range; flat → whole line
				local text_hl = resolve_text_hl(item, is_active, cfg)
				if text_hl then
					local ihl_state = rows.item_hl(item)
					local state = ihl_state and (is_active and ihl_state.active or ihl_state.inactive)
					if rows.item_hl_is_split(state) then
						api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
							end_col = text_e,
							hl_group = resolve_hl(text_hl),
							priority = 300,
						})
					else
						api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
							end_col = #_line,
							hl_group = resolve_hl(text_hl),
							priority = 300,
						})
					end
				end
			end
		end
	end
end

return M
