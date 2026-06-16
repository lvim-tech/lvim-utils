-- lua/lvim-utils/ui/footer.lua
-- Footer key-hint bar: the ordered { key, label } hints for the current mode, rendered as ui.button
-- "action" buttons laid out by ui.bar on a SINGLE centred line — overflowing to a ‹ › scroll (the same
-- primitives the peek and the tab bar use), so every bar of buttons in the UI shares one renderer.
local util = require("lvim-utils.ui.util")
local bar = require("lvim-utils.ui.bar")
local button = require("lvim-utils.ui.button")

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

-- ─── button specs ─────────────────────────────────────────────────────────────

--- Map the resolved hint list to ui.button "action" specs. Each hint's key/label keep their own
--- highlight when set (h.key_hl / h.label_hl), else the cfg.footer_hl overrides, else the defaults.
---@param hints table[]
---@param cfg table
---@return LvimUiButtonSpec[]
local function hint_buttons(hints, cfg)
    local footer_hl = (cfg and cfg.footer_hl) or {}
    local specs = {}
    for i, h in ipairs(hints) do
        local keyg = h.key_hl or footer_hl.key or "LvimUiFooterKey"
        local nameg = h.label_hl or footer_hl.label or "LvimUiFooterLabel"
        local set = { key = keyg, name = nameg }
        specs[i] = {
            type = "action",
            key = h.key,
            name = h.label,
            hl = { normal = set, active = set, hover = set },
        }
    end
    return specs
end

-- ─── max_width ────────────────────────────────────────────────────────────────

--- Display width of the assembled (single-line) footer for `hints` — content only, no padding.
---@param hints table[]
---@param cfg table
---@return integer
local function hints_width(hints, cfg)
    local specs = hint_buttons(hints, cfg)
    local total = 0
    for i, spec in ipairs(specs) do
        if i > 1 then
            total = total + 2 -- ui.bar default sep between buttons
        end
        local txt = button.render(spec, "normal")
        total = total + util.dw(txt)
    end
    return total
end

--- Maximum possible footer width, used for layout calculation before render.
---@param mode     string
---@param has_rows boolean
---@return integer
function M.max_width(mode, has_rows, cfg_override)
    local cfg = cfg_override or util.cfg()
    local row_types = (mode == "tabs" and has_rows) and { "bool", "select", "int", "action", "" } or { nil }
    local max_w = 0
    for _, t in ipairs(row_types) do
        local pseudo = {
            mode = mode,
            has_rows = has_rows,
            horizontal_actions = false,
            row_cursor = 1,
            rows = t and { { type = t } } or {},
            cfg = cfg,
        }
        max_w = math.max(max_w, hints_width(M.hints(pseudo), cfg))
    end
    return max_w
end

-- ─── build / hl ─────────────────────────────────────────────────────────────

--- Build the footer lines (empty + separator + the single centred hint line) and the ui.bar render
--- result (its spans / chevrons drive apply_hl). Pass ctx.hints to skip mode-based hint resolution.
---@param ctx table
---@return string[] lines
---@return table    render  the ui.bar render result
function M.build(ctx)
    local hints = ctx.hints or M.hints(ctx)
    local cfg = ctx.cfg or util.cfg()
    local render = bar.render({
        buttons = hint_buttons(hints, cfg),
        width = ctx.width,
        align = "center",
    })
    local lines = { "", string.rep("─", ctx.width), render.line }
    return lines, render
end

--- Number of hint rows the footer renders — always 1 now (single line, scrolls instead of wrapping).
--- Accepts (and ignores) the ctx the caller passes, keeping the old call signature.
---@param _ctx? table
---@return integer
function M.hint_rows(_ctx)
    return 1
end

--- Apply footer highlights: the separator line above + the ui.bar key/label spans and ‹ › chevrons.
---@param buf         integer
---@param total_lines integer
---@param render      table   the ui.bar render result from M.build
---@param ctx         table
function M.apply_hl(buf, total_lines, render, ctx)
    local NS = util.NS
    local resolve_hl = ctx.resolve_hl
    -- the hint line is the last footer line; the separator sits just above it
    local lnum = total_lines - 1
    util.hl_line(buf, lnum - 1, "LvimUiSeparator")

    local line = api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
    local max_col = #line
    local function span(cs, ce, group, priority)
        cs = math.max(0, math.min(cs, max_col))
        ce = math.max(0, math.min(ce, max_col))
        if ce > cs and group then
            api.nvim_buf_set_extmark(buf, NS, lnum, cs, { end_col = ce, hl_group = group, priority = priority })
        end
    end
    for _, sp in ipairs(render.spans or {}) do
        span(sp[1], sp[2], resolve_hl(sp[3]), 300)
    end
    for _, ch in ipairs(render.chevrons or {}) do
        span(ch[1], ch[2], resolve_hl("LvimUiFooterChevron"), 300)
    end
end

return M
