-- lua/lvim-utils/msgarea/init.lua
-- A persistent, toggleable MESSAGE AREA docked under (or over) the editor — an Emacs-minibuffer-ish
-- zone where messages STAY readable instead of vanishing after a timeout / on the next cursor move.
--
-- It is NOT a second `vim.ui_attach` and does NOT patch any Neovim internals (unlike msgarea.nvim).
-- The notify hub is the single `ext_messages` owner; it captures / de-dups / levels every message and
-- routes by kind to a behaviour. This module registers a "msgarea" SINK with that hub and renders
-- whatever is routed to it into a window IT owns — so it inherits all of notify's message handling.
--
-- Height: `max_height` is the only hard rule. `auto_resize` (toggleable) fits the panel to its
-- content up to that cap (5 rows -> 5 tall, 12 rows -> pinned to the cap and scrolling); off = a
-- fixed `max_height`. Both heights take >= 1 as absolute lines and < 1 as a fraction of the screen.
--
---@module "lvim-utils.msgarea"

local api = vim.api
local levels = vim.log.levels

local M = {}

local FT = "lvim-msgarea"
local ns = api.nvim_create_namespace("lvim_utils_msgarea")

---@class LvimMsgAreaMsg
---@field text string
---@field level integer
---@field count integer
---@field ts integer

---@type table  the live config (set by setup)
local cfg = {}
---@type LvimMsgAreaMsg[]  the scrollback ring buffer
local ring = {}
---@type integer? the panel window
local win = nil
---@type integer? the panel buffer
local buf = nil
---@type integer? autocmd group
local augroup = nil
---@type integer  non-reserve line count of the last render (drives the auto-resize clamp)
local content_lines = 0

-- ─── segment stack ──────────────────────────────────────────────────────────────
-- The zone is a vertical stack of named SEGMENTS ordered by `priority` (low = top, high = bottom).
-- Every owner — messages, the completion grid, the unified cmdline, and any external plugin — puts
-- content in through a segment; the core just composes them. The three built-ins (messages /
-- completion / cmdline) are thin wrappers over this same model, so nothing about them is special.

---@class LvimMsgAreaSegment
---@field name string
---@field priority integer  stack order: low = top of the zone, high = bottom
---@field kind "lines"|"grid"|"reserve"|"provider"
---@field lines? string[]  (lines kind) pre-built content lines
---@field hls? table  (lines kind) parallel to `lines`: a whole-row hl name OR a span list
---@field items? table[]  (grid kind) neutral items `{ text, icon?, icon_hl? }`
---@field selected? integer  (grid kind) selected 1-based index
---@field columns? integer  (grid kind) column count
---@field max_rows? integer  (grid kind) max visible rows (windowed around the selection)
---@field height? integer  (reserve kind) blank rows held for an external float to overlay
---@field render? fun(width: integer): string[], table?  (provider kind) lazy content
---@field on_confirm? fun(item: table?, idx: integer?)  fired on <CR> while the zone is focused (grid)
---@field on_move? fun(idx: integer)  fired when the selection moves while the zone is focused (grid)
---@field keys? table<string, fun(handle: table)>  custom keymaps active while this segment is focused
---@field title? string  an optional header row drawn above this segment's content (separates owners)

---@type LvimMsgAreaSegment[]  the stack, kept sorted by priority
local segments = {}
---@type table<string, LvimMsgAreaSegment>  name → segment
local by_name = {}
---@type string?  the segment receiving focused keyboard interaction (nil = passive / not focused)
local active_name = nil
---@type integer?  the window focus returns to on blur
local prev_win = nil
---@type string[]  buffer keymap lhs's installed for focused interaction (cleared on blur)
local interaction_keys = {}

-- The user's `cmdheight` before we grew it for the zone (restored when the zone hides).
---@type integer?
local base_cmdheight = nil
-- Last applied float geometry — to skip a redundant nvim_win_set_config on every render (navigation).
---@type { row: integer, height: integer, width: integer }?
local last_geom = nil

-- level → { LvimUiMsg<Name> highlight suffix, notify icon key }.
---@type table<integer, { name: string, icon: string }>
local LEVEL = {
    [levels.ERROR] = { name = "Error", icon = "error" },
    [levels.WARN] = { name = "Warn", icon = "warn" },
    [levels.INFO] = { name = "Info", icon = "info" },
    [levels.DEBUG] = { name = "Debug", icon = "debug" },
    [levels.TRACE] = { name = "Debug", icon = "trace" },
}

-- ─── helpers ──────────────────────────────────────────────────────────────────

--- Resolve a height value: >= 1 = absolute lines, < 1 = a fraction of `vim.o.lines`.
---@param v number|nil
---@return integer|nil
local function resolve(v)
    if not v then
        return nil
    end
    return v < 1 and math.max(1, math.floor(vim.o.lines * v)) or math.floor(v)
end

--- The notify level icon for `level` (read live from notify's config, so they stay in sync).
---@param level integer
---@return string
local function level_icon(level)
    if not cfg.icons then
        return ""
    end
    local key = (LEVEL[level] or LEVEL[levels.INFO]).icon
    local icons = (require("lvim-utils.config").notify or {}).icons or {}
    local ic = icons[key]
    return ic and (ic .. " ") or ""
end

--- Truncate `s` to at most `maxw` display columns, adding `…` when cut.
---@param s string
---@param maxw integer
---@return string
local function trunc(s, maxw)
    if maxw <= 0 then
        return ""
    end
    if vim.fn.strdisplaywidth(s) <= maxw then
        return s
    end
    local acc, cur = {}, 0
    for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
        local cw = vim.fn.strdisplaywidth(ch)
        if cur + cw > maxw - 1 then
            break
        end
        acc[#acc + 1] = ch
        cur = cur + cw
    end
    return table.concat(acc) .. "…"
end

--- One completion cell: ` icon label ` — a 1-column leading space, the kind icon, the label, then padded
--- to `w` display columns leaving ≥ 1 trailing space (so adjacent grid columns never touch). The cell is
--- one contiguous padded string, so a span over its full byte range tints it edge-to-edge (space to space).
--- Also returns BYTE spans (within the cell) for the item's matched LABEL characters (`it.match`, a list of
--- 0-based char indices — SOURCE-AGNOSTIC: blink fills it from its fuzzy, other consumers however they like).
---@param it table?  a neutral item `{ text, icon?, icon_hl?, match? }`
---@param w integer
---@return string cell, { c0: integer, c1: integer }[]? match_spans
local function build_cell(it, w)
    if not it then
        return string.rep(" ", w), nil
    end
    local icon = (it.icon and it.icon ~= "") and (it.icon .. " ") or ""
    local label = (it.text or ""):gsub("[\r\n]+", " ")
    -- Leading space + body, truncated so 1 trailing column is always free, then padded back to `w`.
    local content = " " .. trunc(icon .. label, math.max(1, w - 2))
    local pad = w - vim.fn.strdisplaywidth(content)
    local cell = content .. string.rep(" ", math.max(0, pad))

    local spans = nil
    if it.match and #it.match > 0 then
        local label_base = 1 + #icon -- the leading space + the icon precede the label within `content`
        local limit = #content -- nothing past the (possibly truncated) visible content
        local nchars = vim.fn.strchars(label)
        for _, ci in ipairs(it.match) do
            if ci >= 0 and ci < nchars then
                local b0 = label_base + vim.str_byteindex(label, ci)
                if b0 < limit then -- the matched char is within the visible part of the cell
                    spans = spans or {}
                    spans[#spans + 1] = { c0 = b0, c1 = math.min(label_base + vim.str_byteindex(label, ci + 1), limit) }
                end
            end
        end
    end
    return cell, spans
end

-- ─── segment registry ──────────────────────────────────────────────────────────

--- Re-sort the stack by priority (low = top). Called when a segment is added or re-prioritised.
local function seg_sort()
    table.sort(segments, function(a, b)
        return a.priority < b.priority
    end)
end

--- Get an existing segment by name, or create it. `opts.kind` / `opts.priority` apply on create and
--- update an existing one when given.
---@param name string
---@param opts? { priority?: integer, kind?: string }
---@return LvimMsgAreaSegment
local function seg_get(name, opts)
    local s = by_name[name]
    if not s then
        s = { name = name, priority = (opts and opts.priority) or 100, kind = (opts and opts.kind) or "lines" }
        by_name[name] = s
        segments[#segments + 1] = s
        seg_sort()
        return s
    end
    if opts then
        if opts.kind then
            s.kind = opts.kind
        end
        if opts.priority and opts.priority ~= s.priority then
            s.priority = opts.priority
            seg_sort()
        end
    end
    return s
end

--- Drop a segment from the stack entirely.
---@param name string
local function seg_remove(name)
    local s = by_name[name]
    if not s then
        return
    end
    by_name[name] = nil
    for i = #segments, 1, -1 do
        if segments[i] == s then
            table.remove(segments, i)
            break
        end
    end
end

--- Whether a segment currently contributes anything to the zone.
---@param s LvimMsgAreaSegment
---@return boolean
local function seg_has_content(s)
    if s.kind == "reserve" then
        return (s.height or 0) > 0
    elseif s.kind == "grid" then
        return s.items ~= nil and #s.items > 0
    elseif s.kind == "provider" then
        return s.render ~= nil
    end
    return s.lines ~= nil and #s.lines > 0
end

--- Sum of all reserve-segment heights (rows held for external floats, e.g. the unified cmdline).
---@return integer
local function total_reserved()
    local r = 0
    for _, s in ipairs(segments) do
        if s.kind == "reserve" then
            r = r + (s.height or 0)
        end
    end
    return r
end

--- Render a GRID segment into lines + per-row highlight spans (the tint-canon completion grid). Returns
--- the lines, the parallel hls, and the LOCAL (1-based within these lines) selected row, or nil.
---@param seg LvimMsgAreaSegment
---@return string[] lines, table hls, integer? sel_local
local function render_grid(seg)
    local items = seg.items or {}
    local lines, hls = {}, {}
    if #items == 0 then
        return lines, hls, nil
    end
    local C = math.max(1, seg.columns or 1)
    local sel = seg.selected or 0
    local total = #items
    local rows_total = math.ceil(total / C)
    local max_rows = math.max(1, math.min(rows_total, seg.max_rows or 12))
    local sel_grid_row = sel > 0 and math.ceil(sel / C) or 1
    local start_row = (sel_grid_row > max_rows) and (sel_grid_row - max_rows + 1) or 1
    local cell_w = math.max(4, math.floor(vim.o.columns / C))
    local sel_local = nil
    for r = start_row, math.min(rows_total, start_row + max_rows - 1) do
        -- Tint canon: the whole row (icon + label) is the row's accent fg over a light tint of it
        -- (odd BLUE, even YELLOW); the selected cell raises the tint of THAT accent. The stripe is a
        -- full-line eol span (low priority) the per-cell selection paints over.
        local odd = (r % 2) == 1
        local row_hl = odd and "LvimUiMsgAreaRowOdd" or "LvimUiMsgAreaRowEven"
        local sel_hl = odd and "LvimUiMsgAreaSelOdd" or "LvimUiMsgAreaSelEven"
        local parts, spans, byte_col = {}, { { eol = true, hl = row_hl, priority = 100 } }, 0
        for c = 1, C do
            local idx = (r - 1) * C + c
            local it = idx <= total and items[idx] or nil
            local cell, mspans = build_cell(it, cell_w)
            parts[c] = cell
            if it and idx == sel then
                spans[#spans + 1] = { c0 = byte_col, c1 = byte_col + #cell, hl = sel_hl, priority = 200 }
            end
            if mspans then -- the fuzzy-matched characters, above the row stripe AND the selection
                for _, ms in ipairs(mspans) do
                    spans[#spans + 1] =
                        { c0 = byte_col + ms.c0, c1 = byte_col + ms.c1, hl = "LvimUiMsgAreaMatch", priority = 250 }
                end
            end
            byte_col = byte_col + #cell
        end
        lines[#lines + 1] = table.concat(parts)
        hls[#hls + 1] = spans
        if sel > 0 and r == sel_grid_row then
            sel_local = #lines
        end
    end
    return lines, hls, sel_local
end

--- Rebuild the built-in `messages` segment's lines from the scrollback ring (icon badge + text +
--- per-level whole-row highlight). Called by the notify sink and on clear.
local function refresh_messages()
    local s = seg_get("messages", { kind = "lines", priority = 10 })
    local lines, hls = {}, {}
    for _, m in ipairs(ring) do
        local prefix = cfg.timestamps and (os.date(cfg.time_format or "%H:%M:%S", m.ts) .. " ") or ""
        local suffix = (m.count > 1) and ("  (x" .. m.count .. ")") or ""
        local body = prefix .. level_icon(m.level) .. m.text .. suffix
        local name = "LvimUiMsg" .. (LEVEL[m.level] or LEVEL[levels.INFO]).name
        for _, ln in ipairs(vim.split(body, "\n", { plain = true })) do
            lines[#lines + 1] = ln
            hls[#hls + 1] = name
        end
    end
    s.lines = lines
    s.hls = hls
end

-- ─── render / sizing ──────────────────────────────────────────────────────────

--- The zone's height: the MESSAGE area clamped to `[min, max]` (auto_resize) or pinned to `max` (incl.
--- the winbar row, never exceeding `max_height` — the one hard rule), plus the unified cmdline's
--- `reserved` rows ON TOP, so the input is always fully visible.
---@return integer
local function compute_height()
    local maxh = resolve(cfg.max_height) or 10
    local wb = cfg.winbar and 1 or 0
    if cfg.auto_resize ~= false then
        local minh = resolve(cfg.min_height) or 1
        local cmax = math.max(1, maxh - wb)
        -- The min-height floor applies ONLY when there is message/completion content; with NONE (e.g. just
        -- the cmdline), the message area is 0 rows — else an empty dark row would sit under the cmdline.
        local shown = content_lines > 0 and math.max(minh, math.min(content_lines, cmax)) or 0
        return math.max(1, wb + shown + total_reserved()) -- never 0 (a fresh open before the first render)
    end
    return math.max(1, maxh + total_reserved())
end

--- Lay the float over the bottom `h` rows — the `cmdheight` region BELOW the global statusline (so
--- heirline stays permanently above the zone). `cmdheight` is grown to reserve those rows.
local function resize()
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    local h = compute_height()
    if vim.o.cmdheight ~= h then
        vim.o.cmdheight = h
    end
    local row = math.max(0, vim.o.lines - h)
    local width = vim.o.columns
    -- Only reconfigure when the geometry actually changed — set_config forces a redraw, and during
    -- grid NAVIGATION the height/position are stable, so this skips it on every selection move.
    if last_geom and last_geom.row == row and last_geom.height == h and last_geom.width == width then
        return
    end
    pcall(api.nvim_win_set_config, win, {
        relative = "editor",
        row = row,
        col = 0,
        width = width,
        height = h,
    })
    last_geom = { row = row, height = h, width = width }
end

--- Compose the segment stack top-to-bottom into the buffer, apply highlights, resize, and tail.
local function render()
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    -- Walk the stack in priority order (messages → completion grid → … → cmdline reserve). Each segment
    -- contributes lines + a parallel `hls` entry per line (a whole-row hl name, a span list, or `false`
    -- for no highlight). Reserve segments contribute blank rows for an external float to overlay.
    local lines, hls = {}, {}
    local reserved_total, sel_row = 0, nil
    for _, s in ipairs(segments) do
        -- 1) gather this segment's own lines + hls (+ grid selection)
        local seg_lines, seg_hls, sel_local = {}, {}, nil
        if s.kind == "reserve" then
            for _ = 1, (s.height or 0) do
                seg_lines[#seg_lines + 1] = ""
                seg_hls[#seg_hls + 1] = false
            end
            reserved_total = reserved_total + (s.height or 0)
        elseif s.kind == "grid" then
            seg_lines, seg_hls, sel_local = render_grid(s)
        elseif s.kind == "provider" and s.render then
            local ok, pl, ph = pcall(s.render, vim.o.columns)
            seg_lines = (ok and type(pl) == "table") and pl or {}
            for i = 1, #seg_lines do
                seg_hls[i] = (ph and ph[i]) or false
            end
        elseif s.lines then -- lines kind
            for i = 1, #s.lines do
                seg_lines[i] = s.lines[i]
                seg_hls[i] = (s.hls and s.hls[i]) or false
            end
        end

        -- 2) a title header row above the content (only when the segment actually has content, never a reserve)
        if s.title and #seg_lines > 0 and s.kind ~= "reserve" then
            lines[#lines + 1] = " " .. s.title
            hls[#hls + 1] = "LvimUiMsgAreaTitle"
        end

        -- 3) append, offsetting the segment's selected row into the buffer
        local base = #lines
        for i = 1, #seg_lines do
            lines[#lines + 1] = seg_lines[i]
            hls[#hls + 1] = seg_hls[i]
        end
        if sel_local then
            sel_row = base + sel_local
        end
    end

    content_lines = #lines - reserved_total -- everything except the reserved cmdline padding
    if #lines == 0 then
        lines = { "" }
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, g in ipairs(hls) do
        if type(g) == "string" then -- a whole-row highlight (a message line)
            pcall(api.nvim_buf_set_extmark, buf, ns, i - 1, 0, { end_row = i, hl_group = g, hl_eol = true })
        elseif type(g) == "table" then -- per-cell highlight spans (a grid row)
            for _, sp in ipairs(g) do
                if sp.eol then -- a full-row stripe (bg to the right edge)
                    pcall(api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
                        end_row = i,
                        hl_group = sp.hl,
                        hl_eol = true,
                        priority = sp.priority,
                    })
                else
                    pcall(api.nvim_buf_set_extmark, buf, ns, i - 1, sp.c0, {
                        end_col = sp.c1,
                        hl_group = sp.hl,
                        priority = sp.priority,
                    })
                end
            end
        end
    end
    resize()
    -- Keep the selected completion (or the newest message) in view, just above the reserved cmdline rows.
    if cfg.follow ~= false and win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_set_cursor, win, { math.max(1, sel_row or content_lines), 0 })
    end
    -- In COMMAND-LINE mode the screen does not repaint on its own between events, so a render done from a
    -- blink autocmd would otherwise only become visible on the next cmdline redraw (the 500ms cursor blink)
    -- — i.e. the completion would appear ~¼s late. Flush now so the grid shows the instant the list lands.
    if vim.fn.mode():sub(1, 1) == "c" then
        pcall(api.nvim__redraw, { flush = true })
    end
end

-- ─── window ───────────────────────────────────────────────────────────────────

--- Apply the panel's window-local options + a themed winbar. Does not move focus.
local function dress_win()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = false
    vim.wo[win].list = false
    vim.wo[win].wrap = cfg.wrap ~= false
    vim.wo[win].winhighlight = "Normal:LvimUiMsgAreaNormal,EndOfBuffer:LvimUiMsgAreaNormal"
    if cfg.winbar then
        vim.wo[win].winbar = "%#LvimUiMsgAreaTitle# " .. (cfg.title or "Messages") .. " %#LvimUiMsgAreaTitleFill#%="
    else
        vim.wo[win].winbar = nil
    end
end

--- Buffer-local keymaps, active only while the panel is the current window.
local function map_keys()
    local k = cfg.keys or {}
    local function nmap(lhs, fn)
        if lhs then
            pcall(vim.keymap.set, "n", lhs, fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    nmap(k.close, function()
        M.hide()
    end)
    nmap(k.clear, function()
        M.clear()
    end)
    nmap(k.scroll_up, "<C-u>")
    nmap(k.scroll_down, "<C-d>")
    nmap(k.top, "gg")
    nmap(k.bottom, "G")
end

--- Open the zone as a FLOAT over the `cmdheight` region (the bottom of the screen, BELOW the global
--- statusline). Idempotent; never steals focus.
local function open()
    if win and api.nvim_win_is_valid(win) then
        return
    end
    if not (buf and api.nvim_buf_is_valid(buf)) then
        buf = api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile" -- so lvim-colorscheme `dim` treats it as non-real (never dimmed)
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].swapfile = false
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = FT
    end
    local h = compute_height()
    if base_cmdheight == nil then
        base_cmdheight = vim.o.cmdheight -- remember the user's cmdheight to restore on hide
    end
    vim.o.cmdheight = h
    win = api.nvim_open_win(buf, false, {
        relative = "editor",
        row = math.max(0, vim.o.lines - h),
        col = 0,
        width = vim.o.columns,
        height = h,
        style = "minimal",
        focusable = cfg.focusable ~= false,
        zindex = 200, -- below the unified cmdline float (zindex 300)
        border = "none",
    })
    dress_win()
    map_keys()
    render()
end

--- Close the float and RELEASE the reserved `cmdheight` rows (the scrollback model is kept).
local function close()
    if win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
    end
    win = nil
    last_geom = nil -- geometry is recomputed on the next open
    active_name = nil -- focus state drops with the window (interaction keymaps are re-set on next focus)
    prev_win = nil
    vim.o.cmdheight = base_cmdheight or 0
    base_cmdheight = nil -- re-capture on the next open
end

--- True when ANY segment has content (messages, a completion grid, an active cmdline reserve, …).
---@return boolean
local function has_content()
    for _, s in ipairs(segments) do
        if seg_has_content(s) then
            return true
        end
    end
    return false
end

--- Show the zone when it has content, hide it (and release `cmdheight`) when empty — so it is invisible
--- whenever there is nothing to display.
local function update_visibility()
    -- The `enable` master switch gates the AUTOMATIC open (so a segment pushed while the area is toggled
    -- off never reopens it); closing always works, and M.show() bypasses this for an explicit reveal.
    if has_content() and cfg.enable then
        if win and api.nvim_win_is_valid(win) then
            render()
        else
            open()
        end
    elseif win and api.nvim_win_is_valid(win) then
        close()
    end
end

-- ─── sink ─────────────────────────────────────────────────────────────────────

--- The notify "msgarea" sink: append a routed message and refresh.
---@param text string
---@param level integer
local function on_message(text, level)
    if not cfg.enable or type(text) ~= "string" or text == "" then
        return
    end
    level = level or levels.INFO
    local last = ring[#ring]
    if cfg.dedup ~= false and last and last.text == text and last.level == level then
        last.count = last.count + 1
        last.ts = os.time()
    else
        ring[#ring + 1] = { text = text, level = level, count = 1, ts = os.time() }
        local cap = cfg.scrollback or 500
        while #ring > cap do
            table.remove(ring, 1)
        end
    end
    refresh_messages()
    update_visibility()
end

-- ─── public API ───────────────────────────────────────────────────────────────

--- Turn the area ON: register the sink, route its kinds, install resize autocmd.
function M.enable()
    cfg.enable = true
    local notify = require("lvim-utils.notify")
    notify.register_sink("msgarea", on_message)
    notify.route_kinds(cfg.kinds or {})

    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
    end
    augroup = api.nvim_create_augroup("LvimUtilsMsgArea", { clear = true })
    api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = function()
            if win and api.nvim_win_is_valid(win) then
                vim.schedule(render)
            end
        end,
    })

    -- The zone is HIDDEN while empty; it appears only when there is something to show (a message, the
    -- unified cmdline, or a completion list). Rebuild the messages segment from any retained scrollback.
    refresh_messages()
    update_visibility()
end

--- Turn the area OFF: full teardown (unroute, unregister, close, drop autocmds). The model is kept.
function M.disable()
    cfg.enable = false
    local notify = require("lvim-utils.notify")
    notify.unroute_kinds(vim.tbl_keys(cfg.kinds or {}))
    notify.register_sink("msgarea", nil)
    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
    close()
end

--- Flip enable/disable (the command / a keymap calls this).
function M.toggle()
    if cfg.enable then
        M.disable()
    else
        M.enable()
    end
end

--- Open / reveal the panel without changing `enable`.
function M.show()
    open()
end

--- Hide the panel (the scrollback model is retained).
function M.hide()
    close()
end

--- (Unified) Reserve `height` rows at the BOTTOM of the zone for the command-line, ensure the panel
--- is open, and return where the cmdline float should anchor (relative to this window) — or nil when
--- unified is off / disabled. Called by lvim-utils.cmdline on every cmdline render.
---@param height integer
---@return { win: integer, line: integer, width: integer }?
function M.cmdline_host(height)
    if not (cfg.enable and cfg.unified) then
        return nil
    end
    local s = seg_get("cmdline", { kind = "reserve", priority = 1000 })
    s.height = math.max(0, height or 0)
    update_visibility() -- opens the float (reserve > 0 ⇒ has content) and renders
    if not (win and api.nvim_win_is_valid(win)) then
        return nil
    end
    return { win = win, line = content_lines, width = api.nvim_win_get_width(win) }
end

--- (Unified) Release the command-line's reserved rows and reflow (hides the zone if nothing remains).
function M.cmdline_done()
    local s = by_name["cmdline"]
    if not s or (s.height or 0) == 0 then
        return
    end
    s.height = 0
    update_visibility()
end

--- Intercepted completion: an integration (e.g. blink) hands us its live items + selection; we render
--- them IN the zone (above the cmdline). The source engine stays in charge — we only visualise.
---@param items table[]  completion items (each with a `label`)
---@param selected integer?  the selected index (1-based), or nil
function M.set_completion(items, selected)
    if not cfg.enable then
        return
    end
    local s = seg_get("completion", { kind = "grid", priority = 50 })
    s.items = items or {}
    s.selected = selected
    s.columns = cfg.completion_columns
    s.max_rows = cfg.completion_max
    update_visibility()
end

--- Update ONLY the selected index and re-render — the cheap path for grid NAVIGATION, where the item
--- list is unchanged so the integration must NOT re-translate every item. Re-renders so the highlight
--- (and the windowed view) follow the new selection.
---@param selected integer?  the selected index (1-based), or nil
function M.set_completion_selected(selected)
    if not cfg.enable then
        return
    end
    local s = by_name["completion"]
    if not s or s.items == nil then
        return
    end
    s.selected = selected
    update_visibility()
end

--- Drop the intercepted completion list and reflow (hides the zone if nothing remains).
function M.clear_completion()
    local s = by_name["completion"]
    if not s or s.items == nil then
        return
    end
    s.items = nil
    update_visibility()
end

--- Wipe the scrollback and reflow (hides the zone if nothing else remains).
function M.clear()
    ring = {}
    refresh_messages()
    update_visibility()
end

-- ─── public segment API ─────────────────────────────────────────────────────────
-- The seam every plugin uses to put content into the zone. `M.segment(name)` returns a HANDLE to a
-- named segment (get-or-create); its methods mutate that segment and reflow. The built-in messages /
-- completion / cmdline wrappers above drive the SAME registry, so external content composes with them.

--- @class LvimMsgAreaHandle
--- @field name string
local Handle = {}
Handle.__index = Handle

--- Set plain content: `lines` + a parallel `hls` (each entry a whole-row hl name, a span list
--- `{ { c0, c1, hl, priority?, eol? }, … }`, or nil). Switches the segment to the `lines` kind.
---@param lines string[]
---@param hls? table
---@return LvimMsgAreaHandle
function Handle:set(lines, hls)
    local s = seg_get(self.name)
    s.kind = "lines"
    s.lines = lines or {}
    s.hls = hls or {}
    update_visibility()
    return self
end

--- Set a row-major GRID of neutral items `{ text, icon?, icon_hl? }`, the `selected` one highlighted.
--- `opts` = `{ columns, max_rows }`. Switches the segment to the `grid` kind.
---@param items table[]
---@param selected? integer
---@param opts? { columns?: integer, max_rows?: integer }
---@return LvimMsgAreaHandle
function Handle:set_grid(items, selected, opts)
    local s = seg_get(self.name)
    s.kind = "grid"
    s.items = items or {}
    s.selected = selected
    s.columns = (opts and opts.columns) or s.columns or 1
    s.max_rows = (opts and opts.max_rows) or s.max_rows or 12
    update_visibility()
    return self
end

--- Update ONLY the grid selection (cheap — no content rebuild) and reflow.
---@param idx integer?
---@return LvimMsgAreaHandle
function Handle:select(idx)
    local s = by_name[self.name]
    if s then
        s.selected = idx
        update_visibility()
    end
    return self
end

--- Set a lazy PROVIDER `fn(width) -> lines, hls`, re-rendered on every paint. The `provider` kind.
---@param fn fun(width: integer): string[], table?
---@return LvimMsgAreaHandle
function Handle:provider(fn)
    local s = seg_get(self.name)
    s.kind = "provider"
    s.render = fn
    update_visibility()
    return self
end

--- RESERVE `height` blank rows for an external float to overlay; returns the editor-relative rect of
--- the reserved region (flush with the screen bottom), or nil when the zone is closed. The `reserve` kind.
---@param height integer
---@return { win: integer, row: integer, col: integer, width: integer, height: integer }?
function Handle:reserve(height)
    local s = seg_get(self.name, { kind = "reserve" })
    s.kind = "reserve"
    s.height = math.max(0, height or 0)
    update_visibility()
    if not (win and api.nvim_win_is_valid(win)) then
        return nil
    end
    local h = s.height
    return { win = win, row = math.max(0, vim.o.lines - h), col = 0, width = api.nvim_win_get_width(win), height = h }
end

--- Empty the segment's content (keep it registered) and reflow.
---@return LvimMsgAreaHandle
function Handle:clear()
    local s = by_name[self.name]
    if s then
        s.lines, s.hls, s.items, s.selected, s.height, s.render = nil, nil, nil, nil, 0, nil
        update_visibility()
    end
    return self
end

--- Remove the segment from the stack entirely and reflow.
function Handle:release()
    seg_remove(self.name)
    update_visibility()
end

--- Force a re-render of the zone (e.g. after a `provider` segment's underlying data changed on an event).
---@return LvimMsgAreaHandle
function Handle:refresh()
    update_visibility()
    return self
end

--- Set the confirm callback `fn(item, idx)` fired on `<CR>` while the zone is focused on this segment.
---@param fn fun(item: table?, idx: integer?)
---@return LvimMsgAreaHandle
function Handle:on_confirm(fn)
    seg_get(self.name).on_confirm = fn
    return self
end

--- Set the move callback `fn(idx)` fired when the selection changes while the zone is focused on this grid.
---@param fn fun(idx: integer)
---@return LvimMsgAreaHandle
function Handle:on_move(fn)
    seg_get(self.name).on_move = fn
    return self
end

--- Set custom keymaps `{ [lhs] = fn(handle) }` active while the zone is focused on this segment.
---@param map table<string, fun(handle: table)>
---@return LvimMsgAreaHandle
function Handle:keys(map)
    seg_get(self.name).keys = map
    return self
end

--- Set (or clear with nil) a header row drawn above this segment's content — labels it and separates it
--- from the segments above when several owners share the zone.
---@param text string?
---@return LvimMsgAreaHandle
function Handle:title(text)
    seg_get(self.name).title = text
    update_visibility()
    return self
end

--- Focus the zone for keyboard interaction with THIS segment (navigation + confirm + custom keys).
---@return LvimMsgAreaHandle
function Handle:focus()
    M.focus(self.name)
    return self
end

--- Get-or-create the public handle for a named segment. `opts` = `{ priority, kind }` (applied on
--- create / when given). Names are unique, so a plugin re-acquires its own segment across calls.
---@param name string
---@param opts? { priority?: integer, kind?: string }
---@return LvimMsgAreaHandle
function M.segment(name, opts)
    seg_get(name, opts)
    return setmetatable({ name = name }, Handle)
end

--- Introspection: the currently registered segments as `{ [name] = kind }` (for `:checkhealth` / debug).
---@return table<string, string>
function M.segments()
    local t = {}
    for _, s in ipairs(segments) do
        t[s.name] = s.kind
    end
    return t
end

-- ─── focused interaction ────────────────────────────────────────────────────────
-- When the zone is FOCUSED, one segment is "active" and takes keyboard interaction: a grid's selection
-- moves with h/j/k/l (+ arrows), <CR> confirms (fires on_confirm), <Esc> blurs; the segment's custom `keys`
-- apply too. This is the path for a self-contained picker IN the zone — blink instead mirrors from the
-- command line and is never focused, so the two never collide.

--- The first segment that can take interaction (a non-empty grid, or any segment with custom keys), or nil.
---@return string?
local function first_interactive()
    for _, s in ipairs(segments) do
        if (s.kind == "grid" and s.items and #s.items > 0) or s.keys ~= nil then
            return s.name
        end
    end
    return nil
end

--- The active segment record, or nil.
---@return LvimMsgAreaSegment?
local function active_seg()
    return (active_name and by_name[active_name]) or nil
end

--- Move the active grid's selection by `delta` (clamped) and re-render. No-op unless it is a non-empty grid.
---@param delta integer
local function focused_move(delta)
    local s = active_seg()
    if not s or s.kind ~= "grid" or not s.items or #s.items == 0 then
        return
    end
    s.selected = math.max(1, math.min(#s.items, (s.selected or 1) + delta))
    if s.on_move then
        pcall(s.on_move, s.selected)
    end
    update_visibility()
end

--- Fire the active segment's `on_confirm(item, idx)` for the current selection.
local function focused_confirm()
    local s = active_seg()
    if not s then
        return
    end
    local item = (s.items and s.selected) and s.items[s.selected] or nil
    if s.on_confirm then
        pcall(s.on_confirm, item, s.selected)
    end
end

--- Remove the buffer keymaps installed for focused interaction, then re-establish the panel keys — a
--- custom segment key may have shadowed a panel key (e.g. `q`), and deleting it would otherwise leave
--- that key unmapped; map_keys is idempotent, so this restores the panel bindings.
local function remove_interaction()
    if buf and api.nvim_buf_is_valid(buf) then
        for _, lhs in ipairs(interaction_keys) do
            pcall(vim.keymap.del, "n", lhs, { buffer = buf })
        end
        map_keys()
    end
    interaction_keys = {}
end

--- Install the buffer keymaps for interacting with the active segment (nav, confirm, blur, custom keys).
local function install_interaction()
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    remove_interaction()
    local function map(lhs, fn)
        pcall(vim.keymap.set, "n", lhs, fn, { buffer = buf, nowait = true, silent = true })
        interaction_keys[#interaction_keys + 1] = lhs
    end
    local s = active_seg()
    -- Grid navigation is bound ONLY when the active segment is a grid; otherwise h/j/k/l (and <C-d>/<C-u>
    -- from map_keys) stay native, so a focused MESSAGE/lines zone scrolls its scrollback normally.
    if s and s.kind == "grid" then
        -- vertical step = the grid's column count (down/up move by a whole row); horizontal = ± 1 cell.
        local function vstep()
            local a = active_seg()
            return (a and a.columns) or 1
        end
        map("j", function()
            focused_move(vstep())
        end)
        map("<Down>", function()
            focused_move(vstep())
        end)
        map("k", function()
            focused_move(-vstep())
        end)
        map("<Up>", function()
            focused_move(-vstep())
        end)
        map("l", function()
            focused_move(1)
        end)
        map("<Right>", function()
            focused_move(1)
        end)
        map("h", function()
            focused_move(-1)
        end)
        map("<Left>", function()
            focused_move(-1)
        end)
        map("<CR>", focused_confirm)
    end
    map("<Esc>", function()
        M.blur()
    end)
    if s and s.keys then
        for lhs, fn in pairs(s.keys) do
            map(lhs, function()
                fn(M.segment(s.name))
            end)
        end
    end
end

--- Focus the zone for keyboard interaction with `name` (or the first interactive segment). Opens the zone
--- if needed; the hardware cursor stays hidden (the panel filetype is registered with lvim-utils.cursor).
---@param name? string
---@return boolean focused
function M.focus(name)
    update_visibility() -- ensure it is open when there is anything to show
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    active_name = name or first_interactive()
    prev_win = api.nvim_get_current_win()
    pcall(api.nvim_set_current_win, win)
    install_interaction()
    update_visibility() -- repaint with the selection highlight
    return true
end

--- Leave focused interaction: drop the interaction keymaps and return focus to the previous window (the
--- zone stays open). An `on_confirm` that opens something should call this first.
function M.blur()
    remove_interaction()
    active_name = nil
    if prev_win and api.nvim_win_is_valid(prev_win) then
        pcall(api.nvim_set_current_win, prev_win)
    end
    prev_win = nil
    update_visibility()
end

--- Initialise from the merged config. Registers `:LvimMsgArea` (toggle) and enables if configured.
---@param user_cfg table
function M.setup(user_cfg)
    cfg = user_cfg or {}
    pcall(api.nvim_create_user_command, "LvimMsgArea", function()
        M.toggle()
    end, { desc = "Toggle the lvim-utils message area" })
    if cfg.enable then
        cfg.enable = false -- enable() sets it; start from off so it routes/registers exactly once
        M.enable()
    end
    -- Turn on the opt-in source integrations (blink.cmp, …) per `cfg.integrations`.
    require("lvim-utils.msgarea.integrations").setup(cfg)
end

return M
