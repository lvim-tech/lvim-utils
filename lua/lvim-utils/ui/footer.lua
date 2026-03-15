-- lua/lvim-utils/ui/footer.lua
-- Footer text computation and footer highlight application.
local util = require("lvim-utils.ui.util")

local api = vim.api
local M   = {}

-- ─── hints ────────────────────────────────────────────────────────────────────

--- Returns ordered list of {key, label} pairs for the footer hint.
---@param ctx table
---@return table[]
function M.hints(ctx)
	local c    = ctx.cfg or util.cfg()
	local k    = c.keys
	local l    = c.labels
	local mode = ctx.mode

	if mode == "input" then
		return {
			{ key = k.confirm, label = l.confirm },
			{ key = k.cancel,  label = l.cancel },
		}

	elseif mode == "multiselect" then
		return {
			{ key = k.multiselect.toggle,  label = l.toggle },
			{ key = k.multiselect.confirm, label = l.confirm },
			{ key = k.multiselect.cancel,  label = l.cancel },
		}

	elseif mode == "tabs" then
		if ctx.has_rows then
			if ctx.horizontal_actions then
				local cur = ctx.rows[ctx.row_cursor]
				if cur and cur.type == "action" then
					return {
						{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.navigate },
						{ key = k.confirm, label = l.execute },
						{ key = k.cancel,  label = l.close },
					}
				end
			end
			local row = ctx.rows[ctx.row_cursor]
			local t   = row and row.type or ""
			if t == "bool" or t == "boolean" then
				return {
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.toggle },
					{ key = k.cancel,  label = l.close },
				}
			elseif t == "select" then
				return {
					{ key = k.down .. "/" .. k.up,                           label = l.navigate },
					{ key = k.list.next_option .. "/" .. k.list.prev_option, label = l.cycle },
					{ key = k.cancel, label = l.close },
				}
			elseif t == "int" or t == "integer" or t == "float"
				or t == "number" or t == "string" or t == "text"
			then
				return {
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.edit },
					{ key = k.cancel,  label = l.close },
				}
			elseif t == "action" then
				return {
					{ key = k.down .. "/" .. k.up, label = l.navigate },
					{ key = k.confirm, label = l.execute },
					{ key = k.cancel,  label = l.close },
				}
			else
				return {
					{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.tabs },
					{ key = k.down .. "/" .. k.up,             label = l.navigate },
					{ key = k.cancel, label = l.close },
				}
			end
		else
			return {
				{ key = k.tabs.prev .. "/" .. k.tabs.next, label = l.tabs },
				{ key = k.down .. "/" .. k.up,             label = l.navigate },
				{ key = k.confirm, label = l.confirm },
				{ key = k.cancel,  label = l.cancel },
			}
		end

	elseif mode == "info" then
		return {
			{ key = k.down .. "/" .. k.up, label = l.navigate },
			{ key = k.cancel,              label = l.close },
		}

	else -- select
		return {
			{ key = k.down .. "/" .. k.up, label = l.navigate },
			{ key = k.select.confirm,      label = l.confirm },
			{ key = k.select.cancel,       label = l.cancel },
		}
	end
end

-- ─── assemble ─────────────────────────────────────────────────────────────────

--- Assemble hint list into a text string and byte ranges.
---@param hints table[]
---@return string  text
---@return table[] ranges  {s, e, kind="key"|"label"}
local function assemble(hints)
	local text   = "  "
	local ranges = {}
	for i, h in ipairs(hints) do
		local key_s = #text
		text = text .. h.key
		table.insert(ranges, { s = key_s, e = #text, kind = "key", hl = h.key_hl })
		text = text .. " "
		local lbl_s = #text
		text = text .. h.label
		table.insert(ranges, { s = lbl_s, e = #text, kind = "label", hl = h.label_hl })
		text = text .. (i < #hints and "   " or "  ")
	end
	return text, ranges
end

-- ─── max_width ────────────────────────────────────────────────────────────────

--- Maximum possible footer width, used for layout calculation before render.
---@param mode     string
---@param has_rows boolean
---@return integer
function M.max_width(mode, has_rows, cfg_override)
	local row_types = (mode == "tabs" and has_rows)
		and { "bool", "select", "int", "action", "" }
		or  { nil }
	local max_w = 0
	for _, t in ipairs(row_types) do
		local pseudo = {
			mode = mode, has_rows = has_rows,
			horizontal_actions = false, row_cursor = 1,
			rows = t and { { type = t } } or {},
			cfg = cfg_override,
		}
		local text = assemble(M.hints(pseudo))
		max_w = math.max(max_w, util.dw(text))
	end
	if max_w == 0 then
		local pseudo = { mode = mode, has_rows = has_rows, horizontal_actions = false, row_cursor = 1, rows = {}, cfg = cfg_override }
		local text = assemble(M.hints(pseudo))
		max_w = util.dw(text)
	end
	return max_w
end

-- ─── build / hl ───────────────────────────────────────────────────────────────

--- Build the 3 footer lines and return byte ranges for key/label highlights.
---@param ctx table  Pass ctx.hints directly to skip mode-based hint resolution.
---@return string[] lines
---@return table[]  hint_ranges  {s, e, kind}
function M.build(ctx)
	local hints        = ctx.hints or M.hints(ctx)
	local text, ranges = assemble(hints)
	local offset       = math.floor((ctx.width - util.dw(text)) / 2)
	local final_ranges = {}
	for _, r in ipairs(ranges) do
		table.insert(final_ranges, { s = offset + r.s, e = offset + r.e, kind = r.kind })
	end
	return {
		"",
		string.rep("─", ctx.width),
		util.center(text, ctx.width),
	}, final_ranges
end

--- Apply footer highlights: separator line, base footer hl, key/label extmarks.
---@param buf         integer
---@param total_lines integer
---@param hint_ranges table[]
function M.apply_hl(buf, total_lines, hint_ranges, ctx)
	local NS         = util.NS
	local resolve_hl = ctx.resolve_hl
	local cfg        = ctx.cfg
	local footer_hl  = cfg.footer_hl or {}

	util.hl_line(buf, total_lines - 2, "LvimUiSeparator")

	-- Base footer hl as a col extmark (not line_hl_group) so key/label extmarks
	-- can override fg with higher priority.
	local hint_line = api.nvim_buf_get_lines(buf, total_lines - 1, total_lines, false)[1] or ""
	api.nvim_buf_set_extmark(buf, NS, total_lines - 1, 0, {
		end_col  = #hint_line,
		hl_eol   = true,
		hl_group = resolve_hl("LvimUiFooter"),
		priority = 100,
	})

	for _, r in ipairs(hint_ranges or {}) do
		local default = r.kind == "key"
			and (footer_hl.key   or "LvimUiFooterKey")
			or  (footer_hl.label or "LvimUiFooterLabel")
		local group = resolve_hl(r.hl or default)
		api.nvim_buf_set_extmark(buf, NS, total_lines - 1, r.s, {
			end_col  = r.e,
			hl_group = group,
			priority = 300,
		})
	end
end

return M
