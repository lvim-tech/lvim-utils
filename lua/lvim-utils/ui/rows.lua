-- lua/lvim-utils/ui/rows.lua
-- Row type system: type annotations, display helpers, item accessors,
-- and row-navigation utilities used by the popup.
local util = require("lvim-utils.ui.util")

local M = {}

-- ─── type annotations ─────────────────────────────────────────────────────────

---@alias RowType "bool"|"boolean"|"select"|"int"|"integer"|"float"|"number"|"string"|"text"|"action"|"spacer"|"spacer_line"

--- Flat highlight definition: a named hl group string or an inline nvim hl attr table.
--- { bg?, fg?, bold?, italic?, sp?, underline?, ... }
---@alias HlDef string|table

---@class Row
---@field type     RowType
---@field name?    string
---@field label?   string
---@field icon?    string
---@field value?   any
---@field default? any
---@field options? string[]
---@field run?     fun(value: any, close?: fun(confirmed: boolean, result: any))
---@field top?     boolean
---@field bottom?  boolean
---@field hl?      { active?: HlDef, inactive?: HlDef }

--- Per-item hl state: either a flat HlDef (whole line) or split parts.
---@alias ItemHlState HlDef | { checkbox?: HlDef, icon?: HlDef, text?: HlDef }

---@class SelectItem
---@field label          string
---@field icon?          string
---@field checked_icon?   string
---@field unchecked_icon? string
---@field hl?   { active?: ItemHlState, inactive?: ItemHlState }

---@class Tab
---@field label   string
---@field icon?   string
---@field tab_hl? { active?: HlDef, inactive?: HlDef }  -- per-tab: only bg field is merged
---@field rows?   Row[]
---@field items?  (string|SelectItem)[]

-- ─── icons accessor ───────────────────────────────────────────────────────────

--- Convenience accessor for the configured icon set.
---@return table
function M.icons()
	return util.cfg().icons
end

-- ─── row helpers ──────────────────────────────────────────────────────────────

--- Return true when a row can receive keyboard focus.
---@param row Row
---@return boolean
function M.is_selectable(row)
	return row.type ~= "spacer" and row.type ~= "spacer_line"
end

--- Build the display string for a typed row.
---@param row Row
---@return string
function M.row_display(row, ico)
	local t = row.type or "string"
	local label = row.label or row.name or ""
	local val = tostring(row.value ~= nil and row.value or row.default or "")
	ico = ico or M.icons()
	local ri = row.icon and (row.icon .. "  ") or ""

	if t == "bool" or t == "boolean" then
		return (row.value and ico.bool_on or ico.bool_off) .. "  " .. ri .. label
	elseif t == "select" then
		return ico.select .. "  " .. ri .. label .. ": " .. val
	elseif t == "int" or t == "integer" or t == "float" or t == "number" then
		return ico.number .. "  " .. ri .. label .. ": " .. val
	elseif t == "string" or t == "text" then
		return ico.string .. "  " .. ri .. label .. ": " .. val
	elseif t == "action" then
		return ico.action .. "  " .. ri .. label
	elseif t == "spacer" then
		return ico.spacer .. " " .. label
	elseif t == "spacer_line" then
		return ""
	end
	return "   " .. label
end

--- Return the icon string and separator length for a row.
--- Layout in the buffer line: 2-byte indent | icon | sep | text | padding
---@param row Row
---@return string icon_str, integer sep_bytes
function M.row_icon_info(row, ico)
	local t = row.type or "string"
	ico = ico or M.icons()
	if t == "bool" or t == "boolean" then
		return (row.value and ico.bool_on or ico.bool_off), 2
	elseif t == "select" then
		return ico.select, 2
	elseif t == "int" or t == "integer" or t == "float" or t == "number" then
		return ico.number, 2
	elseif t == "string" or t == "text" then
		return ico.string, 2
	elseif t == "action" then
		return ico.action, 2
	elseif t == "spacer" then
		return ico.spacer, 1
	end
	return "", 0
end

-- ─── item accessors ───────────────────────────────────────────────────────────

--- Return the display label of a select item (string or {label,...} table).
---@param item string|SelectItem
---@return string
function M.item_label(item)
	if type(item) == "table" then
		return tostring(item.label or "")
	end
	return tostring(item or "")
end

--- Return the icon string of a select item, or nil.
---@param item string|SelectItem
---@return string|nil
function M.item_icon(item)
	if type(item) == "table" then
		return item.icon
	end
	return nil
end

--- Return the hl table of a select item, or nil.
---@param item string|SelectItem
---@return table|nil
function M.item_hl(item)
	if type(item) == "table" then
		return item.hl
	end
	return nil
end

--- Return true when an ItemHlState uses the split { icon?, text? } format.
---@param state any
---@return boolean
function M.item_hl_is_split(state)
	return type(state) == "table" and (state.checkbox ~= nil or state.icon ~= nil or state.text ~= nil)
end

-- ─── row navigation helpers ───────────────────────────────────────────────────

--- Return the 1-based index of the first selectable row, or 1 as fallback.
---@param rows Row[]
---@return integer
function M.first_selectable(rows)
	for i, r in ipairs(rows) do
		if M.is_selectable(r) then
			return i
		end
	end
	return 1
end

--- Return the next selectable row index in direction delta (+1 / -1),
--- or nil when the boundary is reached.
---@param rows  Row[]
---@param from  integer  Current 1-based index
---@param delta integer  +1 for down, -1 for up
---@return integer|nil
function M.next_selectable(rows, from, delta)
	local i = from + delta
	while i >= 1 and i <= #rows do
		if M.is_selectable(rows[i]) then
			return i
		end
		i = i + delta
	end
	return nil
end

--- Resolve the initial row_cursor from a hint (string name or 1-based index).
--- Falls back to first_selectable when the hint is absent or unmatched.
---@param rows Row[]
---@param hint string|integer|nil
---@return integer
function M.resolve_initial_row(rows, hint)
	if not hint then
		return M.first_selectable(rows)
	end
	if type(hint) == "number" then
		local idx = math.floor(hint)
		if idx >= 1 and idx <= #rows and M.is_selectable(rows[idx]) then
			return idx
		end
		return M.next_selectable(rows, idx - 1, 1) or M.first_selectable(rows)
	end
	for i, r in ipairs(rows) do
		if r.name == hint and M.is_selectable(r) then
			return i
		end
	end
	return M.first_selectable(rows)
end

return M
