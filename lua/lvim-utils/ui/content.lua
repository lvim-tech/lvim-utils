-- lua/lvim-utils/ui/content.lua
-- Content section: rows (tabs mode), select/multiselect items, input placeholder.
-- Also covers the horizontal action bar in tabs mode.
local util = require("lvim-utils.ui.util")
local rows = require("lvim-utils.ui.rows")
local bar = require("lvim-utils.ui.bar")

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
        -- The current row renders as `ico.current .. " " .. icon_part .. lbl` with no
        -- leading pad, where icon_part is `icon .. " "` (or "" when the item has no icon).
        -- The ➤ marker AND the item icon share the icon highlight span, and the text
        -- starts right after — otherwise the highlights land off-column (the item icon was
        -- previously left uncoloured and the text shifted left by the icon's width).
        local after_marker = #ico.current + 1 -- past "➤ "
        if icon then
            local icon_e = after_marker + #icon -- ➤ … ◑
            local text_s = icon_e + 1 -- past the space after the item icon
            return nil, nil, 0, icon_e, text_s, text_s + #lbl
        end
        return nil, nil, 0, #ico.current, after_marker, after_marker + #lbl
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
            table.insert(
                lines,
                row
                        and (row.center and util.center(rows.row_display(row, ico), ctx.width) or util.lpad(
                            rows.row_display(row, ico),
                            ctx.width,
                            2
                        ))
                    or ""
            )
        end

        -- horizontal action bar — one ui.button "label" (icon + label) per action row, laid out by
        -- ui.bar (centred / scrolled like every other bar). The render result is stashed on ctx for
        -- apply_hl; action_bar_ranges keeps the { s, e, row_abs } shape the popup cursor code reads,
        -- with s/e = each button's byte range in the rendered line (so action_bar_offset is 0).
        if ctx.horizontal_actions and ctx.action_bar_ht > 0 then
            local specs, row_abs_of = {}, {}
            for i, ar in ipairs(ctx.action_rows) do
                local row_abs = 0
                for ri, r in ipairs(ctx.rows) do
                    if r == ar then
                        row_abs = ri
                        break
                    end
                end
                row_abs_of[i] = row_abs
                specs[i] = {
                    type = "label",
                    icon = ico.action,
                    label = ar.label or "",
                    active = (row_abs == ctx.row_cursor),
                    hl = {
                        normal = { icon = "LvimUiButtonIconInactive", label = "LvimUiButtonTextInactive" },
                        active = { icon = "LvimUiButtonIconActive", label = "LvimUiButtonTextActive" },
                    },
                }
            end
            local sel
            for i, ra in ipairs(row_abs_of) do
                if ra == ctx.row_cursor then
                    sel = i
                end
            end
            local render = bar.render({ buttons = specs, width = ctx.width, align = "center", sel = sel })
            ctx._action_render = render
            for i, btn in ipairs(render.buttons) do
                if btn.c0 then
                    action_bar_ranges[#action_bar_ranges + 1] = { s = btn.c0, e = btn.c1, row_abs = row_abs_of[i] }
                end
            end
            table.insert(lines, render.line)
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
            local line_cache = {}
            for _, hl in ipairs(ctx.info_highlights) do
                local row = ctx.header_height + hl.line - ctx.scroll
                if row >= ctx.header_height and row < ctx.header_height + ctx.content_height then
                    if not line_cache[row] then
                        line_cache[row] = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
                    end
                    local line_text = line_cache[row]
                    local col_start = math.min(hl.col_start or 0, #line_text)
                    local col_end = (hl.col_end == nil or hl.col_end == -1) and #line_text
                        or math.min(hl.col_end, #line_text)
                    if col_start < col_end then
                        api.nvim_buf_set_extmark(buf, NS, row, col_start, {
                            end_col = col_end,
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
        -- On the tab bar (tab_focus), no content row is active — this hides the active
        -- row's cursor bar and bold while the header is focused.
        local active_row = (not ctx.tab_focus) and ctx.rows[ctx.row_cursor] or nil

        for i = 1, ctx.content_height do
            local row = drows[ctx.scroll + i]
            local row_idx = ctx.header_height + i - 1
            if row then
                -- Disabled row: its current value can't apply in the current context. The dim +
                -- strikethrough is applied later, scoped to the TEXT (label + value) only, so the
                -- type icon and the leading indent stay untouched. `row.disabled` is a boolean OR
                -- a predicate evaluated HERE at render time, so it tracks a related toggle live (a
                -- value that only applies while another option is on).
                local dis = row.disabled
                if type(dis) == "function" then
                    local ok_d, dv = pcall(dis, row.value)
                    dis = ok_d and dv
                end
                if row == active_row then
                    local _line = api.nvim_buf_get_lines(buf, row_idx, row_idx + 1, false)[1] or ""
                    api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
                        end_col = #_line,
                        hl_eol = true,
                        hl_group = "LvimUiCursorLine",
                        priority = 100,
                    })
                elseif not rows.is_selectable(row) and not (row.icon_hl or row.text_hl or row.hl) then
                    hl_line(buf, row_idx, "LvimUiSpacer")
                end
                -- icon / text hl for selectable rows
                local row_content = rows.row_display(row, ico)
                if row.center and row.type == "segmented" then
                    -- Per-segment colours (row.option_hl) + bold for the active option.
                    -- Compute the centering lead from the centre formula (NOT from leading
                    -- whitespace, which over-counts when the row text starts with a space,
                    -- e.g. when a non-first option is the active/bracketed one).
                    local line = api.nvim_buf_get_lines(buf, row_idx, row_idx + 1, false)[1] or ""
                    local rdw = util.dw(rows.row_display(row, ico))
                    local lead = (rdw < ctx.width) and math.floor((ctx.width - rdw) / 2) or 0
                    local prefix, segs = rows.segmented_segments(row, ico)
                    if row.text_hl then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
                            end_col = #line,
                            hl_group = resolve_hl(row.text_hl),
                            priority = 240,
                        })
                    end
                    local col = lead + #prefix
                    for _, sg in ipairs(segs) do
                        local ohl = row.option_hl and row.option_hl[sg.opt]
                        if ohl then
                            api.nvim_buf_set_extmark(buf, NS, row_idx, col, {
                                end_col = col + #sg.text,
                                hl_group = resolve_hl(ohl),
                                priority = 260,
                            })
                        end
                        -- bracket_key bars highlight the active button only while the row is
                        -- focused, so the bold clears when the cursor leaves it.
                        if sg.opt == row.value and row.active_hl and (not row.bracket_key or row == active_row) then
                            api.nvim_buf_set_extmark(buf, NS, row_idx, col, {
                                end_col = col + #sg.text,
                                hl_group = resolve_hl(row.active_hl),
                                priority = 270,
                            })
                        end
                        -- The "[X]" shortcut hint stays bold at all times (every button).
                        if row.bracket_key and row.active_hl then
                            local br = sg.text:find("[", 1, true)
                            if br then
                                api.nvim_buf_set_extmark(buf, NS, row_idx, col + br - 1, {
                                    end_col = col + br - 1 + 3,
                                    hl_group = resolve_hl(row.active_hl),
                                    priority = 280,
                                })
                            end
                        end
                        col = col + #sg.text + 1
                    end
                elseif row.center then
                    local g = row.text_hl or (row.hl and ((row == active_row) and row.hl.active or row.hl.inactive))
                    if g then
                        local _l = api.nvim_buf_get_lines(buf, row_idx, row_idx + 1, false)[1] or ""
                        api.nvim_buf_set_extmark(
                            buf,
                            NS,
                            row_idx,
                            0,
                            { end_col = #_l, hl_group = resolve_hl(g), priority = 250 }
                        )
                    end
                elseif rows.is_selectable(row) or row.icon_hl or row.text_hl then
                    local is_active = (row == active_row)
                    local icon_str, sep_bytes = rows.row_icon_info(row, ico)
                    local icon_hl = is_active and "LvimUiRowIconActive" or "LvimUiRowIconInactive"
                    local text_hl = row.text_hl or (is_active and "LvimUiRowTextActive" or "LvimUiRowTextInactive")
                    if #icon_str > 0 then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, 2, {
                            end_col = 2 + #icon_str,
                            hl_group = resolve_hl(icon_hl),
                            priority = 200,
                        })
                    end
                    local after_type = 2 + #icon_str + sep_bytes
                    local text_s = after_type
                    if row.icon then
                        local ri_hl = row.icon_hl
                            or (is_active and "LvimUiRowItemIconActive" or "LvimUiRowItemIconInactive")
                        api.nvim_buf_set_extmark(buf, NS, row_idx, after_type, {
                            end_col = after_type + #row.icon,
                            hl_group = resolve_hl(ri_hl),
                            priority = 200,
                        })
                        text_s = after_type + #row.icon + 1
                    end
                    local content_end = 2 + #row_content
                    local suffix_s = (row.suffix and #row.suffix > 0) and (content_end - #row.suffix) or nil
                    local text_e = suffix_s and (suffix_s - 1) or content_end
                    if text_s < text_e then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
                            end_col = text_e,
                            hl_group = resolve_hl(text_hl),
                            priority = 200,
                        })
                    end
                    if suffix_s and row.suffix_hl then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, suffix_s, {
                            end_col = content_end,
                            hl_group = resolve_hl(row.suffix_hl),
                            priority = 210,
                        })
                    end
                    -- Disabled: dim to the comment colour + strike through, scoped to the text
                    -- (label + value) only — the type icon and indent are left as-is. Top priority
                    -- so the comment fg wins over the row's own text hl (and any flat override).
                    if dis then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
                            end_col = content_end,
                            hl_group = "LvimUiDisabled",
                            priority = 10000,
                        })
                    end
                end
                -- per-row flat hl override (priority 300 overrides icon/text defaults)
                if row.hl and not row.center then
                    local row_hl = (row == active_row) and row.hl.active or row.hl.inactive
                    if row_hl then
                        api.nvim_buf_set_extmark(buf, NS, row_idx, 2, {
                            end_col = 2 + #row_content,
                            hl_group = resolve_hl(row_hl),
                            priority = 300,
                        })
                    end
                end
            end
        end

        -- action bar — two layers per button: a whole-button fill background (cfg.button_hl, else
        -- LvimUiButton{Active,Inactive}) under the ui.bar icon/label fg spans, plus any ‹ › chevrons.
        -- Driven by the ui.bar render stashed on ctx in M.build.
        local render = ctx._action_render
        if ctx.horizontal_actions and render then
            local bar_lnum = ctx.header_height + ctx.content_height
            local bline = api.nvim_buf_get_lines(buf, bar_lnum, bar_lnum + 1, false)[1] or ""
            local bmax = #bline
            local function bspan(cs, ce, group, priority)
                cs = math.max(0, math.min(cs, bmax))
                ce = math.max(0, math.min(ce, bmax))
                if ce > cs and group then
                    api.nvim_buf_set_extmark(
                        buf,
                        NS,
                        bar_lnum,
                        cs,
                        { end_col = ce, hl_group = group, priority = priority }
                    )
                end
            end
            for _, btn in ipairs(render.buttons) do
                if btn.c0 and not btn.sep then
                    local is_active = btn.spec.active
                    local gbtn = cfg.button_hl
                    local fill = (gbtn and (is_active and gbtn.active or gbtn.inactive))
                        or (is_active and "LvimUiButtonActive" or "LvimUiButtonInactive")
                    bspan(btn.c0, btn.c1, resolve_hl(fill), is_active and 900 or 200)
                end
            end
            for _, sp in ipairs(render.spans) do
                bspan(sp[1], sp[2], resolve_hl(sp[3]), 1000)
            end
            for _, ch in ipairs(render.chevrons) do
                bspan(ch[1], ch[2], resolve_hl("LvimUiFooterChevron"), 300)
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

                -- cursor line (active row only — the list body stays clean, no tint)
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

                -- text hl: split.text → text range; per-item flat → whole line; default → text range only
                local text_hl = resolve_text_hl(item, is_active, cfg)
                if text_hl then
                    local ihl_state = rows.item_hl(item)
                    local ihl_flat = ihl_state and (is_active and ihl_state.active or ihl_state.inactive)
                    if rows.item_hl_is_split(ihl_flat) then
                        -- per-item split: text range only
                        api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
                            end_col = text_e,
                            hl_group = resolve_hl(text_hl),
                            priority = 300,
                        })
                    elseif ihl_flat then
                        -- per-item flat: whole line (icon takes the item color too)
                        api.nvim_buf_set_extmark(buf, NS, row_idx, 0, {
                            end_col = #_line,
                            hl_group = resolve_hl(text_hl),
                            priority = 300,
                        })
                    else
                        -- global default: text range only so checkbox/icon hl are not overridden
                        api.nvim_buf_set_extmark(buf, NS, row_idx, text_s, {
                            end_col = text_e,
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
