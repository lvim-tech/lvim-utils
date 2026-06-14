-- lua/lvim-utils/ui/header.lua
-- Header section: tab bar (tabs mode) or title/subtitle/info block.
local util = require("lvim-utils.ui.util")

local api = vim.api
local M = {}

-- ─── build ────────────────────────────────────────────────────────────────────

--- Build header lines for the current mode.
--- Returns the lines array, tab_ranges table, and centered_offset integer.
--- tab_ranges entries: { active, s, e, tab_hl }
---@param ctx table
---@return string[], table[], integer
function M.build(ctx)
	local lines = {}
	local tab_ranges = {}
	local centered_offset = 0

	if ctx.mode == "tabs" then
		-- optional meta block (title / subtitle / info) above the tab bar
		for _, l in ipairs(ctx.meta_lines) do
			table.insert(lines, l == "" and "" or util.center(l, ctx.width))
		end
		if #ctx.meta_lines > 0 then
			table.insert(lines, "")
		end

		-- tab bar — windowed horizontal scroll. When the full bar is wider than the
		-- popup, only the run of tabs around the active one that fits is rendered, flanked
		-- by   chevrons marking hidden tabs. The per-tab byte ranges are built from the
		-- rendered slice (not the full bar), so centered_offset stays >= 0 and end_col can no
		-- longer run past the line — apply_hl also clamps defensively.
		local CHEVRON_L, CHEVRON_R = "", ""
		local lbls, dws = {}, {}
		for i, t in ipairs(ctx.tabs) do
			local icon_str = t.icon or ""
			-- Icon and text are each their own padded block ("  <x>  ", 2 spaces front and back) —
			-- Nerd glyphs read wider than one cell, so the coloured boxes need the breathing room.
			local icon_part = icon_str ~= "" and ("  " .. icon_str .. "  ") or ""
			local text_part = "  " .. (t.label or ("Tab " .. i)) .. "  "
			lbls[i] = icon_part .. text_part
			dws[i] = util.dw(lbls[i])
		end
		local n = #ctx.tabs
		local total = 0
		for i = 1, n do
			total = total + dws[i]
		end

		-- visible window [lo, hi] (the whole bar when it already fits)
		local lo, hi = 1, n
		if total > ctx.width and n > 0 then
			local budget = ctx.width - 6 -- room for the two flanking " <chevron> " boxes
			local active = math.max(1, math.min(ctx.active_tab, n))
			lo, hi = active, active
			local used = dws[active]
			while true do
				local grew = false
				if hi < n and used + dws[hi + 1] <= budget then
					hi = hi + 1
					used = used + dws[hi]
					grew = true
				end
				if lo > 1 and used + dws[lo - 1] <= budget then
					lo = lo - 1
					used = used + dws[lo]
					grew = true
				end
				if not grew then
					break
				end
			end
		end

		local left_more = lo > 1
		local right_more = hi < n

		-- assemble the windowed bar, recording byte ranges on the rendered string
		-- Chevron boxes get 1 space front and back inside their span (like the tab icons).
		local left_box = left_more and (" " .. CHEVRON_L .. " ") or ""
		local tab_bar = left_box
		if left_more then
			table.insert(tab_ranges, { chevron = true, s = 0, e = #left_box })
		end
		for i = lo, hi do
			local t = ctx.tabs[i]
			local icon_str = t.icon or ""
			local lbl_str = t.label or ("Tab " .. i)
			-- Must match the lbls[] construction above (padded "  <x>  " blocks).
			local icon_part = icon_str ~= "" and ("  " .. icon_str .. "  ") or ""
			local lbl = lbls[i]
			local start = #tab_bar
			local icon_s, icon_e
			if icon_str ~= "" then
				-- Icon block = the whole padded icon_part (2 spaces + icon + 2 spaces).
				icon_s = start
				icon_e = start + #icon_part
			end
			-- Text block = its whole padded "  <label>  " box, so its tint covers the spaces too.
			local text_s = start + #icon_part
			local text_e = text_s + 2 + #lbl_str + 2
			table.insert(tab_ranges, {
				active = (i == ctx.active_tab),
				s = start,
				e = start + #lbl,
				tab_hl = t.tab_hl,
				icon_s = icon_s,
				icon_e = icon_e,
				text_s = text_s,
				text_e = text_e,
			})
			tab_bar = tab_bar .. lbl
		end
		if right_more then
			local cs = #tab_bar -- box starts at the leading space
			tab_bar = tab_bar .. " " .. CHEVRON_R .. " "
			table.insert(tab_ranges, { chevron = true, s = cs, e = #tab_bar })
		end
		centered_offset = math.max(0, math.floor((ctx.width - util.dw(tab_bar)) / 2))
		table.insert(lines, util.center(tab_bar, ctx.width))
		table.insert(lines, "")
		table.insert(lines, string.rep("─", ctx.width))
		table.insert(lines, "")
	else
		-- non-tabs: title / subtitle / info block
		for _, l in ipairs(ctx.header_lines) do
			table.insert(lines, l == "" and "" or util.center(l, ctx.width))
		end
		if #ctx.header_lines > 0 then
			table.insert(lines, "")
			table.insert(lines, string.rep("─", ctx.width))
			table.insert(lines, "")
		end
	end

	return lines, tab_ranges, centered_offset
end

-- ─── apply_hl ─────────────────────────────────────────────────────────────────

--- Apply header highlights.
---@param buf             integer
---@param ctx             table
---@param tab_ranges      table[]
---@param centered_offset integer
function M.apply_hl(buf, ctx, tab_ranges, centered_offset)
	local NS = util.NS
	local resolve_hl = ctx.resolve_hl
	local merge_bg = util.merge_bg
	local hl_line = util.hl_line
	local cfg = ctx.cfg

	-- Apply hl only over the centered text (not the full line).
	local function hl_centered(row, text, group)
		if not group or not text or text == "" then
			return
		end
		local text_start = math.floor((ctx.width - util.dw(text)) / 2)
		local col_s = math.max(0, text_start - 1)
		local col_e = math.min(ctx.width, text_start + #text + 1)
		api.nvim_buf_set_extmark(buf, NS, row, col_s, {
			end_col = col_e,
			hl_group = group,
			priority = 200,
		})
	end

	-- Title line: when it carries an icon (popup built it as "  <icon>  " .. "  <title>  "),
	-- split the centred line into an icon box (LvimUiTitleIcon) and a text box (LvimUiTitle);
	-- otherwise colour the whole padded title with LvimUiTitle.
	local function hl_title(row, line)
		if not line or line == "" then
			return
		end
		if ctx.title_icon and ctx.title_icon ~= "" then
			-- No centre bleed here (unlike hl_centered): the icon/text blocks already carry their
			-- own 2-space padding, so a left bleed would make the icon's leading look bigger.
			local ts = math.floor((ctx.width - util.dw(line)) / 2)
			local split = ts + #("  " .. ctx.title_icon .. "  ")
			api.nvim_buf_set_extmark(buf, NS, row, math.max(0, ts), {
				end_col = math.min(ctx.width, split),
				hl_group = resolve_hl("LvimUiTitleIcon"),
				priority = 200,
			})
			api.nvim_buf_set_extmark(buf, NS, row, math.min(ctx.width, split), {
				end_col = math.min(ctx.width, ts + #line),
				hl_group = resolve_hl(ctx.title_hl or "LvimUiTitle"),
				priority = 200,
			})
		else
			hl_centered(row, line, resolve_hl(ctx.title_hl or "LvimUiTitle"))
		end
	end

	if ctx.mode == "tabs" then
		-- meta block highlights
		for i, l in ipairs(ctx.meta_lines) do
			if l == ctx.title then
				hl_title(i - 1, l)
			elseif l == ctx.subtitle then
				hl_centered(i - 1, l, resolve_hl(ctx.subtitle_hl or "LvimUiSubtitle"))
			elseif l == ctx.info then
				hl_centered(i - 1, l, resolve_hl(ctx.info_hl or "LvimUiInfo"))
			end
		end
		-- tab bar: one extmark per button. Spans are clamped to the rendered line so a
		-- narrow popup (or a windowed bar) can never produce an out-of-range end_col.
		local bar_line = api.nvim_buf_get_lines(buf, ctx.meta_offset, ctx.meta_offset + 1, false)[1] or ""
		local max_col = #bar_line
		local function set_span(cs, ce, group, priority)
			cs = math.max(0, math.min(centered_offset + cs, max_col))
			ce = math.max(0, math.min(centered_offset + ce, max_col))
			if ce > cs then
				api.nvim_buf_set_extmark(buf, NS, ctx.meta_offset, cs, {
					end_col = ce,
					hl_group = group,
					priority = priority,
				})
			end
		end
		for _, r in ipairs(tab_ranges) do
			if r.chevron then
				set_span(r.s, r.e, resolve_hl("LvimUiTabChevron"), 200)
			else
				local gtab = cfg.tab_hl
				local global_hl = gtab and (r.active and gtab.active or gtab.inactive)
				local per_hl = r.tab_hl and (r.active and r.tab_hl.active or r.tab_hl.inactive)
				local final_hl = merge_bg(global_hl, per_hl)
				set_span(r.s, r.e, resolve_hl(final_hl or (r.active and "LvimUiTabActive" or "LvimUiTabInactive")), 200)
				if r.icon_s then
					set_span(
						r.icon_s,
						r.icon_e,
						resolve_hl(r.active and "LvimUiTabIconActive" or "LvimUiTabIconInactive"),
						300
					)
				end
				set_span(
					r.text_s,
					r.text_e,
					resolve_hl(r.active and "LvimUiTabTextActive" or "LvimUiTabTextInactive"),
					300
				)
			end
		end
		hl_line(buf, ctx.meta_offset + 2, "LvimUiSeparator")
	else
		-- non-tabs header highlights
		for i, l in ipairs(ctx.header_lines) do
			if l == ctx.title then
				hl_title(i - 1, l)
			elseif l == ctx.subtitle then
				hl_centered(i - 1, l, resolve_hl(ctx.subtitle_hl or "LvimUiSubtitle"))
			elseif l == ctx.info then
				hl_centered(i - 1, l, resolve_hl(ctx.info_hl or "LvimUiInfo"))
			end
		end
		if #ctx.header_lines > 0 then
			hl_line(buf, #ctx.header_lines + 1, "LvimUiSeparator")
		end
	end
end

return M
