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
			local icon_part = icon_str ~= "" and (icon_str .. " ") or ""
			lbls[i] = " " .. icon_part .. (t.label or ("Tab " .. i)) .. " "
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
			local budget = ctx.width - 4 -- room for the two flanking chevrons + spaces
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
		local prefix = left_more and (CHEVRON_L .. " ") or ""
		local tab_bar = prefix
		if left_more then
			table.insert(tab_ranges, { chevron = true, s = 0, e = #CHEVRON_L })
		end
		for i = lo, hi do
			local t = ctx.tabs[i]
			local icon_str = t.icon or ""
			local lbl_str = t.label or ("Tab " .. i)
			local icon_part = icon_str ~= "" and (icon_str .. " ") or ""
			local lbl = lbls[i]
			local start = #tab_bar
			local icon_s, icon_e
			if icon_str ~= "" then
				icon_s = start + 1
				icon_e = start + 1 + #icon_str
			end
			local text_s = start + 1 + #icon_part
			local text_e = text_s + #lbl_str
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
			local cs = #tab_bar + 1 -- chevron starts after the joining space
			tab_bar = tab_bar .. " " .. CHEVRON_R
			table.insert(tab_ranges, { chevron = true, s = cs, e = cs + #CHEVRON_R })
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

	if ctx.mode == "tabs" then
		-- meta block highlights
		for i, l in ipairs(ctx.meta_lines) do
			if l == ctx.title then
				hl_centered(i - 1, l, resolve_hl(ctx.title_hl or "LvimUiTitle"))
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
				set_span(r.s, r.e, resolve_hl("LvimUiTabInactive"), 200)
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
				hl_centered(i - 1, l, resolve_hl(ctx.title_hl or "LvimUiTitle"))
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
