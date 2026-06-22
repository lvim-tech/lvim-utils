-- lvim-utils.ui.filters: build a centered `ui.bar` band from filter GROUPS — the ONE filter-bar model shared
-- by the picker (its header filter bar) and `ui.tabs` (a tab's toolbar filter), so every filter bar across the
-- plugins is identical: one button per option, a `●` separator between GROUPS, a live count, the bracketed
-- hotkey, the active highlight, and the canonical 4-state button styling (normal/active/hover/hover_active).
--
-- The consumer owns the SEMANTICS (what a filter does, how its count is computed) and passes them in; this
-- module owns only the LOOK + the spec construction. See `.claude/how-build-panels.md` §5.
--
---@module "lvim-utils.ui.filters"

local M = {}

---@class LvimUiFilterButton
---@field id     string
---@field label  string
---@field key?   string                 -- hotkey letter to bracket ([X]); also the direct activation key
---@field predicate? fun(src: any): boolean
---@field hl?            string         -- inactive colour (default LvimUiPeekFilterInactive)
---@field hl_active?     string         -- active colour (default LvimUiPeekFilterActive)
---@field hl_hover_active? string       -- cursor-on-active colour (default: degrades to hover)

---@class LvimUiFilterGroup
---@field id      string
---@field active  string                -- the active button id in this group
---@field buttons LvimUiFilterButton[]

--- Build the filter band from the groups.
---@param filters LvimUiFilterGroup[]
---@param opts { count?: fun(group: LvimUiFilterGroup, btn: LvimUiFilterButton): integer?, on_select?: fun(gi: integer, id: string), accents?: { active?: string, inactive?: string, sep?: string } }
---@return { band: table, sync: fun() }  -- band = { items, align="center" }; sync() re-evaluates the active flags
function M.bar(filters, opts)
    opts = opts or {}
    local A = opts.accents or {}
    local def_active = A.active or "LvimUiPeekFilterActive"
    local def_inactive = A.inactive or "LvimUiPeekFilterInactive"
    local sep_hl = A.sep or "LvimUiPeekFilterSep"

    local specs = {}
    for gi, g in ipairs(filters or {}) do
        if gi > 1 then
            -- a `●` divider BETWEEN groups (never before the first)
            specs[#specs + 1] = { type = "separator", text = "●", style = { padding = { 3, 3 }, hl = sep_hl } }
        end
        for _, b in ipairs(g.buttons) do
            local accent = b.hl_active or def_active
            local dim = b.hl or def_inactive
            local ha = b.hl_hover_active -- nil → ui.button degrades hover_active to plain hover
            specs[#specs + 1] = {
                type = "button",
                text = b.label,
                key = b.key, -- brackets the hotkey letter in the accent colour
                _gi = gi, -- so sync() can re-evaluate `active` after a toggle
                _id = b.id,
                count = opts.count and function()
                    return opts.count(g, b)
                end or nil,
                active = b.id == g.active,
                run = function()
                    if opts.on_select then
                        opts.on_select(gi, b.id)
                    end
                end,
                style = {
                    icon = { padding = { 0, 0 }, normal = accent, active = accent, hover = accent, hover_active = ha },
                    text = { padding = { 1, 1 }, normal = dim, active = accent, hover = accent, hover_active = ha },
                },
            }
        end
    end

    --- Re-sync each spec's `active` flag with its group (call after a filter toggles, before a re-render).
    local function sync()
        for _, s in ipairs(specs) do
            if s._gi and filters and filters[s._gi] then
                s.active = filters[s._gi].active == s._id
            end
        end
    end

    return { band = { items = specs, align = "center" }, sync = sync }
end

return M
