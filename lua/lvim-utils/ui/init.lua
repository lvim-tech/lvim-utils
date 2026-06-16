-- lua/lvim-utils/ui/init.lua
-- Public API for lvim-utils floating UI components.
--
-- Modes and their callback signatures:
--   select      → callback(confirmed: boolean, index: integer)
--   multiselect → callback(confirmed: boolean, selected: table<string, boolean>)
--   input       → callback(confirmed: boolean, value: string)
--   tabs        → callback(confirmed: boolean, result)
--                 result = { tab, index, item } for simple tabs
--                 result = table<name, value>   for typed-row tabs
--
-- Public API:
--   M.select(opts)        – pick one item from a list
--   M.multiselect(opts)   – pick multiple items
--   M.input(opts)         – free-text input field
--   M.confirm(opts)       – yes/no dialog → callback(yes: boolean)
--   M.tabs(opts)          – tabbed view with typed rows or simple item lists
--   M.info(content, opts) – read-only markdown/text info window
--   M.close_info(win)     – programmatically close an info window

local hl = require("lvim-utils.highlight")
local colors = require("lvim-utils.config").colors
local popup = require("lvim-utils.ui.popup")
local peek = require("lvim-utils.ui.peek")
local frame = require("lvim-utils.ui.frame")
local form = require("lvim-utils.ui.form")
local rows = require("lvim-utils.ui.rows")
local util = require("lvim-utils.ui.util")

local M = {}

--- Pick one item from a list — a 1-panel `frame` (the list) + a confirm/cancel footer. `<C-j>`
--- descends into the footer (which scrolls to follow the selection on a narrow popup); the list shows
--- its selection via cursorline. callback(confirmed, index, item).
---@param opts UiOpts
function M.select(opts)
    opts = opts or {}
    local items = opts.items or {}
    local cb = opts.callback or function() end
    if #items == 0 then
        vim.schedule(function()
            cb(false)
        end)
        return
    end
    local confirmed = false
    local pan

    local function index()
        if pan and pan.win and vim.api.nvim_win_is_valid(pan.win) then
            return vim.api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end
    --- Confirm the focused item and close. `st` is the frame state (carries `close`).
    ---@param st table
    local function pick(st)
        confirmed = true
        local i = index()
        st.close()
        vim.schedule(function()
            cb(true, i)
        end)
    end

    local provider = {
        hide_cursor = true,
        cursorline = true,
        size = function()
            local w = util.dw(opts.title or "Select") + 4
            for _, it in ipairs(items) do
                local icon = rows.item_icon(it)
                w = math.max(w, util.dw((icon and icon .. " " or "") .. rows.item_label(it)) + 4)
            end
            return w, #items
        end,
        render = function(width)
            local lines, hls = {}, {}
            for i, it in ipairs(items) do
                local icon = rows.item_icon(it)
                lines[i] = util.lpad((icon and (icon .. " ") or "") .. rows.item_label(it), width, 2)
                if icon then
                    hls[#hls + 1] = { i - 1, 2, 2 + #icon, "LvimUiItemIconInactive" }
                end
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            map({ "<CR>", "<Space>" }, function()
                pick(st)
            end)
        end,
    }

    return frame.open({
        mode = "float",
        title = opts.title or "Select",
        border = "rounded",
        panel_border = "none",
        auto_width = true,
        max_width = 0.6,
        auto_height = true,
        max_height = 0.6,
        panels = { { provider = provider } },
        footer = {
            actions = {
                { key = "<CR>", name = "confirm", run = pick },
                {
                    key = "<Esc>",
                    name = "cancel",
                    run = function(st)
                        st.close()
                    end,
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Pick multiple items — a 1-panel `frame` of checkbox rows + a toggle/confirm/cancel footer.
--- `<Space>` toggles the focused row, `<CR>` confirms. callback(confirmed, selected) where `selected`
--- maps each chosen item to true.
---@param opts UiOpts
function M.multiselect(opts)
    opts = opts or {}
    local items = opts.items or {}
    local cb = opts.callback or function() end
    if #items == 0 then
        vim.schedule(function()
            cb(false)
        end)
        return
    end
    local confirmed = false
    local selected = {}
    local pan
    local ico = util.cfg().icons or rows.icons()

    local function index()
        if pan and pan.win and vim.api.nvim_win_is_valid(pan.win) then
            return vim.api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end
    local function toggle_current()
        local it = items[index()]
        if it ~= nil then
            selected[it] = (not selected[it]) or nil
        end
        if pan and pan.refresh then
            pan.refresh()
        end
    end
    --- @param st table
    local function confirm(st)
        confirmed = true
        st.close()
        vim.schedule(function()
            cb(true, selected)
        end)
    end

    local provider = {
        hide_cursor = true,
        cursorline = true,
        size = function()
            local w = util.dw(opts.title or "Select") + 6
            for _, it in ipairs(items) do
                local icon = rows.item_icon(it)
                w = math.max(w, util.dw((icon and icon .. " " or "") .. rows.item_label(it)) + 6)
            end
            return w, #items
        end,
        render = function(width)
            local lines, hls = {}, {}
            for i, it in ipairs(items) do
                local check = selected[it] and (ico.multi_selected or "") or (ico.multi_empty or "")
                local icon = rows.item_icon(it)
                lines[i] = util.lpad(check .. " " .. (icon and (icon .. " ") or "") .. rows.item_label(it), width, 2)
                hls[#hls + 1] =
                    { i - 1, 2, 2 + #check, selected[it] and "LvimUiCheckboxSelected" or "LvimUiCheckboxEmpty" }
                if icon then
                    local off = 2 + #check + 1
                    hls[#hls + 1] = { i - 1, off, off + #icon, "LvimUiItemIconInactive" }
                end
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            map({ "<Space>" }, toggle_current)
            map({ "<CR>" }, function()
                confirm(st)
            end)
        end,
    }

    frame.open({
        mode = "float",
        title = opts.title or "Select",
        border = "rounded",
        panel_border = "none",
        auto_width = true,
        max_width = 0.6,
        auto_height = true,
        max_height = 0.6,
        panels = { { provider = provider } },
        footer = {
            actions = {
                {
                    key = "<Space>",
                    name = "toggle",
                    run = function()
                        toggle_current()
                    end,
                },
                { key = "<CR>", name = "confirm", run = confirm },
                {
                    key = "<Esc>",
                    name = "cancel",
                    run = function(st)
                        st.close()
                    end,
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Free-text input — a 1-panel `frame` whose single editable line IS the field; `<CR>` confirms,
--- `<Esc>` cancels. callback(confirmed, value).
---@param opts UiOpts
function M.input(opts)
    opts = opts or {}
    local cb = opts.callback or function() end
    local default = tostring(opts.default or opts.value or "")
    local confirmed = false
    local buf

    --- @param st table
    local function confirm(st)
        confirmed = true
        local val = ""
        if buf and vim.api.nvim_buf_is_valid(buf) then
            val = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        end
        st.close()
        vim.schedule(function()
            cb(true, val)
        end)
    end

    local provider = {
        editable = true,
        size = function()
            return math.max(util.dw(default) + 4, util.dw(opts.title or opts.prompt or "Input") + 4, 30), 1
        end,
        render = function()
            return { default }, {}
        end,
        keys = function(map, p, st)
            buf = p.buf
            vim.keymap.set("i", "<CR>", function()
                vim.cmd("stopinsert")
                confirm(st)
            end, { buffer = p.buf, nowait = true })
            vim.keymap.set("i", "<Esc>", function()
                vim.cmd("stopinsert")
                st.close()
            end, { buffer = p.buf, nowait = true })
            map("<CR>", function()
                confirm(st)
            end)
        end,
    }

    frame.open({
        mode = "float",
        title = opts.title or opts.prompt or "Input",
        border = "rounded",
        panel_border = "none",
        auto_width = true,
        max_width = opts.width or 0.6,
        auto_height = true,
        panels = { { provider = provider } },
        footer = {
            actions = {
                { key = "<CR>", name = "confirm", run = confirm },
                {
                    key = "<Esc>",
                    name = "cancel",
                    run = function(st)
                        st.close()
                    end,
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Yes/no confirmation dialog (a two-item select). The default choice is listed first so
--- it is focused on open; cancelling (<Esc>) resolves to `false`.
---@param opts { prompt?: string, title?: string, yes?: string, no?: string, default_no?: boolean, callback: fun(yes: boolean) }
function M.confirm(opts)
    opts = opts or {}
    local yes_label, no_label = opts.yes or "Yes", opts.no or "No"
    local items = opts.default_no and { no_label, yes_label } or { yes_label, no_label }
    local cb = opts.callback or function() end
    M.select({
        title = opts.title or opts.prompt or " Confirm",
        items = items,
        callback = function(confirmed, index)
            cb(confirmed == true and items[index] == yes_label)
        end,
    })
end

--- Tabbed / form view on a `frame`: the center is a `form` provider of the active tab's typed rows;
--- the tab's ACTION rows become the navigable FOOTER (so `<C-j>` reaches them, scrolling on a narrow
--- popup); a tab bar in the header (when more than one tab) switches the row set live with `h`/`l`.
--- callback(confirmed, result) where result = table<name, value>; `on_change(row)` on every edit.
--- NOTE: a per-tab DIFFERENT footer is a follow-up — the footer is built from the first tab's actions.
---@param opts UiOpts
function M.tabs(opts)
    opts = opts or {}
    local tabset = opts.tabs or {}
    if #tabset == 0 then
        return
    end
    local cb = opts.callback or function() end
    local active = 1
    local done = false

    -- Split a tab's rows into content (form center) and action rows (footer buttons).
    local function split(ti)
        local content, actions = {}, {}
        for _, r in ipairs((tabset[ti] or {}).rows or {}) do
            if r.type == "action" then
                actions[#actions + 1] = r
            else
                content[#content + 1] = r
            end
        end
        return content, actions
    end
    -- Typed-row values of the active tab, keyed by name (the callback result).
    local function collect()
        local res = {}
        for _, r in ipairs((tabset[active] or {}).rows or {}) do
            if r.name and r.type ~= "action" and r.type ~= "spacer" and r.type ~= "spacer_line" then
                res[r.name] = r.value
            end
        end
        return res
    end

    local content1, actions1 = split(1)
    local form_p = form.new({ rows = content1, on_change = opts.on_change })

    local function action_specs(actions)
        local specs = {}
        for _, a in ipairs(actions) do
            specs[#specs + 1] = {
                key = a.key or (a.label or "?"):sub(1, 1):lower(),
                name = a.label or a.name or "",
                run = function(st)
                    done = true
                    if a.run then
                        a.run(a.value, function(confirmed, r)
                            st.close()
                            if confirmed ~= nil then
                                cb(confirmed == true, r or collect())
                            end
                        end)
                    else
                        st.close()
                    end
                end,
            }
        end
        return specs
    end

    -- Header: optional title/subtitle meta + a tab bar (live switch) when more than one tab.
    local header = { title = opts.title, subtitle = opts.subtitle }
    if #tabset > 1 then
        local tab_btns = {}
        for i, t in ipairs(tabset) do
            tab_btns[i] = {
                type = "label",
                icon = t.icon,
                label = t.label or ("Tab " .. i),
                _tab = i,
                active = (i == 1),
                hl = {
                    normal = { icon = "LvimUiTabIconInactive", label = "LvimUiTabTextInactive" },
                    active = { icon = "LvimUiTabIconActive", label = "LvimUiTabTextActive" },
                },
            }
        end
        header.bands = {
            {
                buttons = tab_btns,
                on_change = function(spec, st)
                    active = spec._tab
                    for _, b in ipairs(tab_btns) do
                        b.active = (b._tab == active)
                    end
                    form_p.set_rows((split(active)))
                    st.refresh_chrome()
                end,
            },
        }
    end
    if not (header.title or header.subtitle or header.bands) then
        header = nil
    end

    frame.open({
        mode = "float",
        border = "rounded",
        panel_border = "none",
        auto_width = true,
        max_width = opts.width or 0.7,
        auto_height = true,
        max_height = opts.height or 0.8,
        header = header,
        panels = { { provider = form_p } },
        footer = (#actions1 > 0) and { actions = action_specs(actions1) } or nil,
        on_close = function()
            if not done then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Read-only info viewer — a 1-panel `frame` that scrolls the content, with a `q close` footer.
--- Returns the panel buffer + window (close via M.close_info or the frame's own keys).
--- NOTE: markview / syntax rendering is not yet ported (plain lines + optional `opts.highlights`).
---@param content string|string[]
---@param opts?   table
---@return integer|nil buf, integer|nil win
function M.info(content, opts)
    opts = opts or {}
    local lines = type(content) == "string" and vim.split(content, "\n")
        or (type(content) == "table" and vim.list_extend({}, content) or {})
    local buf_ref, win_ref
    local provider = {
        size = function()
            local w = 1
            for _, l in ipairs(lines) do
                w = math.max(w, util.dw(l))
            end
            return w + 4, math.max(1, #lines)
        end,
        render = function()
            return lines, opts.highlights or {}
        end,
        keys = function(_, p)
            buf_ref, win_ref = p.buf, p.win
            if opts.on_open then
                opts.on_open(p.buf, p.win)
            end
        end,
    }
    frame.open({
        mode = "float",
        title = opts.title or "Info",
        border = "rounded",
        panel_border = "none",
        auto_width = true,
        max_width = opts.width or 0.7,
        auto_height = true,
        max_height = opts.height or 0.7,
        panels = { { provider = provider } },
        footer = opts.footer == false and nil or {
            actions = {
                {
                    key = "q",
                    name = "close",
                    run = function(st)
                        st.close()
                    end,
                },
            },
        },
    })
    return buf_ref, win_ref
end

--- Two-pane "peek" navigator over a list of source locations: a grouped list on one side, a
--- live preview of the focused location on the other. `opts.mode` ("split" | "float") chooses
--- the presentation; `opts.on_jump(item, cmd)` overrides the default jump.
---@param opts { title?: string, items: table[], mode?: string, on_jump?: fun(item: table, cmd: string) }
---@return boolean opened  false when there were no items
function M.peek(opts)
    return peek.open(opts)
end

--- Programmatically close an info window.
---@param win integer
function M.close_info(win)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end

--- Create an independent UI instance with its own config overrides.
--- Useful when multiple plugins share lvim-utils but need different colours/icons.
---
---@param instance_cfg table  Any subset of the ui config + highlights table.
---   highlights = { LvimUiTitle = { fg = "#..." }, ... }  -- per-instance hl overrides
---   icons      = { bool_on = "X", ... }                  -- per-instance icons
---   keys       = { ... }                                  -- per-instance keymaps
---   labels     = { ... }                                  -- per-instance labels
---@return { select: fun(opts: table), multiselect: fun(opts: table),
---          input: fun(opts: table), tabs: fun(opts: table),
---          info: fun(content: any, opts: table): integer, integer }
function M.new(instance_cfg)
    local inst = {}

    function inst.select(opts)
        opts.mode = "select"
        popup.open(opts, instance_cfg)
    end

    function inst.multiselect(opts)
        opts.mode = "multiselect"
        popup.open(opts, instance_cfg)
    end

    function inst.input(opts)
        opts.mode = "input"
        popup.open(opts, instance_cfg)
    end

    function inst.confirm(opts)
        M.confirm(opts)
    end

    function inst.tabs(opts)
        opts.mode = "tabs"
        return popup.open(opts, instance_cfg)
    end

    function inst.peek(opts)
        return peek.open(opts, instance_cfg)
    end

    function inst.info(content, opts)
        opts = opts or {}
        local lines = type(content) == "string" and vim.split(content, "\n")
            or (type(content) == "table" and vim.list_extend({}, content) or {})
        local buf_ref, win_ref
        local user_on_open = opts.on_open
        opts.mode = "info"
        opts.content = lines
        opts.on_open = function(b, w)
            buf_ref = b
            win_ref = w
            if user_on_open then
                user_on_open(b, w)
            end
        end
        popup.open(opts, instance_cfg)
        return buf_ref, win_ref
    end

    return inst
end

return M
