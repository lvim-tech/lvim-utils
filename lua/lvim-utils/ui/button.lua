-- lvim-utils.ui.button: render one toolbar "button" into text + highlight spans.
--
-- Two visual types, each with normal / active / hover states; a state supplies ONE hl per segment, so
-- every part of the button is themed independently and the whole button is fully caller-coloured:
--
--   "label"   — `[W]orkspace 7` / ` 󰈙  Tab ` : an optional leading ICON box, the caption (with the
--               KEY's letter bracketed when a key is given, else plain), and an optional dynamic
--               count. A pick-one-of-many item (filter / tab / scope / horizontal action). `hl[state]
--               = { icon, key, label, count }`.  spec = { type = "label", label, icon?, count?, key?,
--               run?, hl }
--   "action"  — ` <CR>  open `  : the whole key as a badge + a name; a command you fire.
--               `hl[state] = { key, name }`.  spec = { type = "action", key, name, run?, hl }
--
-- For the "label" type the bracket marks the KEY's letter where it appears in the label (case-
-- insensitively): `key="a"`/"All" → `[A]ll`, `key="o"`/"Workspace" → `W[o]rkspace`. It falls back to
-- the first letter when the key is multi-char or not found in the label. With NO key/key_pos the label
-- is rendered plain (no brackets) — for tabs / action buttons that lead with an icon instead.
-- `count` may be a value or a function returning one (evaluated at render, so it stays dynamic). `run`
-- is what the button does when its key / <CR> / a click fires it — consumed by `ui.bar`, not here.
--
---@module "lvim-utils.ui.button"

local M = {}

---@alias LvimUiButtonState "normal"|"active"|"hover"

---@class LvimUiButtonSpec
---@field type "label"|"action"
---@field label? string          -- "label" type: the caption (bracketed key + rest, or plain)
---@field icon? string           -- "label" type: optional leading icon, rendered as its own padded box
---@field count? number|string|fun(): (number|string|nil)  -- "label" type: optional dynamic trailing count
---@field key? string            -- hotkey; "action" shows it whole, "label" brackets its letter in `label`
---@field key_pos? integer       -- "label" type: 1-based char index to bracket (disambiguates repeats)
---@field name? string|fun(): string  -- "action" type: the caption (a fn is evaluated each render)
---@field run? fun()             -- what firing the button does
---@field active? boolean        -- whether this button is the semantically active one (the bar reads it)
---@field hl table               -- { normal = {...}, active = {...}, hover = {...} } — see the type docs above
---@field separator? string      -- ui.bar entry: a non-interactive separator glyph instead of a button
---@field pad? string            -- ui.bar separator entry: padding put on each side of the separator

--- The 1-based char index in `label` to bracket as the shortcut hint: an explicit `key_pos`, else the
--- KEY's first occurrence (case-insensitively), else the first char. The single home of the "[X]"
--- shortcut convention — shared by `render` and by row widgets (segmented / bracket_key option rows).
---@param label string
---@param key? string
---@param key_pos? integer
---@return integer
function M.key_pos(label, key, key_pos)
    local pos = key_pos
    if not pos and key and #key == 1 then
        pos = label:lower():find(key:lower(), 1, true)
    end
    return math.max(1, math.min(pos or 1, #label > 0 and #label or 1))
end

--- Render `spec` in `state`. Returns the text and its hl spans ({ byte_c0, byte_c1, hl_group }, byte
--- columns into the returned text). Falls back to the `normal` hl set for an unknown/missing state.
---@param spec LvimUiButtonSpec
---@param state LvimUiButtonState
---@return string text, table[] spans
function M.render(spec, state)
    local hl = (spec.hl and (spec.hl[state] or spec.hl.normal)) or {}
    local text, spans = "", {}
    local function put(s, group)
        if s ~= "" and group then
            spans[#spans + 1] = { #text, #text + #s, group }
        end
        text = text .. s
    end
    if spec.type == "action" then
        local name = spec.name
        if type(name) == "function" then
            name = name() -- a dynamic caption (e.g. the footer "menu" ⇄ "back" toggle)
        end
        put(" " .. (spec.key or "") .. " ", hl.key)
        put(" " .. (name or "") .. " ", hl.name)
    else
        -- Optional leading icon box (` <icon> `) — tabs / horizontal-action buttons lead with this.
        if spec.icon and spec.icon ~= "" then
            put(" " .. spec.icon .. " ", hl.icon)
        end
        local label = spec.label or ""
        -- Which label letter to bracket: explicit `key_pos` (1-based char index) when given — use it to
        -- disambiguate repeats, e.g. `label="Xoxo", key_pos=4` → `Xox[o]`. Otherwise auto-locate the
        -- KEY's letter (case-insensitively, first occurrence) — `key="o"`/"Workspace" → `W[o]rkspace` —
        -- falling back to the first letter when the key is multi-char. With NO key at all, render plain.
        if spec.key or spec.key_pos then
            local pos = M.key_pos(label, spec.key, spec.key_pos)
            put(label:sub(1, pos - 1), hl.label)
            put("[" .. label:sub(pos, pos) .. "]", hl.key)
            put(label:sub(pos + 1), hl.label)
        else
            put(label, hl.label)
        end
        local count = spec.count
        if type(count) == "function" then
            count = count()
        end
        if count ~= nil and count ~= "" then
            put(" " .. tostring(count), hl.count)
        end
    end
    return text, spans
end

return M
