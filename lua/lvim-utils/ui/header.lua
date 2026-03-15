-- lua/lvim-utils/ui/header.lua
-- Header section: tab bar (tabs mode) or title/subtitle/info block.
local util = require("lvim-utils.ui.util")

local api = vim.api
local M   = {}

-- ─── build ────────────────────────────────────────────────────────────────────

--- Build header lines for the current mode.
--- Returns the lines array, tab_ranges table, and centered_offset integer.
--- tab_ranges entries: { active, s, e, tab_hl }
---@param ctx table
---@return string[], table[], integer
function M.build(ctx)
	local lines         = {}
	local tab_ranges    = {}
	local centered_offset = 0

	if ctx.mode == "tabs" then
		-- optional meta block (title / subtitle / info) above the tab bar
		for _, l in ipairs(ctx.meta_lines) do
			table.insert(lines, l == "" and "" or util.center(l, ctx.width))
		end
		if #ctx.meta_lines > 0 then
			table.insert(lines, "")
		end

		-- tab bar
		local tab_bar = ""
		for i, t in ipairs(ctx.tabs) do
			local icon_str  = t.icon or ""
			local lbl_str   = t.label or ("Tab " .. i)
			local icon_part = icon_str ~= "" and (icon_str .. " ") or ""
			local lbl       = " " .. icon_part .. lbl_str .. " "
			local start     = #tab_bar
			local icon_s, icon_e
			if icon_str ~= "" then
				icon_s = start + 1
				icon_e = start + 1 + #icon_str
			end
			local text_s = start + 1 + #icon_part
			local text_e = text_s + #lbl_str
			table.insert(tab_ranges, {
				active = (i == ctx.active_tab),
				s      = start,
				e      = start + #lbl,
				tab_hl = t.tab_hl,
				icon_s = icon_s,
				icon_e = icon_e,
				text_s = text_s,
				text_e = text_e,
			})
			tab_bar = tab_bar .. lbl
		end
		centered_offset = math.floor((ctx.width - util.dw(tab_bar)) / 2)
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
	local NS         = util.NS
	local resolve_hl = ctx.resolve_hl
	local merge_bg   = util.merge_bg
	local hl_line    = util.hl_line
	local cfg        = ctx.cfg

	-- Apply hl only over the centered text (not the full line).
	local function hl_centered(row, text, group)
		if not group or not text or text == "" then return end
		local text_start = math.floor((ctx.width - util.dw(text)) / 2)
		local col_s = math.max(0, text_start - 1)
		local col_e = math.min(ctx.width, text_start + #text + 1)
		api.nvim_buf_set_extmark(buf, NS, row, col_s, {
			end_col  = col_e,
			hl_group = group,
			priority = 200,
		})
	end

	if ctx.mode == "tabs" then
		-- meta block highlights
		for i, l in ipairs(ctx.meta_lines) do
			if     l == ctx.title    then hl_centered(i - 1, l, resolve_hl(ctx.title_hl    or "LvimUiTitle"))
			elseif l == ctx.subtitle then hl_centered(i - 1, l, resolve_hl(ctx.subtitle_hl or "LvimUiSubtitle"))
			elseif l == ctx.info     then hl_centered(i - 1, l, resolve_hl(ctx.info_hl     or "LvimUiInfo"))
			end
		end
		-- tab bar: one extmark per button.
		-- Layer 2 (global tab_hl) is base; per-tab tab_hl contributes bg only.
		for _, r in ipairs(tab_ranges) do
			local gtab      = cfg.tab_hl
			local global_hl = gtab and (r.active and gtab.active or gtab.inactive)
			local per_hl    = r.tab_hl and (r.active and r.tab_hl.active or r.tab_hl.inactive)
			local final_hl  = merge_bg(global_hl, per_hl)
			api.nvim_buf_set_extmark(buf, NS, ctx.meta_offset, centered_offset + r.s, {
				end_col  = centered_offset + r.e,
				hl_group = resolve_hl(final_hl or (r.active and "LvimUiTabActive" or "LvimUiTabInactive")),
				priority = 200,
			})
			if r.icon_s then
				api.nvim_buf_set_extmark(buf, NS, ctx.meta_offset, centered_offset + r.icon_s, {
					end_col  = centered_offset + r.icon_e,
					hl_group = resolve_hl(r.active and "LvimUiTabIconActive" or "LvimUiTabIconInactive"),
					priority = 300,
				})
			end
			api.nvim_buf_set_extmark(buf, NS, ctx.meta_offset, centered_offset + r.text_s, {
				end_col  = centered_offset + r.text_e,
				hl_group = resolve_hl(r.active and "LvimUiTabTextActive" or "LvimUiTabTextInactive"),
				priority = 300,
			})
		end
		hl_line(buf, ctx.meta_offset + 2, "LvimUiSeparator")

	else
		-- non-tabs header highlights
		for i, l in ipairs(ctx.header_lines) do
			if     l == ctx.title    then hl_centered(i - 1, l, resolve_hl(ctx.title_hl    or "LvimUiTitle"))
			elseif l == ctx.subtitle then hl_centered(i - 1, l, resolve_hl(ctx.subtitle_hl or "LvimUiSubtitle"))
			elseif l == ctx.info     then hl_centered(i - 1, l, resolve_hl(ctx.info_hl     or "LvimUiInfo"))
			end
		end
		if #ctx.header_lines > 0 then
			hl_line(buf, #ctx.header_lines + 1, "LvimUiSeparator")
		end
	end
end

return M
