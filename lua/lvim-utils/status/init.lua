-- lvim-utils.status: the shared "echo / info" publisher for the bottom statusline. A transient action (the
-- navigator, the command-line) sets its current state here — a title, a match counter, a free-form action
-- string — and the statusline DISPLAYS it, so the bottom line acts as the Emacs echo/info area for whatever
-- is happening, instead of each UI drawing its own title/counter.
--
-- Two render backends, picked by `configure`:
--   * NATIVE (default): this module drives `vim.o.statusline` directly (save on first set, restore on
--     clear) — used when nothing else owns the statusline.
--   * COMPONENT: a statusline plugin (heirline) owns the line and renders a component that reads `M.get()`;
--     this module then only holds state (never touches `vim.o.statusline`). That is the integration path.
--
---@module "lvim-utils.status"

local colors = require("lvim-utils.colors")

local M = {}

-- ─── highlight (tint canon) ────────────────────────────────────────────────────

--- The status segment highlights, recomputed from the live palette (bound on setup, re-applied on theme
--- change). Each segment is its accent fg on a light blend of that accent — the same "тинт" canon as the
--- cmdline / msgarea chrome. The Icon variant is a stronger, bold badge.
---@return table<string, table>
local function build()
    local c = colors
    local b, bg = c.blend, c.bg
    local g = {}
    local function pair(name, col)
        g[name] = { fg = col, bg = b(col, bg, 0.1) }
        g[name .. "Icon"] = { fg = col, bg = b(col, bg, 0.2), bold = true }
    end
    pair("LvimUiStatusTitle", c.blue) -- the action title (+ its icon badge)
    pair("LvimUiStatusCount", c.green) -- the match counter
    pair("LvimUiStatusAction", c.yellow) -- the free-form action / query
    pair("LvimUiStatusSubtitle", c.cyan) -- a per-selection subtitle (e.g. the focused file name)
    return g
end

---@class LvimStatusState
---@field active boolean  whether a transient action currently owns the status line
---@field title string?  the action title (e.g. "Buffers")
---@field title_hl string?  highlight group for the title (default LvimUiStatusTitle)
---@field icon string?  an optional leading glyph for the title
---@field icon_hl string?  highlight group for the icon badge (default LvimUiStatusTitleIcon) — lets a caller
---  hand its OWN themed badge group (e.g. the cmdline mode colour) so the line mirrors that badge exactly
---@field current integer  the selected index (1-based; 0 = none)
---@field total integer  the total candidate count
---@field action string?  a free-form "current action" string (e.g. the query, or a hint)
---@field subtitle string?  a per-selection subtitle shown after the title (e.g. the focused file name)

---@type LvimStatusState
local state = {
    active = false,
    title = nil,
    title_hl = nil,
    icon = nil,
    icon_hl = nil,
    current = 0,
    total = 0,
    action = nil,
    subtitle = nil,
}

---@type string?  the user's `statusline` saved before we took it over (native backend), restored on clear
local saved = nil
---@type boolean  true = drive vim.o.statusline ourselves; false = a component (heirline) reads get()
local native = true
---@type boolean  whether build() has been bound to the palette yet
local hl_bound = false

--- Choose the render backend + register the segment highlights (once). `component = true` means a
--- statusline plugin renders `M.get()` itself, so we must NOT touch `vim.o.statusline`; `false`/absent =
--- the native backend drives the line directly.
---@param opts? { component?: boolean }
function M.configure(opts)
    native = not (opts and opts.component)
    if not hl_bound then
        hl_bound = true
        local ok, hl = pcall(require, "lvim-utils.highlight")
        if ok then
            hl.bind(build) -- apply now + re-apply on palette / ColorScheme change
        end
    end
end

--- Repaint the line: native backend re-evaluates the statusline expression; component backend just nudges
--- a redraw so the plugin's component re-reads our state.
local function repaint()
    pcall(vim.cmd, "redrawstatus!")
end

--- The native statusline string, evaluated by the `%!` expression while a transient action is active. Empty
--- when inactive (so the line falls back to whatever it normally shows). Built from `%#Group#` segments in
--- the tint canon: a title badge (icon stronger), the right-aligned counter, then the action / query.
---@return string
function M.render()
    if not state.active then
        return ""
    end
    -- A themed segment `%#Group#<lpad>text<rpad>%*` (`%*` resets to the line's own highlight). All padding
    -- is read from the live config, so the spacing is fully configurable.
    local cfg = require("lvim-utils.config").status or {}
    local function seg(group, text, l, r)
        return ("%%#%s#%s%s%s%%*"):format(group, string.rep(" ", l or 0), text, string.rep(" ", r or 0))
    end
    local parts = {}
    if state.icon and state.icon ~= "" then
        parts[#parts + 1] =
            seg(state.icon_hl or "LvimUiStatusTitleIcon", state.icon, cfg.icon_pad_left or 0, cfg.icon_pad_right or 1)
    end
    if state.title and state.title ~= "" then
        parts[#parts + 1] =
            seg(state.title_hl or "LvimUiStatusTitle", state.title, cfg.title_pad_left or 1, cfg.title_pad_right or 1)
    end
    local gp = cfg.segment_pad or 1
    -- A per-selection subtitle right after the title — e.g. the focused file name in a finder.
    if state.subtitle and state.subtitle ~= "" then
        parts[#parts + 1] = seg("LvimUiStatusSubtitle", state.subtitle, gp, gp)
    end
    -- The action / query sits on the LEFT, right after the title (the search pattern, the navigator query) —
    -- what the user is entering. Off by default (`show_action`): the input lives where you type it.
    if cfg.show_action and state.action and state.action ~= "" then
        parts[#parts + 1] = seg("LvimUiStatusAction", state.action, gp, gp)
    end
    -- The counter is pushed to the RIGHT edge (`%=`). On by default (`show_counter`). Shows `current/total`
    -- when there is a meaningful current (search match, a navigated completion row), else just the total
    -- (a flat result count, e.g. `:hel` → 18).
    if cfg.show_counter ~= false and state.total > 0 then
        local txt = state.current > 0 and ("%d/%d"):format(state.current, state.total) or tostring(state.total)
        parts[#parts + 1] = "%=" .. seg("LvimUiStatusCount", txt, gp, gp)
    end
    return table.concat(parts)
end

--- Publish (merge) the current action's status. Marks the line active and repaints. On the native backend
--- the first set saves the user's `statusline` and installs our expression.
---@param s { title?: string, title_hl?: string, icon?: string, icon_hl?: string, current?: integer, total?: integer, action?: string, subtitle?: string }
function M.set(s)
    s = s or {}
    if not hl_bound then
        M.configure({ component = not native })
    end
    state.active = true
    if s.title ~= nil then
        state.title = s.title
    end
    if s.title_hl ~= nil then
        state.title_hl = s.title_hl
    end
    if s.icon ~= nil then
        state.icon = s.icon
    end
    if s.icon_hl ~= nil then
        state.icon_hl = s.icon_hl
    end
    if s.current ~= nil then
        state.current = s.current
    end
    if s.total ~= nil then
        state.total = s.total
    end
    if s.action ~= nil then
        state.action = s.action
    end
    if s.subtitle ~= nil then
        state.subtitle = s.subtitle
    end
    if native and saved == nil then
        saved = vim.o.statusline
        vim.o.statusline = "%!v:lua.require'lvim-utils.status'.render()"
    end
    repaint()
end

--- Clear the status and (native backend) restore the user's statusline.
function M.clear()
    state.active = false
    state.title, state.title_hl, state.icon, state.icon_hl, state.action = nil, nil, nil, nil, nil
    state.subtitle = nil
    state.current, state.total = 0, 0
    if native and saved ~= nil then
        vim.o.statusline = saved
        saved = nil
    end
    repaint()
end

--- The live state (read by a heirline/statusline component on the component backend).
---@return LvimStatusState
function M.get()
    return state
end

--- The master switch — true when the statusline echo model is enabled (`config.status.enabled`). Callers
--- check this to decide whether to publish to the line or draw their own badge/title in place.
---@return boolean
function M.is_enabled()
    local cfg = require("lvim-utils.config").status or {}
    return cfg.enabled ~= false
end

return M
