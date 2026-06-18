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

local frame = require("lvim-utils.ui.frame")
local form = require("lvim-utils.ui.form")
local rows = require("lvim-utils.ui.rows")
local util = require("lvim-utils.ui.util")

local M = {}

---@class UiOpts
---@field title? string|false        -- border-title (false hides it for M.info)
---@field items? any[]               -- select / multiselect items
---@field tabs? table[]              -- tabs: { { label, icon?, rows } , … }
---@field callback? fun(...): any    -- result callback (signature varies per presenter)
---@field on_change? fun(row: table) -- tabs: fired on every typed-row edit
---@field subtitle? string|table|table[]  -- tabs: message line(s) under the title. A string, ONE line `{ text, type?, hl?, icon?, blank_below? }`, or a LIST of such lines. `type` ∈ "info"|"warn"|"error" (predefined fg colour); `hl` overrides; `icon` is fronted when given.
---@field default? any               -- input: initial value
---@field value? any                 -- input: alias for default
---@field prompt? string             -- input: prompt → title fallback
---@field width? number              -- info: FIXED width (fraction ≤1 or count)
---@field height? number             -- info: FIXED height (fraction ≤1 or count)
---@field max_width? number          -- auto-fit cap (fraction ≤1 or count)
---@field max_height? number         -- auto-fit cap (fraction ≤1 or count)
---@field position? string           -- "cursor" (anchor at the cursor) | "win" | "bottom" | "top" | nil (centred)
---@field enter? boolean             -- false → open without focusing (cursor stays in the editor, e.g. hover)
---@field border? any                -- frame border override
---@field close_keys? string[]       -- keys that close the frame
---@field keymaps? table[]           -- extra frame-wide keymaps { { key, run } }
---@field highlights? table[]        -- info: extra content highlights
---@field on_open? fun(buf: integer, win: integer)  -- info: after open
---@field footer? boolean            -- info: false → no footer
---@field footer_items? table[]      -- info: extra footer action buttons { { key, name, run } } before `q close`
---@field hide_cursor? boolean       -- info: hide the hardware cursor (read-only viewer)
---@field wrap? boolean              -- info: enable line wrap in the window (default off)
---@field filetype? string           -- info: set the buffer filetype (e.g. "markdown" → treesitter colours)
---@field markview? boolean          -- info: render the content as markdown via markview.nvim

-- The canonical popup border: a top " " edge (for the native border-title / brand) plus a " " gutter on
-- the LEFT and RIGHT (no bottom, no ring) so the content breathes off the window edges. Titles are always
-- border-titles, blue-tinted — the diagnostics-panel approach. (resolve_border fills the two top corners.)
local FRAME_BORDER = { "", " ", "", " ", "", "", "", " " }

--- Pick one item from a list — a 1-panel `frame` (the list) + a confirm/cancel footer. `<C-j>`
--- descends into the footer (which scrolls to follow the selection on a narrow popup); the list shows
--- its selection via cursorline. callback(confirmed, index, item).
---@param opts UiOpts
function M.select(opts)
    opts = opts or {}
    local items = opts.items or {}
    ---@type fun(...): any
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
        position = opts.position, -- nil = centred; "cursor" anchors at the cursor (e.g. the code-action picker)
        border = FRAME_BORDER,
        title = opts.title or "Select", -- a plain string → a single blue-tinted border-title text box
        panel_border = "none",
        size = {
            width = { auto = true, max = opts.max_width or 0.6 },
            height = { auto = true, max = opts.max_height or 0.6 },
        },
        content = { blocks = { { id = "list", provider = provider } } },
        footer = {
            bars = {
                {
                    items = {
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
    ---@type fun(...): any
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
        border = FRAME_BORDER,
        title = opts.title or "Select",
        panel_border = "none",
        size = { width = { auto = true, max = 0.6 }, height = { auto = true, max = 0.6 } },
        content = { blocks = { { id = "list", provider = provider } } },
        footer = {
            bars = {
                {
                    items = {
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
    ---@type fun(...): any
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
        border = FRAME_BORDER,
        title = opts.title or opts.prompt or "Input",
        panel_border = "none",
        size = { width = { auto = true, max = opts.width or 0.6 }, height = { auto = true } },
        content = { blocks = { { id = "input", provider = provider } } },
        footer = {
            bars = {
                {
                    items = {
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
    ---@type fun(...): any
    local cb = opts.callback or function() end
    M.select({
        title = opts.title or opts.prompt or " Confirm",
        items = items,
        callback = function(confirmed, index)
            cb(confirmed == true and items[index] == yes_label)
        end,
    })
end

--- Semantic subtitle `type` → its (fg-only) highlight group. A line may instead carry an explicit `hl`.
---@type table<string, string>
local SUBTITLE_TYPES = {
    info = "LvimUiSubtitleInfo", -- blue
    warn = "LvimUiSubtitleWarn", -- orange
    error = "LvimUiSubtitleError", -- red
}

--- Normalise `opts.subtitle` into header meta bars. Accepts a plain string, a single line table
--- `{ text, type?, hl?, icon?, blank_below? }`, or a LIST of such lines (a multi-line subtitle). Each line's
--- colour is its explicit `hl`, else its `type`'s predefined group, else the default `LvimUiSubtitle`; an
--- `icon` (optional, never implied by a type) is fronted; `blank_below` adds an empty row beneath the line.
---@param subtitle string|table|nil
---@return table[]
local function subtitle_bars(subtitle)
    if not subtitle then
        return {}
    end
    ---@type table
    local list
    if type(subtitle) ~= "table" or subtitle.text then
        list = { subtitle } -- a single line (string or `{ text = … }`) → a one-element list
    else
        list = subtitle -- already a LIST of line specs
    end
    local out = {}
    for _, ln in ipairs(list) do
        if type(ln) == "string" then
            out[#out + 1] = { text = ln, hl = "LvimUiSubtitle" }
        else
            local hl = ln.hl or (ln.type and SUBTITLE_TYPES[ln.type]) or "LvimUiSubtitle"
            out[#out + 1] = { text = (ln.icon and (ln.icon .. "  ") or "") .. (ln.text or ""), hl = hl }
            if ln.blank_below then
                out[#out + 1] = { text = "" } -- one empty meta band = a blank row under this line
            end
        end
    end
    return out
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
    ---@type fun(...): any
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
        -- Drop trailing spacer / divider rows from the body: they separated the fields from the action
        -- rows, which now live in the FOOTER, so otherwise they dangle (a stray ────── at the bottom).
        while #content > 0 and (content[#content].type == "spacer" or content[#content].type == "spacer_line") do
            content[#content] = nil
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

    -- Header bars: an optional subtitle text bar + a tab bar (live switch) when more than one tab. The
    -- TITLE is the frame's border-title, not a header bar.
    local bars = {}
    local set_active_tab -- (multi-tab) switch to a tab; shared by the tab bar and the body l/h keymaps
    for _, b in ipairs(subtitle_bars(opts.subtitle)) do
        bars[#bars + 1] = b
    end
    if #tabset > 1 then
        local tab_btns = {}
        for i, t in ipairs(tabset) do
            tab_btns[i] = {
                type = "button",
                icon = t.icon,
                text = t.label or ("Tab " .. i),
                _tab = i,
                active = (i == 1),
                style = {
                    icon = {
                        padding = { 2, 2 },
                        normal = "LvimUiTabIconInactive",
                        active = "LvimUiTabIconActive",
                        hover = "LvimUiTabIconHover",
                    },
                    text = {
                        padding = { 2, 2 },
                        normal = "LvimUiTabTextInactive",
                        active = "LvimUiTabTextActive",
                        hover = "LvimUiTabTextHover",
                    },
                },
            }
        end
        local tab_bar = { items = tab_btns }
        set_active_tab = function(st, i)
            i = math.max(1, math.min(i, #tabset))
            if i == active then
                return
            end
            active = i
            tab_bar._sel = active
            for _, b in ipairs(tab_btns) do
                b.active = (b._tab == active)
            end
            form_p.set_rows((split(active)))
            -- Re-fit to the new tab's content (dynamic height) + re-render chrome.
            if st.relayout then
                st.relayout()
            else
                st.refresh_chrome()
            end
        end
        tab_bar.on_change = function(spec, st)
            set_active_tab(st, spec._tab)
        end
        bars[#bars + 1] = tab_bar
        bars[#bars + 1] = { text = "" } -- 1 blank "air" row between the tab bar and the content
    end

    local st = frame.open({
        mode = "float",
        border = opts.border or FRAME_BORDER,
        title = opts.title, -- border-title, blue-tinted (LvimUiPeekTitle)
        close_keys = opts.close_keys,
        keymaps = opts.keymaps,
        panel_border = "none",
        -- A given `width` is FIXED (e.g. the per-server form at 0.8); otherwise the frame auto-fits the
        -- content (capped at 0.7). Height is always dynamic (fits the active tab), capped at `height` ⊕ 0.9.
        size = {
            width = opts.width and { fixed = opts.width } or { auto = true, max = 0.7 },
            height = { auto = true, max = opts.height or 0.9 },
        },
        header = (#bars > 0) and { bars = bars } or nil,
        content = { blocks = { { id = "form", provider = form_p } } },
        footer = (#actions1 > 0) and { bars = { { items = action_specs(actions1) } } } or nil,
        on_close = function()
            if not done then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })

    -- `l` / `h` switch tabs from the content body too (multi-tab) — not only while the tab bar is focused,
    -- matching the project panel. (Plain h/l are free on the body; the form owns j/k/<CR>.)
    if set_active_tab then
        local body_buf = st.panels[1] and st.panels[1].buf
        if body_buf and vim.api.nvim_buf_is_valid(body_buf) then
            vim.keymap.set("n", "l", function()
                set_active_tab(st, active + 1)
            end, { buffer = body_buf, nowait = true, silent = true })
            vim.keymap.set("n", "h", function()
                set_active_tab(st, active - 1)
            end, { buffer = body_buf, nowait = true, silent = true })
        end
    end
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
        -- A read-only viewer may hide the hardware cursor (delegated to lvim-utils.cursor via FRAME_FT);
        -- the active line still reads via cursorline. Off by default (e.g. hover keeps the cursor).
        hide_cursor = opts.hide_cursor == true,
        size = function()
            local w = 1
            for _, l in ipairs(lines) do
                w = math.max(w, util.dw(l))
            end
            return w + 4, math.max(1, #lines)
        end,
        render = function()
            -- Accept BOTH the positional `{ row, c0, c1, hl[, prio] }` and the named
            -- `{ line, col_start, col_end, group }` highlight shapes (the LSP info builder uses the
            -- latter); a `-1` end_col means "to the end of the line".
            local hls = {}
            for _, h in ipairs(opts.highlights or {}) do
                local row = h.line ~= nil and h.line or h[1]
                local c0 = h.col_start ~= nil and h.col_start or h[2]
                local c1 = h.col_end ~= nil and h.col_end or h[3]
                if c1 == -1 then
                    c1 = #(lines[(row or 0) + 1] or "")
                end
                hls[#hls + 1] = { row, c0, c1, h.group or h[4], h[5] }
            end
            return lines, hls
        end,
        keys = function(_, p)
            buf_ref, win_ref = p.buf, p.win
            -- Line wrap is window-local — off by default (a viewer); a consumer may enable it (e.g. hover).
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                vim.wo[p.win].wrap = opts.wrap == true
            end
            if opts.markview then
                -- Optional, explicit opt-in: render the WHOLE content buffer with markview.nvim (the frame
                -- keeps header/footer in separate buffers, so there is no row offset). Its decorations add
                -- virtual lines, so the rendered content can be taller than the raw line count.
                local pr_ok, mv_parser = pcall(require, "markview.parser")
                local rn_ok, mv_renderer = pcall(require, "markview.renderer")
                if pr_ok and rn_ok then
                    vim.bo[p.buf].filetype = "markdown"
                    local ac_ok, mv_actions = pcall(require, "markview.actions")
                    if ac_ok then
                        pcall(mv_actions.clear, p.buf)
                    end
                    local ok2, content = pcall(mv_parser.parse, p.buf, 0, -1, true)
                    if ok2 and content then
                        pcall(mv_renderer.render, p.buf, content)
                    end
                end
            elseif opts.filetype then
                -- Colour via the treesitter highlighter DIRECTLY — NEVER `:set filetype`. Setting the
                -- filetype would fire markview's auto-attach (it gates on `filetype`), which boxes code
                -- blocks with virtual lines + cursor-aware conceal. treesitter gives the same colours
                -- (headers, emphasis, fenced-code injections) with none of that. `conceallevel = 2` lets the
                -- markdown query hide the ``` fence delimiters (whole lines, via `conceal_lines`) and inline
                -- backticks; `concealcursor` keeps them hidden STABLY — never revealed on the cursor line.
                pcall(vim.treesitter.start, p.buf, opts.filetype)
                if p.win and vim.api.nvim_win_is_valid(p.win) then
                    vim.wo[p.win].conceallevel = 2
                    vim.wo[p.win].concealcursor = "nvic"
                end
            end
            if opts.on_open then
                opts.on_open(p.buf, p.win)
            end
        end,
    }
    -- Footer: the consumer's extra action buttons (`opts.footer_items` — e.g. fold all / unfold all),
    -- then the standard `q close`. Each is a footer action shorthand `{ key, name, run }`.
    local footer_items = {}
    for _, it in ipairs(opts.footer_items or {}) do
        footer_items[#footer_items + 1] = it
    end
    footer_items[#footer_items + 1] = {
        key = "q",
        name = "close",
        run = function(st)
            st.close()
        end,
    }
    frame.open({
        mode = "float",
        enter = opts.enter, -- false → open WITHOUT focusing (cursor stays in the editor, e.g. hover)
        position = opts.position, -- nil = centred; "cursor" anchors at the cursor (e.g. hover), "win", …
        border = opts.border or FRAME_BORDER,
        title = opts.title ~= false and (opts.title or "Info") or nil, -- border-title, blue-tinted
        close_keys = opts.close_keys,
        keymaps = opts.keymaps,
        panel_border = "none",
        -- A given `width` / `height` is FIXED (a clean rectangle — e.g. the LSP info viewer, whose folded
        -- height the consumer computes); else auto-fit to content, capped by `max_width` / `max_height`
        -- (fraction ≤ 1 or absolute count; default 0.7 / 0.85). A cursor-anchored hover passes a tight cap.
        size = {
            width = opts.width and { fixed = opts.width } or { auto = true, max = opts.max_width or 0.7 },
            height = opts.height and { fixed = opts.height } or { auto = true, max = opts.max_height or 0.85 },
        },
        content = { blocks = { { id = "info", provider = provider } } },
        footer = opts.footer == false and nil or { bars = { { items = footer_items } } },
    })
    return buf_ref, win_ref
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
    local _ = instance_cfg -- reserved: per-instance colour/icon overrides are a follow-up
    -- Every presenter is now the shared frame-based one, so an instance is a thin namespace over the
    -- module functions (kept for API compatibility — e.g. lvim-lsp calls `ui.new(cfg).tabs(...)`).
    return {
        select = M.select,
        multiselect = M.multiselect,
        input = M.input,
        confirm = M.confirm,
        tabs = M.tabs,
        info = M.info,
    }
end

return M
