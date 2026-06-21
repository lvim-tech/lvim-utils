-- lua/lvim-utils/notify/init.lua
-- Notification hub: intercepts vim.notify (and optionally print), routes
-- every message through a list of pluggable printers, and ships two
-- built-in printers:
--   "toast"   – one floating panel per severity level, stacked vertically
--   "history" – ring-buffer; browsable with M.history()
--
-- Works out-of-the-box after require() — no setup() call needed.

local M = {}

local api = vim.api
local colors = require("lvim-utils.colors")
local config = require("lvim-utils.config")
local hl = require("lvim-utils.highlight")
local levels = vim.log.levels
local NS = api.nvim_create_namespace("lvim_utils_notify")

-- ── level metadata ────────────────────────────────────────────────────────

-- Per-panel metadata: key → { icon_key, name, icon, hl, header_hl }
-- icon_key  – looked up in _cfg.icons and _cfg.level_names (built-in panels)
-- name      – explicit display name (overrides icon_key-based lookup when set)
-- icon      – explicit icon char (overrides _cfg.icons lookup when set)
-- hl        – highlight group for content lines
-- header_hl – highlight group for the header bar
-- Reverse map: vim.log.levels integer → icon_key string
local LEVEL_KEY = {
    [levels.TRACE] = "trace",
    [levels.DEBUG] = "debug",
    [levels.INFO] = "info",
    [levels.WARN] = "warn",
    [levels.ERROR] = "error",
}

local _panel_meta = {
    [levels.TRACE] = {
        icon_key = "trace",
        hl = "LvimNotifyDebug",
        header_hl = "LvimNotifyHeaderDebug",
        sep_hl = "LvimNotifySepDebug",
        title_hl = "LvimNotifyTitleDebug",
    },
    [levels.DEBUG] = {
        icon_key = "debug",
        hl = "LvimNotifyDebug",
        header_hl = "LvimNotifyHeaderDebug",
        sep_hl = "LvimNotifySepDebug",
        title_hl = "LvimNotifyTitleDebug",
    },
    [levels.INFO] = {
        icon_key = "info",
        hl = "LvimNotifyInfo",
        header_hl = "LvimNotifyHeaderInfo",
        sep_hl = "LvimNotifySepInfo",
        title_hl = "LvimNotifyTitleInfo",
    },
    [levels.WARN] = {
        icon_key = "warn",
        hl = "LvimNotifyWarn",
        header_hl = "LvimNotifyHeaderWarn",
        sep_hl = "LvimNotifySepWarn",
        title_hl = "LvimNotifyTitleWarn",
    },
    [levels.ERROR] = {
        icon_key = "error",
        hl = "LvimNotifyError",
        header_hl = "LvimNotifyHeaderError",
        sep_hl = "LvimNotifySepError",
        title_hl = "LvimNotifyTitleError",
    },
}

-- Bottom-to-top stacking order (ERROR closest to bottom edge)
-- Custom panels registered via M.register_panel() are prepended (shown highest).
local PANEL_ORDER = {
    levels.ERROR,
    levels.WARN,
    levels.INFO,
    levels.DEBUG,
    levels.TRACE,
}

-- ── runtime state ─────────────────────────────────────────────────────────

local _cfg = config.notify
local _history = {}
local _printers = {}

-- One panel per level: _panels[level] = { win, buf, width, height, entries }
local _panels = {}

-- Named progress channels, each rendered as its own independent floating panel.
-- Registered via M.progress_register(id, opts); updated via M.progress_update(id, lines).
-- _prog_channels[id] = { name, icon, header_hl, lines, marks, natural_w, win, buf, height }
local _prog_channels = {}
-- Insertion order: first registered = lowest in the stack (closest to bottom edge).
local _prog_order = {}

-- ── helpers ───────────────────────────────────────────────────────────────

local function dw(s)
    return vim.fn.strdisplaywidth(tostring(s or ""))
end

local function wrap(text, limit)
    if limit <= 0 then
        return { tostring(text) }
    end
    local lines = {}
    for raw in tostring(text):gmatch("[^\n]+") do
        local line = ""
        for word in raw:gmatch("%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if dw(candidate) > limit then
                if line ~= "" then
                    table.insert(lines, line)
                end
                line = word
            else
                line = candidate
            end
        end
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    return #lines > 0 and lines or { "" }
end

-- ── panel management ──────────────────────────────────────────────────────

local function _close_panel(level)
    local p = _panels[level]
    if not p then
        return
    end
    if api.nvim_win_is_valid(p.win) then
        api.nvim_win_close(p.win, true)
    end
    if api.nvim_buf_is_valid(p.buf) then
        api.nvim_buf_delete(p.buf, { force = true })
    end
    _panels[level] = nil
end

--- Reposition all open panels so they stack from bottom_margin upward.
--- Progress channels are at the bottom (in registration order); level panels stack above.
local function _restack()
    local offset = _cfg.bottom_margin or 2

    for _, id in ipairs(_prog_order) do
        local ch = _prog_channels[id]
        if ch and ch.win and api.nvim_win_is_valid(ch.win) then
            local win_row = math.max(0, vim.o.lines - offset - (ch.height or 1))
            api.nvim_win_set_config(ch.win, {
                relative = "editor",
                row = win_row,
                col = api.nvim_win_get_config(ch.win).col,
            })
            offset = offset + (ch.height or 1) + (_cfg.panel_gap or 1)
        end
    end

    for _, lvl in ipairs(PANEL_ORDER) do
        local p = _panels[lvl]
        if p and api.nvim_win_is_valid(p.win) then
            local win_row = math.max(0, vim.o.lines - offset - p.height)
            api.nvim_win_set_config(p.win, {
                relative = "editor",
                row = win_row,
                col = api.nvim_win_get_config(p.win).col,
            })
            offset = offset + p.height + (_cfg.panel_gap or 1)
        end
    end
end

local _rebuild_all -- forward declaration; defined after progress helpers

--- Rebuild one panel's buffer content at the given width. No restack.
local function _rebuild_panel(level, win_w)
    local p = _panels[level]
    if not p or #p.entries == 0 then
        return
    end

    p.width = win_w

    local cfg_icons = _cfg.icons or {}
    local cfg_names = _cfg.level_names or {}
    local meta = _panel_meta[level] or {}
    local icon_key = meta.icon_key or tostring(level)
    local pad_s = string.rep(" ", _cfg.padding or 1)
    local count = #p.entries
    local name = meta.name or cfg_names[icon_key] or icon_key
    local icon = meta.icon or cfg_icons[icon_key] or " "
    local header_hl = meta.header_hl or "LvimNotifyHeaderInfo"
    local sep_hl = meta.sep_hl or "LvimNotifySepInfo"
    if count > 1 then
        name = name .. "s"
    end

    local hdr = pad_s .. icon .. " " .. name
    local fill = win_w - dw(hdr)
    if fill > 0 then
        hdr = hdr .. string.rep(" ", fill)
    end

    local sep = string.rep(_cfg.separator or "─", win_w)

    local all_lines = { hdr }
    local row_offset = 1
    local col_marks = {}
    local sep_rows = {}

    for i, entry in ipairs(p.entries) do
        if i > 1 and _cfg.show_separator ~= false then
            table.insert(all_lines, sep)
            table.insert(sep_rows, row_offset)
            row_offset = row_offset + 1
        end
        for _, l in ipairs(entry.lines) do
            local lw = dw(l)
            table.insert(all_lines, lw < win_w and (l .. string.rep(" ", win_w - lw)) or l)
        end
        for _, m in ipairs(entry.marks) do
            table.insert(col_marks, { m[1] + row_offset, m[2], m[3], m[4] })
        end
        row_offset = row_offset + #entry.lines
    end

    local h = #all_lines
    local buf = p.buf
    local win = p.win
    local win_col = math.max(0, vim.o.columns - win_w - 1)

    api.nvim_set_option_value("modifiable", true, { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    api.nvim_set_option_value("modifiable", false, { buf = buf })

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    api.nvim_buf_set_extmark(buf, NS, 0, 0, {
        end_col = #hdr,
        hl_group = header_hl,
        hl_eol = true,
        priority = 200,
    })

    -- Tint the whole content body (every row below the header bar) one level — the
    -- separator and title marks layer their fg on top. Only when a matching Body group
    -- exists (the standard levels; custom panels keep the plain panel bg).
    local body_hl, n_body = header_hl:gsub("Header", "Body")
    if n_body > 0 then
        for r = 1, h - 1 do
            api.nvim_buf_set_extmark(buf, NS, r, 0, {
                line_hl_group = body_hl,
                priority = 100,
            })
        end
    end

    for _, r in ipairs(sep_rows) do
        api.nvim_buf_set_extmark(buf, NS, r, 0, {
            end_col = #sep,
            hl_group = sep_hl,
            hl_eol = true,
            priority = 150,
        })
    end

    for _, m in ipairs(col_marks) do
        api.nvim_buf_set_extmark(buf, NS, m[1], m[2], {
            end_col = m[3],
            hl_group = m[4],
            priority = 150,
        })
    end

    if not api.nvim_win_is_valid(win) then
        return
    end
    p.height = h
    api.nvim_win_set_config(win, {
        relative = "editor",
        width = win_w,
        height = h,
        row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
        col = win_col,
    })
end

--- Global max natural_w across every notify entry and every progress channel.
local function _global_max_w()
    local w = _cfg.min_width or 36
    for _, p in pairs(_panels) do
        for _, e in ipairs(p.entries) do
            w = math.max(w, e.natural_w or 0)
        end
    end
    for _, ch in pairs(_prog_channels) do
        w = math.max(w, ch.natural_w or 0)
    end
    return w
end

--- Close empty panel for `level` if needed, then trigger a full uniform rebuild.
local function _rebuild(level)
    local p = _panels[level]
    if p and #p.entries == 0 then
        _close_panel(level)
    end
    _rebuild_all()
end

-- ── progress channels ─────────────────────────────────────────────────────

--- Render (or close) one named progress channel at the given width. No restack.
local function _render_prog_channel(id, win_w)
    local ch = _prog_channels[id]
    if not ch then
        return
    end

    if not ch.lines or #ch.lines == 0 then
        if ch.win and api.nvim_win_is_valid(ch.win) then
            api.nvim_win_close(ch.win, true)
        end
        if ch.buf and api.nvim_buf_is_valid(ch.buf) then
            api.nvim_buf_delete(ch.buf, { force = true })
        end
        ch.win = nil
        ch.buf = nil
        ch.height = nil
        return
    end

    local pad_s = string.rep(" ", _cfg.padding or 1)
    local hdr_icon = ch.icon or (_cfg.icons or {}).progress or ""
    local hdr_name = ch.name or tostring(id)
    local hdr_hl = ch.header_hl or "LvimNotifyHeaderInfo"
    local hdr_text = pad_s .. hdr_icon .. " " .. hdr_name
    local hdr_fill = win_w - dw(hdr_text)
    if hdr_fill > 0 then
        hdr_text = hdr_text .. string.rep(" ", hdr_fill)
    end

    -- col_marks format: { row, col_start, col_end_bytes, hl_group, hl_eol? }
    local all_lines = { hdr_text }
    local col_marks = { { 0, 0, #hdr_text, hdr_hl, true } }
    local row_offset = 1

    for _, l in ipairs(ch.lines) do
        local safe = l:gsub("\n", " ")
        local lw = dw(safe)
        table.insert(all_lines, lw < win_w and (safe .. string.rep(" ", win_w - lw)) or safe)
    end
    for _, m in ipairs(ch.marks or {}) do
        table.insert(col_marks, { row_offset + m[1], m[2], m[3], m[4] })
    end

    local h = #all_lines
    local win_col = math.max(0, vim.o.columns - win_w - 1)

    if not ch.win or not api.nvim_win_is_valid(ch.win) then
        local buf = api.nvim_create_buf(false, true)
        api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
            col = win_col,
            width = win_w,
            height = h,
            border = _cfg.border or "none",
            style = "minimal",
            focusable = false,
            zindex = math.max(1, (_cfg.zindex or 200) - 10),
        })
        api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
        ch.win = win
        ch.buf = buf
    end

    local buf = ch.buf
    api.nvim_set_option_value("modifiable", true, { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    api.nvim_set_option_value("modifiable", false, { buf = buf })

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    -- Body tint (0.2) over the progress content rows, same as the toast panels; the header
    -- bar (row 0, hdr_hl at 0.3) and the col marks sit on top.
    local body_hl, n_body = hdr_hl:gsub("Header", "Body")
    if n_body > 0 then
        for r = 1, h - 1 do
            api.nvim_buf_set_extmark(buf, NS, r, 0, {
                line_hl_group = body_hl,
                priority = 100,
            })
        end
    end

    for _, m in ipairs(col_marks) do
        api.nvim_buf_set_extmark(buf, NS, m[1], m[2], {
            end_col = m[3],
            hl_group = m[4],
            hl_eol = m[5] or false,
            priority = 150,
        })
    end

    ch.height = h
    if api.nvim_win_is_valid(ch.win) then
        api.nvim_win_set_config(ch.win, {
            relative = "editor",
            width = win_w,
            height = h,
            row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - h),
            col = win_col,
        })
    end
end

--- Master rebuild: one global width for ALL panels (notify levels + progress channels).
_rebuild_all = function()
    local win_w = _global_max_w()
    for _, lvl in ipairs(PANEL_ORDER) do
        if _panels[lvl] then
            _rebuild_panel(lvl, win_w)
        end
    end
    for _, id in ipairs(_prog_order) do
        _render_prog_channel(id, win_w)
    end
    _restack()
    vim.schedule(function()
        vim.cmd("redraw!")
    end)
end

-- Reflow the notification stack on terminal/window resize: each panel's right-edge column comes
-- from `vim.o.columns` and the bottom-up stack from `vim.o.lines`, so a rebuild re-anchors them
-- all. Installed once (the module is a singleton); a no-op when nothing is on screen.
api.nvim_create_autocmd("VimResized", {
    group = api.nvim_create_augroup("LvimUtilsNotifyResize", { clear = true }),
    callback = function()
        if next(_panels) or next(_prog_channels) then
            _rebuild_all()
        end
    end,
})

-- ── toast printer ─────────────────────────────────────────────────────────

local function _show_toast(msg, level, opts)
    opts = opts or {}
    level = level or levels.INFO
    msg = tostring(msg or "")

    local meta = _panel_meta[level] or {}
    local title_hl = meta.title_hl or "LvimNotifyTitleInfo"
    local title = opts.title and tostring(opts.title) or nil
    local pad = _cfg.padding or 1
    local pad_s = string.rep(" ", pad)
    local max_w = _cfg.max_width or 60
    local min_w = _cfg.min_width or 36
    local available = max_w - pad * 2
    local msg_lines = wrap(msg, available)
    local timeout = (opts.timeout ~= nil) and opts.timeout or (_cfg.timeout or 4000)

    -- (Re)render an entry's buffer lines + marks + natural width. A `×N` badge is shown
    -- when the same toast has been collapsed more than once (see dedup below). Also
    -- (re)sets the sliding deadline so a repeat refreshes the timeout.
    local function render(entry)
        local lines, marks, ri = {}, {}, 0
        local function push(str, m)
            table.insert(lines, str)
            if m then
                table.insert(marks, { ri, m[1], m[2], m[3] })
            end
            ri = ri + 1
        end
        local badge = (entry.count and entry.count > 1) and ("  ×" .. entry.count) or ""
        if entry.title then
            push(pad_s .. entry.title .. badge, { pad, pad + dw(entry.title), title_hl })
        end
        for i, mline in ipairs(entry.msg_lines) do
            push(pad_s .. mline .. ((not entry.title and i == 1) and badge or ""))
        end
        local inner_w = 0
        for _, l in ipairs(lines) do
            inner_w = math.max(inner_w, dw(l))
        end
        entry.lines, entry.marks = lines, marks
        entry.natural_w = math.min(max_w, math.max(min_w, inner_w + pad * 2))
        entry.deadline = vim.uv.now() + timeout
    end

    -- Dedup: an identical consecutive toast (same level, title, message) bumps a counter
    -- on the existing entry instead of stacking a duplicate, and refreshes its deadline.
    local p = _panels[level]
    if _cfg.dedup ~= false and p and api.nvim_win_is_valid(p.win) then
        local last = p.entries[#p.entries]
        if last and last.title == title and last.raw == msg then
            last.count = (last.count or 1) + 1
            render(last)
            _rebuild(level)
            return
        end
    end

    local entry = { title = title, msg_lines = msg_lines, raw = msg, count = 1 }
    render(entry)

    -- Create panel for this level if needed.
    -- Initial width uses natural_w; _rebuild will widen it when more entries arrive.
    if not _panels[level] or not api.nvim_win_is_valid(_panels[level].win) then
        _panels[level] = nil
        local buf = api.nvim_create_buf(false, true)
        local win_col = math.max(0, vim.o.columns - entry.natural_w - 1)
        api.nvim_set_option_value("filetype", "lvim-utils-notify", { buf = buf })
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            row = math.max(0, vim.o.lines - (_cfg.bottom_margin or 2) - 2),
            col = win_col,
            width = entry.natural_w,
            height = 1,
            border = _cfg.border or "none",
            style = "minimal",
            focusable = false,
            zindex = _cfg.zindex or 200,
        })
        api.nvim_set_option_value("winhl", "Normal:LvimNotifyNormal", { win = win })
        _panels[level] = { win = win, buf = buf, width = entry.natural_w, height = 1, entries = {} }
    end

    table.insert(_panels[level].entries, entry)
    _rebuild(level)

    if timeout > 0 then
        -- Sliding-deadline removal: a dedup hit pushes `entry.deadline` forward, so the
        -- toast persists while it keeps repeating and clears `timeout` ms after the last.
        local function schedule_remove()
            vim.defer_fn(function()
                local pp = _panels[level]
                if not pp then
                    return
                end
                for i, e in ipairs(pp.entries) do
                    if e == entry then
                        if vim.uv.now() < (e.deadline or 0) then
                            schedule_remove()
                        else
                            table.remove(pp.entries, i)
                            _rebuild(level)
                        end
                        break
                    end
                end
            end, math.max(50, (entry.deadline or 0) - vim.uv.now()))
        end
        schedule_remove()
    end
end

-- ── history printer ────────────────────────────────────────────────────────

local function _append_history(msg, level, opts)
    table.insert(_history, {
        msg = tostring(msg or ""),
        level = level or levels.INFO,
        opts = opts or {},
        time = os.time(),
    })
    local max = _cfg.max_history or 100
    while #_history > max do
        table.remove(_history, 1)
    end
end

-- ── dispatch ───────────────────────────────────────────────────────────────

-- Routing sinks for ext_messages behaviours other than toast/history (e.g. "cmdline").
-- name → fun(text, level, opts). Registered by domain modules; NOT iterated by _dispatch,
-- so a sink fires only for messages explicitly routed to it via ext_kinds.
local _sinks = {}

local _in_dispatch = false

local function _dispatch(msg, level, opts)
    if _in_dispatch then
        return
    end
    _in_dispatch = true
    for _, p in ipairs(_printers) do
        pcall(p.fn, msg, level, opts)
    end
    _in_dispatch = false
end

-- ── public API ─────────────────────────────────────────────────────────────

function M.add_printer(name, fn)
    M.remove_printer(name)
    table.insert(_printers, { name = name, fn = fn })
end

function M.remove_printer(name)
    for i, p in ipairs(_printers) do
        if p.name == name then
            table.remove(_printers, i)
            return
        end
    end
end

function M.has_printer(name)
    for _, p in ipairs(_printers) do
        if p.name == name then
            return true
        end
    end
    return false
end

--- Register a routing sink for an ext_kinds behaviour (e.g. "cmdline"). Unlike a printer,
--- it is only called for messages whose kind maps to `name` in ext_kinds. Pass `nil` to remove.
---@param name string
---@param fn fun(text: string, level: integer, opts: table)|nil
function M.register_sink(name, fn)
    _sinks[name] = fn
end

-- Saved original `ext_kinds` values, so a temporary routing (e.g. msgarea while enabled) can be
-- restored verbatim on teardown.
---@type table<string, any>
local _saved_kinds = {}

--- Route message kinds to a behaviour at runtime (e.g. `{ echomsg = "msgarea" }`), saving whatever
--- each kind mapped to before so `unroute_kinds` can put it back. Mutates the live ext_kinds the
--- ext_messages handler reads.
---@param map table<string, string>
function M.route_kinds(map)
    _cfg.ext_kinds = _cfg.ext_kinds or {}
    for kind, behaviour in pairs(map or {}) do
        if _saved_kinds[kind] == nil then
            -- false sentinel = "was absent" (so we can delete it again, not leave it set)
            _saved_kinds[kind] = _cfg.ext_kinds[kind] == nil and false or _cfg.ext_kinds[kind]
        end
        _cfg.ext_kinds[kind] = behaviour
    end
end

--- Restore the `ext_kinds` entries for `keys` to what they were before `route_kinds`.
---@param keys string[]
function M.unroute_kinds(keys)
    _cfg.ext_kinds = _cfg.ext_kinds or {}
    for _, kind in ipairs(keys or {}) do
        local prev = _saved_kinds[kind]
        if prev ~= nil then
            _cfg.ext_kinds[kind] = (prev == false) and nil or prev
            _saved_kinds[kind] = nil
        end
    end
end

function M.notify(msg, level, opts)
    _dispatch(msg, level, opts)
end
function M.get_history()
    return vim.deepcopy(_history)
end
function M.clear()
    _history = {}
end

--- Register a named progress channel with its own floating panel and appearance.
--- Safe to call multiple times; subsequent calls update appearance only.
---@param id   string  Unique channel identifier
---@param opts table   { name?: string, icon?: string, header_hl?: string }
function M.progress_register(id, opts)
    opts = opts or {}
    if not _prog_channels[id] then
        _prog_channels[id] = {}
        table.insert(_prog_order, id)
    end
    local ch = _prog_channels[id]
    if opts.name ~= nil then
        ch.name = opts.name
    end
    if opts.icon ~= nil then
        ch.icon = opts.icon
    end
    if opts.header_hl ~= nil then
        ch.header_hl = opts.header_hl
    end
end

--- Register a custom panel with a unique key, display name, and highlight groups.
--- The panel is stacked above all built-in severity panels by default.
---@param key  any     Unique identifier (string or integer) for the panel
---@param opts table   { name: string, icon: string, hl: string, header_hl: string, order?: integer }
function M.register_panel(key, opts)
    opts = opts or {}
    _panel_meta[key] = {
        name = opts.name,
        icon = opts.icon,
        hl = opts.hl or "LvimNotifyInfo",
        header_hl = opts.header_hl or "LvimNotifyHeaderInfo",
    }
    -- Remove any existing position for this key, then insert at requested order.
    for i, k in ipairs(PANEL_ORDER) do
        if k == key then
            table.remove(PANEL_ORDER, i)
            break
        end
    end
    table.insert(PANEL_ORDER, opts.order or 1, key)
end

--- Push a message directly to a named panel (built-in or custom).
--- Accepts the same opts as vim.notify (title, timeout, …).
---@param key  any     Panel key passed to M.register_panel, or a vim.log.levels value
---@param msg  string
---@param opts table|nil
function M.push(key, msg, opts)
    _show_toast(msg, key, opts)
end

--- Update content for a named progress channel (auto-registers if unknown).
---@param id    string
---@param lines string[]
---@param marks table[]|nil  { row, col_start, col_end, hl_group } (row 0-based within lines)
function M.progress_update(id, lines, marks)
    if not _prog_channels[id] then
        _prog_channels[id] = {}
        table.insert(_prog_order, id)
    end
    local ch = _prog_channels[id]
    ch.lines = lines
    ch.marks = marks or {}
    local min_w = _cfg.min_width or 36
    local max_w = _cfg.max_width or 60
    local nw = min_w
    for _, l in ipairs(lines) do
        nw = math.max(nw, dw(l))
    end
    ch.natural_w = math.min(max_w, nw + (_cfg.padding or 1) * 2)
    _rebuild_all()
end

--- Clear content for a named progress channel and close its panel.
---@param id string
function M.progress_clear(id)
    local ch = _prog_channels[id]
    if not ch then
        return
    end
    ch.lines = nil
    ch.marks = nil
    ch.natural_w = nil
    _rebuild_all()
end

--- Clear all progress channels and close all their panels.
function M.progress_clear_all()
    for _, ch in pairs(_prog_channels) do
        ch.lines = nil
        ch.marks = nil
        ch.natural_w = nil
    end
    _rebuild_all()
end

-- ── history window ────────────────────────────────────────────────────────

local _hist_NS = api.nvim_create_namespace("lvim_utils_notify_history")

--- Build lines + highlights for the history popup. Returns them without touching any buffer.
local function _history_build(filter)
    local lines = {}
    local highlights = {} -- { line, col_start, col_end, group }
    local levels = {} -- per-line level key ("error"/"warn"/"info"/"debug")

    local function push_hl(group, col_s, col_e)
        table.insert(highlights, { line = #lines - 1, col_start = col_s, col_end = col_e, group = group })
    end

    -- Whole-line tint per level (ui.nvim-style coloured rows).
    local TINT = { error = "LvimUiMsgError", warn = "LvimUiMsgWarn", info = "LvimUiMsgInfo", debug = "LvimUiMsgDebug" }
    local function push_line_hl(group)
        table.insert(highlights, { line = #lines - 1, line_hl = group })
    end

    local function push_header(label)
        local text = "  " .. label
        table.insert(lines, text)
        push_hl("LvimUiTitle", 0, #text)
    end

    -- notifications
    for i = #_history, 1, -1 do
        local item = _history[i]
        if not filter or filter == (LEVEL_KEY[item.level] or "info") then
            local key = LEVEL_KEY[item.level] or "info"
            local cap = key:sub(1, 1):upper() .. key:sub(2)
            local icon = (_cfg.icons or {})[key] or " "
            local ts = os.date("%H:%M:%S", item.time) --[[@as string]]
            local title = item.opts and item.opts.title
            local pre = title and ("[" .. title .. "] ") or ""
            -- Icon badge at column 0 (`  icon  `), aligned directly under the title's icon box
            -- (2 spaces each side). One plain gap cell, then the timestamp, then the message.
            local badge = "  " .. icon .. "  "
            local badge_b = #badge
            local ts_s = badge_b + 1
            local msg_flat = item.msg:gsub("\n", " ")
            local line = badge .. " " .. ts .. "  " .. pre .. msg_flat
            local msg_s = ts_s + #ts + 2
            table.insert(lines, line)
            levels[#lines] = key
            push_line_hl(TINT[key] or "LvimUiMsgInfo")
            push_hl("LvimUiMsg" .. cap .. "Icon", 0, badge_b)
            push_hl("LvimUiFooterLabel", ts_s, ts_s + #ts)
            -- Message text in the level colour (same hue as the icon).
            push_hl("LvimUiMsg" .. cap .. "Text", msg_s, #line)
        end
    end

    -- Filtered to a level that has no records: one placeholder row in that level's style.
    if #lines == 0 then
        local key = filter or "info"
        local cap = key:sub(1, 1):upper() .. key:sub(2)
        local icon = (_cfg.icons or {})[key] or " "
        local badge = "  " .. icon .. "  "
        local badge_b = #badge
        local line = badge .. " No " .. cap .. " records"
        table.insert(lines, line)
        levels[#lines] = key
        push_line_hl(TINT[key] or "LvimUiMsgInfo")
        push_hl("LvimUiMsg" .. cap .. "Icon", 0, badge_b)
        push_hl("LvimUiMsg" .. cap .. "Text", badge_b + 1, #line)
    end

    return lines, highlights, levels
end

--- Write pre-built lines + highlights into buf.
local function _history_write(buf, lines, highlights)
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    api.nvim_buf_clear_namespace(buf, _hist_NS, 0, -1)
    for _, m in ipairs(highlights) do
        if m.line_hl then
            -- Whole-line tint as a real hl_group range (+hl_eol), NOT line_hl_group: a
            -- line_hl_group overrides any cell hl_group regardless of priority, which would
            -- swallow the icon badge. As a plain range it loses to the higher-priority badge.
            -- Must span to the next line's start (end_row+1) so the range covers the EOL —
            -- only then does hl_eol fill the rest of the screen line to the window edge.
            api.nvim_buf_set_extmark(buf, _hist_NS, m.line, 0, {
                end_row = m.line + 1,
                end_col = 0,
                hl_group = m.line_hl,
                hl_eol = true,
                priority = 10,
            })
        else
            api.nvim_buf_set_extmark(buf, _hist_NS, m.line, m.col_start, {
                end_col = m.col_end,
                hl_group = m.group,
                priority = 100,
            })
        end
    end
end

local _lvl_map = { i = "info", w = "warn", e = "error", d = "debug" }
local _lvl_labels = { i = "Info", w = "Warn", e = "Error", d = "Debug" }

-- ── history in the msgarea zone ─────────────────────────────────────────────
-- When the msgarea zone is enabled, `:Messages` browses the log IN it (below a hosted finder) — one
-- consistent, navigable message space — instead of the cmdline pager.

local _hist_cap = { info = "Info", warn = "Warn", error = "Error", debug = "Debug" }

--- The history as zone lines (newest first) + parallel whole-row level tints (which take the focused zone's
--- active-row "Sel" boost). `filter` keeps one level, or nil for all.
---@param filter string?
---@return string[] lines, string[] hls
local function _history_zone_lines(filter)
    local lines, hls = {}, {}
    for i = #_history, 1, -1 do
        local item = _history[i]
        local key = LEVEL_KEY[item.level] or "info"
        if not filter or filter == key then
            local icon = (_cfg.icons or {})[key]
            local ts = os.date("%H:%M:%S", item.time) --[[@as string]]
            local title = item.opts and item.opts.title
            local pre = title and ("[" .. title .. "] ") or ""
            local body = (icon and icon ~= "" and (icon .. "  ") or "") .. ts .. "  " .. pre .. item.msg:gsub("\n", " ")
            lines[#lines + 1] = "  " .. body
            hls[#hls + 1] = "LvimUiMsg" .. (_hist_cap[key] or "Info")
        end
    end
    if #lines == 0 then
        lines, hls = { "  No " .. (_hist_cap[filter] or "") .. " records" }, { "LvimUiMsgInfo" }
    end
    return lines, hls
end

-- The history filter bar as the segment's TITLE row: a coloured badge + label per button — All / per-level
-- (in its level colour, ACTIVE one bold via the "Sel" tint) / Refresh / close — over the zone bg.
---@param filter string?  the active level filter (nil = All)
---@return string text, table spans
local function _history_bar(filter)
    local btns = {
        { k = "a", l = "All", lvl = nil, filt = true },
        { k = "e", l = "Error", lvl = "error", filt = true },
        { k = "w", l = "Warn", lvl = "warn", filt = true },
        { k = "i", l = "Info", lvl = "info", filt = true },
        { k = "d", l = "Debug", lvl = "debug", filt = true },
        { k = "r", l = "Refresh", lvl = nil, filt = false },
        { k = "q", l = "close", lvl = nil, filt = false },
    }
    local text = " "
    local spans = { { eol = true, hl = "LvimUiMsgAreaNormal", priority = 1 } } -- the row's own bg
    for _, b in ipairs(btns) do
        local active = b.filt and (b.lvl == filter)
        local badge_hl, label_hl
        if b.lvl then -- a level: coloured badge + label (bold "Sel" when it is the active filter)
            local cap = _hist_cap[b.lvl]
            badge_hl = "LvimUiMsg" .. cap .. "Icon"
            label_hl = "LvimUiMsg" .. cap .. (active and "Sel" or "Text")
        elseif b.filt then -- All: bright when active, dim otherwise
            badge_hl = active and "LvimUiMsgAreaTitle" or "LvimUiMsgAreaItemSource"
            label_hl = badge_hl
        else -- Refresh / close (actions, not filters)
            badge_hl, label_hl = "LvimUiMsgAreaItem", "LvimUiMsgAreaItem"
        end
        local p0 = #text
        text = text .. " " .. b.k .. " " -- the key badge
        spans[#spans + 1] = { c0 = p0, c1 = #text, hl = badge_hl, priority = 120 }
        local p1 = #text
        text = text .. b.l .. " " -- the label
        spans[#spans + 1] = { c0 = p1, c1 = #text, hl = label_hl, priority = 110 }
        text = text .. "  " -- gap between buttons
    end
    return text, spans
end

--- Render the log into the zone's "history" segment (priority 10 — below a hosted finder) + focus it: `j`/`k`
--- scroll with the active row lit, the level keys filter (a styled bar shows which is active), `r` refreshes,
--- `q` dismisses (the generic zone key). The inline recent-messages scrollback is cleared (history wins).
---@param ma table  the lvim-utils.msgarea module
local function _history_in_zone(ma)
    local filter = nil
    local seg = ma.segment("history", { priority = 10 })
    local function render()
        local bar, bar_hls = _history_bar(filter) -- the filter bar (title row), re-styled for the active level
        seg:configure({ title = bar, title_hls = bar_hls })
        seg:set(_history_zone_lines(filter))
    end
    seg:configure({
        keys = {
            a = function()
                filter = nil
                render()
            end,
            e = function()
                filter = "error"
                render()
            end,
            w = function()
                filter = "warn"
                render()
            end,
            i = function()
                filter = "info"
                render()
            end,
            d = function()
                filter = "debug"
                render()
            end,
            r = render,
        },
    })
    ma.clear() -- wipe the inline recent-messages scrollback (the history below supersedes it; the log persists)
    render()
    seg:focus()
end

function M.history()
    if #_history == 0 then
        M.push(vim.log.levels.INFO, "No notifications")
        return
    end
    -- The msgarea zone (when on) is the one message space — browse the log there, below a hosted finder.
    local ok_ma, ma = pcall(require, "lvim-utils.msgarea")
    if ok_ma and ma.is_enabled and ma.is_enabled() then
        _history_in_zone(ma)
        return
    end

    local filter = nil
    local buf_ref ---@type integer

    local current_levels = {}
    local function rerender()
        if buf_ref and api.nvim_buf_is_valid(buf_ref) then
            local lines, hls, levels = _history_build(filter)
            _history_write(buf_ref, lines, hls)
            current_levels = levels or {}
        end
    end

    -- Per-level colour groups for the pager buttons (key badge + label), matching the
    -- toast/history level colours.
    local _lvl_cap = { info = "Info", warn = "Warn", error = "Error", debug = "Debug" }
    local keymaps = {
        a = {
            fn = function()
                filter = nil
                rerender()
            end,
            label = "All",
        },
        r = { fn = rerender, label = "Refresh" },
    }
    for key, lvl in pairs(_lvl_map) do
        local cap = _lvl_cap[lvl] or "Info"
        keymaps[key] = {
            fn = function()
                filter = filter == lvl and nil or lvl
                rerender()
            end,
            label = _lvl_labels[key],
            badge = "LvimUiMsg" .. cap .. "Icon",
            label_hl = "LvimUiMsg" .. cap .. "Text",
        }
    end

    local cmd = require("lvim-utils.cmdline")
    cmd.pager({
        title = " History ",
        keymaps = keymaps,
        order = { "a", "e", "w", "i", "d", "r" },
        level_at = function(row)
            return current_levels[row + 1]
        end,
        on_open = function(b)
            buf_ref = b
            rerender()
        end,
    })
end

-- ── ext_messages (vim.ui_attach) ──────────────────────────────────────────

-- Map message kind → vim.log.levels
local _KIND_LEVEL = {
    emsg = levels.ERROR,
    echoerr = levels.ERROR,
    lua_error = levels.ERROR,
    rpc_error = levels.ERROR,
    shell_err = levels.ERROR,
    wmsg = levels.WARN,
    echomsg = levels.INFO,
    echo = levels.INFO,
    [""] = levels.INFO,
    bufwrite = levels.INFO,
    undo = levels.INFO,
    shell_out = levels.DEBUG,
    lua_print = levels.DEBUG,
    verbose = levels.DEBUG,
}

--- Convert content fragments [{attr_id, text}, …] to a plain string.
local function _fragments_to_text(content)
    local parts = {}
    for _, frag in ipairs(content) do
        table.insert(parts, frag[2] or "")
    end
    return vim.trim(table.concat(parts))
end

local _in_ext = false
local _ui_attached = false
local _dedup_last = {} -- [text] = uv_hrtime of last dispatch
local _DEDUP_WINDOW = 500 -- ms — same text within this window is dropped

local function _dedup_check(text)
    local now = vim.uv.hrtime() / 1e6 -- ms
    local last = _dedup_last[text]
    if last and (now - last) < _DEDUP_WINDOW then
        return true
    end
    _dedup_last[text] = now
    -- keep table small
    if vim.tbl_count(_dedup_last) > 50 then
        local oldest, oldest_key = math.huge, nil
        for k, t in pairs(_dedup_last) do
            if t < oldest then
                oldest, oldest_key = t, k
            end
        end
        if oldest_key then
            _dedup_last[oldest_key] = nil
        end
    end
    return false
end

local function _attach_ui()
    if _ui_attached then
        return
    end
    _ui_attached = true

    local ns = api.nvim_create_namespace("lvim_utils_ext_messages")

    vim.ui_attach(ns, { ext_messages = true }, function(event, ...)
        if event == "msg_show" then
            local kind, content, _replace = ...

            -- capture args before scheduling (varargs don't survive yield)
            local text_raw = _fragments_to_text(content)

            if kind == "return_prompt" then
                vim.schedule(function()
                    api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
                end)
                return
            end

            local behaviour = (_cfg.ext_kinds or {})[kind] or "history"
            if behaviour == "ignore" then
                return
            end

            vim.schedule(function()
                if _in_ext or _in_dispatch then
                    return
                end
                _in_ext = true
                local ok, err = pcall(function()
                    local text = vim.trim(text_raw)
                    if text == "" then
                        return
                    end
                    if _dedup_check(text) then
                        return
                    end

                    local lvl = _KIND_LEVEL[kind] or levels.INFO
                    local timeout = (lvl == levels.INFO or lvl == levels.DEBUG) and (_cfg.ext_echo_timeout or 3000)
                        or (_cfg.timeout or 5000)

                    _append_history(text, lvl, {})

                    if behaviour == "toast" then
                        _show_toast(text, lvl, { timeout = timeout })
                    elseif _sinks[behaviour] then
                        _sinks[behaviour](text, lvl, { timeout = timeout })
                    end
                end)
                _in_ext = false
                if not ok then
                    io.stderr:write("[lvim-utils.notify] ext handler error: " .. tostring(err) .. "\n")
                end
            end)
        end
    end)
end

local _initialized = false

--- Per-level highlight groups for the history pager rows. Single source of truth
--- (the cmdline module merges these too). Owned here so the history has its colours
--- even when the cmdline module is disabled.
---   LvimUiMsg<L>       row background       — light tint (0.1)
---   LvimUiMsg<L>Text   message label        — level fg on light tint
---   LvimUiMsg<L>Icon   left icon badge      — level fg on a stronger background tint (0.3)
---   LvimUiMsg<L>Active focused row          — same 0.3 background, so it merges with the icon
---@return table<string, table>
function M.msg_highlights()
    local c = colors
    local b, bg = c.blend, c.bg
    local g = {}
    local msg = { Error = c.red, Warn = c.orange, Info = c.blue, Debug = c.purple }
    for name, col in pairs(msg) do
        g["LvimUiMsg" .. name] = { fg = col, bg = b(col, bg, 0.1) }
        g["LvimUiMsg" .. name .. "Text"] = { fg = col, bg = b(col, bg, 0.1) }
        g["LvimUiMsg" .. name .. "Icon"] = { fg = col, bg = b(col, bg, 0.2), bold = true }
        g["LvimUiMsg" .. name .. "Active"] = { bg = b(col, bg, 0.2) }
        -- The ACTIVE (cursor) message row when the zone is focused: same hue, STRONGER tint (fg + a 0.4 blend
        -- + bold — the help-window active-row canon), so the focused row stands out while the cursor is hidden.
        g["LvimUiMsg" .. name .. "Sel"] = { fg = col, bg = b(col, bg, 0.4), bold = true }
    end
    return g
end

-- Self-theme the history-pager groups at module load (not just in setup) so they exist
-- after a plain require(); bind() applies them with `default = true` and re-applies on
-- palette change and on ColorScheme.
pcall(function()
    hl.bind(M.msg_highlights)
end)

function M.setup(user_cfg)
    user_cfg = user_cfg or {}
    _cfg = vim.tbl_deep_extend("force", _cfg, user_cfg)

    -- LvimNotify* groups are self-themed centrally via highlight.bind (config factory),
    -- so notify no longer re-registers them here.

    -- Build printer list: explicit printers list replaces defaults;
    -- otherwise ensure toast + history are present on first call.
    if user_cfg.printers then
        _printers = {}
        for _, p in ipairs(user_cfg.printers) do
            if p == "toast" then
                M.add_printer("toast", _show_toast)
            elseif p == "history" then
                M.add_printer("history", _append_history)
            elseif type(p) == "function" then
                M.add_printer(tostring(p), p)
            elseif type(p) == "table" and p.fn then
                M.add_printer(p.name or tostring(p), p.fn)
            end
        end
        if not M.has_printer("history") then
            M.add_printer("history", _append_history)
        end
    elseif not _initialized then
        M.add_printer("toast", _show_toast)
        M.add_printer("history", _append_history)
    end

    -- Intercept vim.notify on first setup.
    if not _initialized then
        vim.notify = function(msg, level, opts)
            _dispatch(msg, level, opts)
        end ---@diagnostic disable-line: duplicate-set-field
    end

    if _cfg.override_print then
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                table.insert(parts, tostring(select(i, ...)))
            end
            _dispatch(table.concat(parts, "\t"), levels.DEBUG, { title = "print" })
        end
    end

    if _cfg.ext_messages then
        _attach_ui()
    end

    _initialized = true
end

return M
