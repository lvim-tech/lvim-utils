-- lua/lvim-utils/ui/header.lua
-- Header section: tab bar (tabs mode) or title/subtitle/info block.
-- The tab bar is composed from ui.button "label" specs and laid out by ui.bar (the same primitives the
-- peek uses) — a single source of truth for every bar of buttons in the UI.
local util = require("lvim-utils.ui.util")
local bar = require("lvim-utils.ui.bar")

local api = vim.api
local M = {}

-- Tab-bar overflow chevrons (Nerd Font U+F104 / U+F105) marking hidden tabs on each side.
local CHEVRON_L, CHEVRON_R = vim.fn.nr2char(0xF104), vim.fn.nr2char(0xF105)

-- ─── build ────────────────────────────────────────────────────────────────────

--- Build header lines for the current mode.
--- Returns the lines array and (tabs mode) the ui.bar render result for the tab bar.
---@param ctx table
---@return string[], table|nil
function M.build(ctx)
    local lines = {}
    local tab_render = nil -- the ui.bar render result for the tab bar (tabs mode only)

    if ctx.mode == "tabs" then
        -- optional meta block (title / subtitle / info) above the tab bar
        for _, l in ipairs(ctx.meta_lines) do
            table.insert(lines, l == "" and "" or util.center(l, ctx.width))
        end
        if #ctx.meta_lines > 0 then
            table.insert(lines, "")
        end

        -- tab bar — one ui.button "label" per tab (icon + label), laid out by ui.bar: centred when it
        -- fits, else a scrolled window flanked by the U+F104/U+F105 chevrons keeping the active tab
        -- visible. The per-tab fill background (cfg.tab_hl + the tab's own tab_hl, merged) is placed in
        -- apply_hl over each button's returned byte range; the icon/label fg spans ride on top. `off` is
        -- persisted on popup state (ctx.tab_off) so the scroll position survives redraws.
        local specs = {}
        for i, t in ipairs(ctx.tabs) do
            specs[i] = {
                type = "label",
                icon = t.icon,
                label = t.label or ("Tab " .. i),
                active = (i == ctx.active_tab),
                _tab_hl = t.tab_hl, -- per-tab override, merged against cfg.tab_hl in apply_hl
                hl = {
                    normal = { icon = "LvimUiTabIconInactive", label = "LvimUiTabTextInactive" },
                    active = { icon = "LvimUiTabIconActive", label = "LvimUiTabTextActive" },
                },
            }
        end
        tab_render = bar.render({
            buttons = specs,
            width = ctx.width,
            align = "center",
            sel = ctx.active_tab,
            chevrons = { left = CHEVRON_L, right = CHEVRON_R },
            off = ctx.tab_off,
        })
        table.insert(lines, tab_render.line)
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

    return lines, tab_render
end

-- ─── apply_hl ─────────────────────────────────────────────────────────────────

--- Apply header highlights.
---@param buf        integer
---@param ctx        table
---@param tab_render table|nil  the ui.bar render result returned by M.build (tabs mode)
function M.apply_hl(buf, ctx, tab_render)
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
        -- tab bar — two layers per button: a whole-button fill background (cfg.tab_hl + the tab's own
        -- tab_hl, merged; falling back to LvimUiTab{Active,Inactive}) under the ui.bar icon/label fg
        -- spans. Everything is clamped to the rendered line so a narrow / scrolled bar can never
        -- produce an out-of-range end_col.
        local lnum = ctx.meta_offset
        local line = api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
        local max_col = #line
        local function span(cs, ce, group, priority)
            cs = math.max(0, math.min(cs, max_col))
            ce = math.max(0, math.min(ce, max_col))
            if ce > cs and group then
                api.nvim_buf_set_extmark(buf, NS, lnum, cs, { end_col = ce, hl_group = group, priority = priority })
            end
        end
        if tab_render then
            for _, btn in ipairs(tab_render.buttons) do
                if btn.c0 and not btn.sep then
                    local is_active = btn.spec.active
                    local global_hl = cfg.tab_hl and (is_active and cfg.tab_hl.active or cfg.tab_hl.inactive)
                    local per_hl = btn.spec._tab_hl
                        and (is_active and btn.spec._tab_hl.active or btn.spec._tab_hl.inactive)
                    local fill = merge_bg(global_hl, per_hl) or (is_active and "LvimUiTabActive" or "LvimUiTabInactive")
                    span(btn.c0, btn.c1, resolve_hl(fill), 200)
                end
            end
            for _, sp in ipairs(tab_render.spans) do
                span(sp[1], sp[2], resolve_hl(sp[3]), 300)
            end
            for _, ch in ipairs(tab_render.chevrons) do
                span(ch[1], ch[2], resolve_hl("LvimUiTabChevron"), 200)
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
