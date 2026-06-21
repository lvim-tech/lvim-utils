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
local status = require("lvim-utils.status")

--- Publish the completion match counter to the statusline — but ONLY when a transient action already owns
--- it (the cmdline published its mode), so this never activates the line on its own (it respects the
--- cmdline's `statusline = false`). Enriches the active status with `selected/total`.
---@param items table[]?
---@param selected integer?
local function publish_completion_count(items, selected)
    if status.get().active then
        status.set({ current = selected or 0, total = items and #items or 0 })
    end
end

local M = {}

---@class LvimMsgAreaMsg
---@field text string
---@field level integer
---@field count integer
---@field ts integer

---@type table  the live config (set by setup)
local cfg = {}
---@type LvimMsgAreaMsg[]  the scrollback ring buffer
local ring = {}
---@type integer? autocmd group
local augroup = nil
---@type integer  non-reserve line count of the last render (exported to cmdline_host)
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
---@field line_offset? integer  (set by compose) the composed-buffer row where this segment's content starts
---@field on_rect? fun(rect: table?)  (reserve kind) called with the segment's CURRENT rect on every reflow
---@field on_descend? fun(): boolean?  (reserve kind) focus the hosted float over this reserve (the finder) on a descend from above; false = declined
---@field render? fun(width: integer): string[], table?  (provider kind) lazy content
---@field on_confirm? fun(item: table?, idx: integer?)  fired on <CR> while the zone is focused (grid)
---@field on_move? fun(idx: integer)  fired when the selection moves while the zone is focused (grid)
---@field on_focus? fun()  fired when focus ENTERS this segment (e.g. to publish its statusline)
---@field on_blur? fun()  fired when focus leaves this segment (e.g. to restore the statusline it published)
---@field keys? table<string, fun(handle: table)>  custom keymaps active while this segment is focused
---@field title? string  an optional header row drawn above this segment's content (separates owners)
---@field title_hls? table  span list styling the title row per-cell (e.g. the history filter-bar badges)
---@field title_when_focused? boolean  show the title row ONLY while this segment is focused (e.g. the bar)

---@type LvimMsgAreaSegment[]  the stack, kept sorted by priority
local segments = {}
---@type table<string, LvimMsgAreaSegment>  name → segment
local by_name = {}
---@type string?  the segment receiving focused keyboard interaction (nil = passive / not focused)
local active_name = nil
---@type integer?  the window focus returns to on blur
local prev_win = nil
---@type integer?  the cursor row (0-based, panel buffer) while a lines zone is focused — the render boosts it
local active_row = nil
---@type integer?  the CursorMoved autocmd tracking `active_row` (removed on blur)
local cursor_au = nil
---@type string[]  surface-panel keymap lhs's installed for focused interaction (cleared on blur)
local interaction_keys = {}

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

-- ─── compose / sizing ─────────────────────────────────────────────────────────

--- Build the composed segment stack: the lines + a parallel `hls` (a whole-row hl name, a span list, or
--- `false`), the non-reserve line count, and the selected buffer row. NO buffer writes — consumed by the
--- ui.surface zone provider (`open_surface`), which renders lines + converts the hls.
---@return string[] lines, table hls, integer content_lines, integer? sel_row
local function compose()
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

        -- 2) a title header row above the content (only when the segment actually has content, never a reserve).
        -- `title_hls` (a span list) styles it per-cell — e.g. the history's coloured filter-bar badges; else the
        -- whole row is the plain title tint. `title_when_focused` hides it unless this segment is FOCUSED — so
        -- the messages read as clean tinted lines passively, and the filter bar appears only while browsing.
        if
            s.title
            and #seg_lines > 0
            and s.kind ~= "reserve"
            and (not s.title_when_focused or active_name == s.name)
        then
            lines[#lines + 1] = s.title_hls and s.title or (" " .. s.title)
            hls[#hls + 1] = s.title_hls or "LvimUiMsgAreaTitle"
        end

        -- 3) append, offsetting the segment's selected row into the buffer
        local base = #lines
        s.line_offset = base -- the composed-buffer row where this segment's content starts (for reserve rects)
        for i = 1, #seg_lines do
            lines[#lines + 1] = seg_lines[i]
            hls[#hls + 1] = seg_hls[i]
        end
        if sel_local then
            sel_row = base + sel_local
        end
    end
    return lines, hls, #lines - reserved_total, sel_row
end

--- Convert the composed per-line `hls` (a whole-row hl name, a span list, or `false`) to the ui.surface
--- provider hls format `{ row0, c0, end_col, hl, prio }` (end_col -1 = a full-row eol span). For the
--- surface backend (Stage B of the cmdline+surface unify), where the zone renders through a surface panel.
---@param hls table
---@return table
local function to_surface_hls(hls)
    local out = {}
    for i, g in ipairs(hls) do
        if type(g) == "string" then
            out[#out + 1] = { i - 1, 0, -1, g, 200 }
        elseif type(g) == "table" then
            for _, sp in ipairs(g) do
                out[#out + 1] = { i - 1, sp.eol and 0 or sp.c0, sp.eol and -1 or sp.c1, sp.hl, sp.priority or 200 }
            end
        end
    end
    return out
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

-- ─── surface (the zone's single rendering chassis) ─────────────────────────────
-- The zone renders through ONE ui.surface (position="cmdline"): the surface owns the window + grows
-- `cmdheight` so a global statusline stays above it; its single panel renders the composed segment stack
-- (messages + completion grid + the cmdline reserve). The cmdline float anchors at the absolute screen
-- bottom over the reserve rows. Focused interaction (M.focus) drives this same panel.
---@type table?  the backing surface handle
local surf = nil
---@type table?  its single content panel (captured via the provider's keys), for content re-renders + focus
local surf_panel = nil

--- Open the backing surface (cmdheight-bottom; one panel rendering compose()).
local function open_surface()
    local surface = require("lvim-utils.ui.surface")
    surf = surface.open({
        mode = "float",
        position = "cmdline",
        border = "none",
        header_air = false, -- no title here, so drop the header "air" row (it would cover the statusline row)
        zindex = 200, -- sit in the cmdline layer; a low-zindex editor float gets re-anchored BELOW the
        -- cmdline region during cmdline mode, which would cover the statusline row
        enter = false, -- never steal focus on open — the cmdline / editor owns it (M.focus enters explicitly)
        persistent = true, -- no auto-close keys; msgarea closes it when the stack empties
        -- The `max_height` cap applies to the MESSAGE/completion content only (so a flood of messages can't
        -- fill the screen), NOT to RESERVE rows — a hosted float (the area finder) must always get its full
        -- height. So the size fn caps content + adds reserves on top; the surface `max` is left wide open and
        -- the real ceiling is `max_cmdheight` (the room the splits leave).
        size = { height = { auto = true, max = 9999 } },
        content = {
            blocks = {
                {
                    id = "zone",
                    border = "none", -- the zone fills the cmdline region edge-to-edge (a default block is rounded)
                    provider = {
                        hide_cursor = true, -- hide the hardware cursor while the zone is the focused window
                        size = function()
                            local lines, _, content_count = compose()
                            local reserved = #lines - content_count -- host + cmdline reserve rows
                            local cap = resolve(cfg.max_height) or 10
                            return vim.o.columns, math.max(1, reserved + math.min(content_count, cap))
                        end,
                        render = function()
                            local lines, hls, cl = compose()
                            content_lines = cl -- exported for cmdline_host
                            -- Boost the cursor row of a FOCUSED lines zone (the messages) to its stronger
                            -- "Sel" tint, so the active row stands out while the hardware cursor is hidden.
                            local base = active_name and active_row and hls[active_row + 1]
                            if type(base) == "string" and base:match("^LvimUiMsg") and not base:match("Sel$") then
                                hls[active_row + 1] = base .. "Sel"
                            end
                            return lines, to_surface_hls(hls)
                        end,
                        keys = function(_, pan)
                            surf_panel = pan -- capture the panel for refresh() + focused interaction
                        end,
                    },
                },
            },
        },
    })
end

--- Close the backing surface.
local function close_surface()
    if surf and surf.close then
        pcall(surf.close)
    end
    surf, surf_panel = nil, nil
end

--- The editor-relative rect of segment `s`'s region within the open zone, or nil when the zone is closed.
--- Positioned by the segment's place in the stack (`line_offset`, set by compose): a LOW-priority reserve
--- sits at the TOP of the zone, a HIGH-priority one at the bottom — so a hosted float (the area finder above
--- the messages, the cmdline below them) lands in the right place.
---@param s LvimMsgAreaSegment
---@return { win: integer, row: integer, col: integer, width: integer, height: integer }?
local function segment_rect(s)
    if not (surf and surf.container_win and api.nvim_win_is_valid(surf.container_win)) then
        return nil
    end
    return {
        win = surf.container_win,
        row = api.nvim_win_get_position(surf.container_win)[1] + (s.line_offset or 0), -- zone top + segment offset
        col = 0,
        width = vim.o.columns,
        height = s.height or 0,
    }
end

--- Notify every reserve segment that registered an `on_rect` of its CURRENT rect, so a hosted float (the
--- area finder) follows the zone as messages appear / clear and it reflows. Returns whether ANY hosted
--- reserve exists (the caller forces a clean flush so the repositioned float paints in one frame).
---@return boolean hosted
local function notify_reserves()
    local hosted = false
    for _, s in ipairs(segments) do
        if s.kind == "reserve" and s.on_rect then
            hosted = true
            s.on_rect(segment_rect(s))
        end
    end
    return hosted
end

--- Re-fit + repaint the surface to the current segments. The content height changes with the segments, so
--- relayout re-fits the geometry + cmdheight AND the panel re-renders its content (relayout only moves
--- windows, it does not repaint a panel).
local function refresh_surface()
    -- Coalesce the whole reflow into ONE repaint. Growing `cmdheight` (inside relayout) reflows the editor and
    -- would repaint with a hosted float still at its OLD row — before notify_reserves moves it — a visible
    -- flicker on every new message. `lazyredraw` holds the screen until everything is placed, then we flush
    -- once. pcall-guarded so an error can't leave `lazyredraw` stuck on (which would freeze the screen).
    local lz = vim.o.lazyredraw
    vim.o.lazyredraw = true
    local hosted = false
    pcall(function()
        if surf and surf.relayout then
            surf.relayout()
        end
        if surf_panel and surf_panel.refresh then
            surf_panel.refresh()
        end
        hosted = notify_reserves()
    end)
    vim.o.lazyredraw = lz
    -- Flush one clean frame when nothing else will: COMMAND-LINE mode (the screen doesn't repaint between
    -- cmdline events — else completion lands a cursor-blink late) or a HOSTED float (it repositioned, and the
    -- coalesced reflow above must now paint as a single frame).
    if hosted or vim.fn.mode():sub(1, 1) == "c" then
        pcall(api.nvim__redraw, { flush = true })
    end
end

local function update_visibility()
    -- The `enable` master switch gates the AUTOMATIC open (so a segment pushed while the area is toggled
    -- off never reopens it); closing always works. The zone renders through a ui.surface (cmdheight-bottom).
    if has_content() and cfg.enable then
        if surf then
            refresh_surface()
        else
            open_surface()
        end
    elseif surf then
        close_surface()
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

-- ─── window-nav integration ─────────────────────────────────────────────────
-- The zone behaves as the window "below" the editor, but WITHOUT overriding any global window command: it
-- exposes `M.focus_content()` (descend) + the zone panel binds `<C-w>k`/`<C-k>` → blur (escape up, BUFFER-
-- local, install_interaction). A user wires their OWN "focus window down" key (`<C-w>j`, a smart-splits nav,
-- whatever) to call `focus_content()` at the bottom edge — so we never clobber a built-in binding.

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
            if surf then
                vim.schedule(update_visibility) -- reflow the surface to the new screen size
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
    close_surface()
end

--- Flip enable/disable (the command / a keymap calls this).
function M.toggle()
    if cfg.enable then
        M.disable()
    else
        M.enable()
    end
end

--- Open / reveal the zone without changing `enable` (a no-op when the stack is empty — there is nothing
--- to show; the surface zone only exists while it has content).
function M.show()
    update_visibility()
end

--- Hide the zone (the scrollback model is retained).
function M.hide()
    close_surface()
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
    update_visibility() -- opens the zone (reserve > 0 ⇒ has content) and renders
    -- The surface owns the window; the cmdline float anchors at the absolute screen bottom (relative
    -- "editor"), so it only needs the width.
    return surf and { win = surf.container_win, line = content_lines, width = vim.o.columns } or nil
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
    publish_completion_count(items, selected)
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
    publish_completion_count(s.items, selected)
end

--- Drop the intercepted completion list and reflow (hides the zone if nothing remains).
function M.clear_completion()
    local s = by_name["completion"]
    if not s or s.items == nil then
        return
    end
    s.items = nil
    update_visibility()
    publish_completion_count(nil, nil) -- reset the counter (the cmdline mode stays until it closes)
end

--- Wipe the scrollback and reflow (hides the zone if nothing else remains).
function M.clear()
    ring = {}
    refresh_messages()
    update_visibility()
end

--- Open a NAVIGATOR (Vertico/Consult-style: a filter input + a results list + an optional live preview)
--- through the bottom AREA — the Emacs-minibuffer model: a selectable list IN the message-area space (not a
--- centred float). Delegates to the picker on ui.surface with the bottom "area" layout; `opts` is the
--- picker's (items, format, preview, preview_side, on_confirm, on_cancel, prompt, title, …).
---@param opts table
function M.navigator(opts)
    local o = vim.tbl_extend("force", {}, opts or {}, { layout = "area" })
    return require("lvim-utils.picker").open(o)
end

--- True when the msgarea zone is enabled (messages / completion / cmdline route through it). An external
--- float (the area finder) checks this to decide whether to HOST itself in the zone (reserve rows above the
--- messages so they compose below it) instead of growing `cmdheight` on its own.
---@return boolean
function M.is_enabled()
    return cfg.enable == true
end

--- True when the messages segment currently holds content — so a hosted finder knows there is something
--- BELOW it to descend into (and only then focuses the zone).
---@return boolean
function M.has_messages()
    local s = by_name["messages"]
    return s ~= nil and s.lines ~= nil and #s.lines > 0
end

--- DESCEND into the zone from ABOVE (the editor): focus the TOPMOST thing in it, by priority. A hosted float
--- (a finder, whose reserve carries `on_descend`) is focused FIRST — so you land in the finder, not skip past
--- it to the messages below; otherwise the first content segment. Returns whether it took focus.
---@return boolean focused
function M.focus_content()
    for _, s in ipairs(segments) do
        if s.kind == "reserve" then
            if s.on_descend and (s.height or 0) > 0 then
                return s.on_descend() ~= false -- a hosted finder above the messages — enter IT
            end
        elseif seg_has_content(s) then
            return M.focus(s.name)
        end
    end
    return false
end

--- Focus the first content SEGMENT (skipping reserves / hosted floats) — used by a finder descending PAST
--- itself into the messages below it, where `focus_content` would just re-enter the finder.
---@return boolean focused
function M.focus_messages()
    for _, s in ipairs(segments) do
        if s.kind ~= "reserve" and seg_has_content(s) then
            return M.focus(s.name)
        end
    end
    return false
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

--- RESERVE `height` blank rows for an external float to overlay; returns the editor-relative rect of the
--- reserved region (positioned by the segment's priority). `on_rect` (optional) is called with the NEW rect
--- whenever the zone reflows (messages appear/clear, resize), so the float can follow. The `reserve` kind.
---@param height integer
---@param on_rect? fun(rect: { win: integer, row: integer, col: integer, width: integer, height: integer }?)
---@return { win: integer, row: integer, col: integer, width: integer, height: integer }?
function Handle:reserve(height, on_rect)
    local s = seg_get(self.name, { kind = "reserve" })
    s.kind = "reserve"
    s.height = math.max(0, height or 0)
    s.on_rect = on_rect or s.on_rect
    update_visibility()
    return segment_rect(s)
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

--- Configure the segment's header `title` (a row drawn above its content) and the `keys` active while it is
--- focused (lhs → fn(handle) — e.g. the history view's level filters). Set fields are merged; nil ones keep.
---@param opts { title?: string, title_hls?: table, title_when_focused?: boolean, keys?: table<string, fun(handle: LvimMsgAreaHandle)>, on_confirm?: fun(item: table?, idx: integer?), on_focus?: fun(), on_blur?: fun(), on_descend?: fun(): boolean? }
---@return LvimMsgAreaHandle
function Handle:configure(opts)
    local s = seg_get(self.name)
    if opts.on_focus ~= nil then
        s.on_focus = opts.on_focus
    end
    if opts.on_descend ~= nil then
        s.on_descend = opts.on_descend
    end
    if opts.title ~= nil then
        s.title = opts.title
    end
    if opts.title_hls ~= nil then
        s.title_hls = opts.title_hls
    end
    if opts.title_when_focused ~= nil then
        s.title_when_focused = opts.title_when_focused
    end
    if opts.keys ~= nil then
        s.keys = opts.keys
    end
    if opts.on_confirm ~= nil then
        s.on_confirm = opts.on_confirm
    end
    if opts.on_blur ~= nil then
        s.on_blur = opts.on_blur
    end
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

--- Remove the surface-panel keymaps installed for focused interaction (the surface's own panel keys stay —
--- they were set once on open, never touched here).
local function remove_interaction()
    if surf_panel and surf_panel.buf and api.nvim_buf_is_valid(surf_panel.buf) then
        for _, lhs in ipairs(interaction_keys) do
            pcall(vim.keymap.del, "n", lhs, { buffer = surf_panel.buf })
        end
    end
    interaction_keys = {}
end

--- Install the surface-panel keymaps for interacting with the active segment (nav, confirm, blur, custom).
local function install_interaction()
    if not (surf_panel and surf_panel.buf and api.nvim_buf_is_valid(surf_panel.buf)) then
        return
    end
    remove_interaction()
    local function map(lhs, fn)
        pcall(vim.keymap.set, "n", lhs, fn, { buffer = surf_panel.buf, nowait = true, silent = true })
        interaction_keys[#interaction_keys + 1] = lhs
    end
    local s = active_seg()
    -- Grid navigation is bound ONLY when the active segment is a grid; otherwise h/j/k/l stay native, so a
    -- focused MESSAGE/lines zone scrolls its scrollback normally.
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
    -- ESCAPE the zone (blur back up): `<Esc>` always, plus the configurable `ui.keys.zone_escape` (default
    -- `<C-k>` / `<C-w>k`) from ANY focused segment — so the window-up / stack-up key leaves the zone. Change
    -- them globally via `setup({ ui = { keys = { zone_escape = … } } })`.
    local ok_cfg, ucfg = pcall(require, "lvim-utils.config")
    local escape = (ok_cfg and ucfg.ui and ucfg.ui.keys and ucfg.ui.keys.zone_escape) or { "<C-k>", "<C-w>k" }
    map("<Esc>", function()
        M.blur()
    end)
    for _, lhs in ipairs(type(escape) == "table" and escape or { escape }) do
        map(lhs, function()
            M.blur()
        end)
    end
    -- `q` DISMISSES a focused LINES/MESSAGES zone's content — clear the segment (the zone shrinks back, the
    -- finder above reclaims the space) and return. A grid keeps `q` native; a segment's OWN key overrides this.
    if s and s.kind ~= "grid" then
        map("q", function()
            M.segment(s.name):clear()
            M.blur()
        end)
    end
    if s and s.keys then
        for lhs, fn in pairs(s.keys) do
            map(lhs, function()
                fn(M.segment(s.name))
            end)
        end
    end
end

--- Focus the zone for keyboard interaction with `name` (or the first interactive segment). Opens the zone
--- if needed; the hardware cursor stays hidden (the surface panel sets `hide_cursor`).
---@param name? string
---@return boolean focused
function M.focus(name)
    update_visibility() -- ensure it is open when there is anything to show
    if not (surf_panel and surf_panel.win and api.nvim_win_is_valid(surf_panel.win)) then
        return false
    end
    active_name = name or first_interactive()
    -- Capture the return window only when entering from OUTSIDE the zone — a RE-focus from within (e.g. a
    -- repeated descend key, or a content swap) must NOT clobber it with the zone's own window, else blur could
    -- never get back out to the real editor buffer above.
    local cur = api.nvim_get_current_win()
    if cur ~= surf_panel.win then
        prev_win = cur
    end
    pcall(api.nvim_set_current_win, surf_panel.win)
    install_interaction()
    update_visibility() -- repaint with the selection highlight
    -- Where to land the cursor on descend. A segment with a TITLE (the history's filter bar) lands on the
    -- TITLE row — so the BUTTONS are the first stop, then `j` moves down into the messages; otherwise the first
    -- CONTENT row (not the top of the zone, which under a hosted finder is its hidden reserve rows). The
    -- active-row boost skips the bar (it carries span hls), so only the message rows light up.
    local s = active_seg()
    local row = (s and s.line_offset or 0) + 1
    if s and s.title then
        row = math.max(1, s.line_offset)
    end
    if s and api.nvim_win_is_valid(surf_panel.win) then
        pcall(api.nvim_win_set_cursor, surf_panel.win, { math.max(1, row), 0 })
    end
    -- Track the cursor row (the render boosts it to the "Sel" tint) + repaint on every move, so the active
    -- message row follows the hidden cursor.
    active_row = math.max(0, row - 1)
    if cursor_au then
        pcall(api.nvim_del_autocmd, cursor_au)
    end
    cursor_au = api.nvim_create_autocmd("CursorMoved", {
        buffer = surf_panel.buf,
        callback = function()
            if surf_panel and surf_panel.win and api.nvim_win_is_valid(surf_panel.win) then
                active_row = api.nvim_win_get_cursor(surf_panel.win)[1] - 1
                if surf_panel.refresh then
                    surf_panel.refresh()
                end
            end
        end,
    })
    if surf_panel.refresh then
        surf_panel.refresh() -- paint the initial active-row boost
    end
    if s and s.on_focus then
        pcall(s.on_focus) -- e.g. the history publishes "Messages" to the statusline (restored on blur)
    end
    return true
end

--- Leave focused interaction: drop the interaction keymaps and return focus to the previous window (the
--- zone stays open). An `on_confirm` that opens something should call this first.
function M.blur()
    local s = active_seg() -- capture before clearing, to fire its on_blur (e.g. restore the statusline)
    remove_interaction()
    if cursor_au then
        pcall(api.nvim_del_autocmd, cursor_au)
        cursor_au = nil
    end
    active_row = nil
    active_name = nil
    if s and s.on_blur then
        pcall(s.on_blur)
    end
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
