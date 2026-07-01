-- lua/lvim-utils/dashboard/init.lua
-- The START DASHBOARD — a declarative, section-based greeter buffer (the snacks.nvim dashboard model,
-- reimplemented on the lvim-utils stack). The render engine lives in dashboard.render; the built-in sections
-- in dashboard.sections; this file owns the public API + the INSTANCE LIFECYCLE:
--   • open()   — make the scratch buffer + window, strip its chrome, render, wire keys + the cursor snap;
--   • update() — re-resolve + re-paint on resize;
--   • close()  — a SINGLE, idempotent teardown (one augroup, deleted ONCE, guarded by `closed`). This is the
--                clean fix for snacks' double-delete-augroup crash: there is no global monkey-patch — the
--                buffer-wipe autocmd just calls close(), which no-ops if already closed.
--   • auto-open on an empty startup (no file args), and `:LvimDashboard [open|pick <finder>]`.
-- Actions that open a finder go through lvim-utils.picker (no fzf-lua/telescope dependency). No snacks code.
--
---@module "lvim-utils.dashboard"

local api = vim.api
local render = require("lvim-utils.dashboard.render")

local M = {}

local NS = api.nvim_create_namespace("lvim-utils-dashboard")
local CURSOR_NS = api.nvim_create_namespace("lvim-utils-dashboard-cursor")

---@type table?  the currently-open dashboard instance (a re-open replaces it)
local _current = nil

-- ─── the instance ─────────────────────────────────────────────────────────────

---@class LvimDashboard
---@field opts table  the live config snapshot
---@field buf integer  the dashboard scratch buffer
---@field win integer?  the window showing it
---@field ns integer  the extmark namespace
---@field augroup integer?  the single lifecycle autocmd group
---@field closed boolean  teardown guard
---@field items table[]  the resolved flat item list
---@field panes table[][]  items grouped into side-by-side panes
---@field lines string[]  the painted buffer lines
---@field row integer  the top centring offset
---@field _size? { width: integer, height: integer }
---@field _cur_pane? integer  the pane the cursor is currently in (h/l switch it)
---@field _cur_idx? integer  index of the current item in its pane's actionable list (j/k step it)
---@field _acting? boolean  freeze re-paints while a finder launched from the menu owns the screen
local D = {}
D.__index = D

--- Read the live config (merged in place by setup()).
---@return table
local function cfg()
    return require("lvim-utils.config").dashboard or {}
end

--- Run an item ACTION: a `:Cmd` string, a raw-keys string, or a `fun(self)`. Closes the dashboard first.
---@param action string|fun(self: LvimDashboard)
function D:action(action)
    -- the action usually replaces the dashboard (opens a file / a finder); close ours first
    if self.win and api.nvim_win_is_valid(self.win) and self:is_float() then
        pcall(api.nvim_win_close, self.win, true)
        self.win = nil
    end
    -- FREEZE re-paints from here until focus returns (WinEnter). A finder opening below churns the layout
    -- (resizes, window re-stacks) while it owns the screen; re-painting then would re-centre / one-column the
    -- dashboard against that transient geometry. The flag is the reliable signal (focus timing is not).
    self._acting = true
    if type(action) == "string" then
        if action:sub(1, 1) == ":" then
            vim.cmd(action:sub(2))
        else
            api.nvim_feedkeys(api.nvim_replace_termcodes(action, true, true, true), "m", false)
        end
    elseif type(action) == "function" then
        action(self)
    end
    -- if the action did NOT open anything (dashboard still focused AND full height), there is nothing to wait
    -- for — unfreeze. If a finder opened (focus moved OR our window shrank), stay frozen until it closes.
    vim.schedule(function()
        if
            not self.closed
            and self.win
            and api.nvim_win_is_valid(self.win)
            and api.nvim_get_current_win() == self.win
            and not self:window_shrunk()
        then
            self._acting = false
        end
    end)
end

--- True when our window is shorter than its last painted height — i.e. a finder / the area opened below and
--- took rows. While this holds we stay FROZEN (no re-paint): re-centring against the shrunk height would jump
--- the content up, and re-laying-out against the finder's transient width would collapse the panes to one
--- column. We re-paint only once the window is back to full height (the finder closed).
---@return boolean
function D:window_shrunk()
    return self.win ~= nil
        and api.nvim_win_is_valid(self.win)
        and self._size ~= nil
        and api.nvim_win_get_height(self.win) < self._size.height
end

--- The dashboard auto-opens early — before the lazy nvim-web-devicons has initialised — so file rows first
--- paint with the generic fallback glyph. Poll briefly and re-paint ONCE devicons is ready, upgrading them to
--- per-file-type icons. Stops on the first success, after ~1s, or when the dashboard closes / a finder opens.
function D:upgrade_icons()
    local function ready()
        local ok, dev = pcall(require, "nvim-web-devicons")
        return ok and dev.get_icon("init.lua", "lua", { default = false }) ~= nil
    end
    if ready() then
        return
    end
    local timer = (vim.uv or vim.loop).new_timer()
    local tries = 0
    local done = false -- the REPEATING timer + `vim.schedule_wrap` can queue several ticks before one closes
    -- the handle; `done` makes the stop+close run exactly once so a later queued tick can't double-close it.
    timer:start(
        100,
        100,
        vim.schedule_wrap(function()
            if done then
                return
            end
            tries = tries + 1
            if self.closed or ready() or tries >= 10 then
                done = true
                timer:stop()
                timer:close()
                if not self.closed and not self._acting and ready() then
                    self:update()
                end
            end
        end)
    )
end

--- True when the dashboard is a floating window (vs the editor window).
---@return boolean
function D:is_float()
    return self.win ~= nil and api.nvim_win_is_valid(self.win) and api.nvim_win_get_config(self.win).relative ~= ""
end

--- Assign an auto-key (from `autokeys`, skipping the nav keys + taken keys) to every `autokey` item — BEFORE
--- the paint, so each row can show its shortcut.
function D:assign_keys()
    local used = {}
    for _, it in ipairs(self.items) do
        if it.key then
            used[it.key] = true
        end
    end
    local pool = {}
    for ch in (self.opts.autokeys or ""):gmatch(".") do
        if not used[ch] and not ("hjklq"):find(ch, 1, true) then
            pool[#pool + 1] = ch
        end
    end
    local n = 0
    for _, it in ipairs(self.items) do
        if it.autokey and not it.key then
            n = n + 1
            it.key = pool[n]
        end
    end
end

--- Install the buffer keymaps: each item's `key` → its action, plus `<CR>` on the item under the cursor and
--- `q` to close.
function D:map_keys()
    for _, it in ipairs(self.items) do
        if it.key and it.action then
            local act = it.action
            vim.keymap.set("n", it.key, function()
                self:action(act)
            end, {
                buffer = self.buf,
                nowait = true,
                silent = true,
                desc = "Dashboard: " .. (it.desc or it.key),
            })
        end
    end
    vim.keymap.set("n", "<CR>", function()
        local it = self:actionables(self._cur_pane or 1)[self._cur_idx or 1]
        if it and it.action then
            return self:action(it.action)
        end
    end, { buffer = self.buf, nowait = true, silent = true })
    -- j/k (and ↓/↑) step between the CLICKABLE rows of the current pane — skipping every blank / banner /
    -- title / meta line; h/l (and ←/→) move between the side-by-side panes. All land only on real items.
    for _, lhs in ipairs({ "j", "<Down>" }) do
        vim.keymap.set("n", lhs, function()
            self:nav(1)
        end, { buffer = self.buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "k", "<Up>" }) do
        vim.keymap.set("n", lhs, function()
            self:nav(-1)
        end, { buffer = self.buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "l", "<Right>" }) do
        vim.keymap.set("n", lhs, function()
            self:switch_pane(1)
        end, { buffer = self.buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "h", "<Left>" }) do
        vim.keymap.set("n", lhs, function()
            self:switch_pane(-1)
        end, { buffer = self.buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "q", function()
        self:close()
        if self.buf and api.nvim_buf_is_valid(self.buf) then
            pcall(api.nvim_buf_delete, self.buf, { force = true })
        end
    end, { buffer = self.buf, nowait = true, silent = true })
end

--- The actionable items (have an `action` + an on-screen row), sorted top to bottom — optionally restricted
--- to one pane.
---@param pane? integer  only items in this pane (nil = all panes)
---@return table[]
function D:actionables(pane)
    local list = {}
    for _, it in ipairs(self.items) do
        if it.action and it._row and not it.hidden and (not pane or it._pane == pane) then
            list[#list + 1] = it
        end
    end
    table.sort(list, function(a, b)
        return a._row < b._row
    end)
    return list
end

--- The index, in `pane`'s actionable list, of the item nearest buffer row `row`.
---@param pane integer
---@param row integer  0-based buffer row
---@return integer index, table[] acts
function D:nearest(pane, row)
    local acts = self:actionables(pane)
    local bi, best = 1, math.huge
    for i, it in ipairs(acts) do
        local d = math.abs(it._row - row)
        if d < best then
            best, bi = d, i
        end
    end
    return bi, acts
end

--- Tint the active item's row CELL (its pane-width byte span) so the selected row stands out. Cleared and
--- redrawn on every move; scoped to its own namespace so it never disturbs the content highlights.
---@param it table?  the active item (carries `_row` + `_hl` byte range from the render)
function D:highlight_item(it)
    if not (self.buf and api.nvim_buf_is_valid(self.buf)) then
        return
    end
    api.nvim_buf_clear_namespace(self.buf, CURSOR_NS, 0, -1)
    if it and it._row and it._hl then
        pcall(api.nvim_buf_set_extmark, self.buf, CURSOR_NS, it._row, it._hl[1], {
            end_col = it._hl[2],
            hl_group = self.opts.hl.cursorline or "LvimUiDashboardCursorLine",
        })
    end
end

--- Move the cursor onto actionable #idx of `pane` (clamped) and record it as the current item. The cursor
--- only ever lands on a real, clickable item this way — never a blank / banner / title / meta row.
---@param pane integer
---@param idx integer
function D:goto_item(pane, idx)
    local acts = self:actionables(pane)
    if #acts == 0 then
        return
    end
    idx = math.max(1, math.min(#acts, idx))
    self._cur_pane, self._cur_idx = pane, idx
    self:highlight_item(acts[idx])
    -- the selection is shown by the TINTED row, not the real cursor — so PIN the cursor to the top. A cursor
    -- sitting on a low row would make Neovim scroll the view to keep it visible when the window shrinks (the
    -- area opening below), jumping the whole dashboard up. Pinned at the top, the view never scrolls.
    pcall(api.nvim_win_set_cursor, self.win, { 1, 0 })
end

--- Step to the next (+1) / previous (-1) actionable item WITHIN the current pane (clamped at the ends).
---@param delta integer
function D:nav(delta)
    self:goto_item(self._cur_pane or 1, (self._cur_idx or 1) + delta)
end

--- Move to the ADJACENT pane (dir = +1 right / -1 left), onto its actionable nearest the current row. No-op
--- with a single pane or when the target pane has no actionable items.
---@param dir integer
function D:switch_pane(dir)
    if not (self.win and api.nvim_win_is_valid(self.win)) or #(self.panes or {}) < 2 then
        return
    end
    local to = math.max(1, math.min(#self.panes, (self._cur_pane or 1) + dir))
    if to == (self._cur_pane or 1) or #self:actionables(to) == 0 then
        return
    end
    -- align to the row of the CURRENT selection (not the cursor, which is pinned to the top)
    local cur = self:actionables(self._cur_pane or 1)[self._cur_idx or 1]
    self:goto_item(to, self:nearest(to, cur and cur._row or 0))
end

--- Select an actionable item: RESTORE the saved selection (after a re-paint), else the first actionable in
--- the first pane that has one (the initial selection).
---@param restore? boolean
function D:select(restore)
    if not (self.win and api.nvim_win_is_valid(self.win)) then
        return
    end
    if restore and self._cur_pane and self._cur_idx and #self:actionables(self._cur_pane) > 0 then
        self:goto_item(self._cur_pane, self._cur_idx)
        return
    end
    for p = 1, #(self.panes or {}) do
        if #self:actionables(p) > 0 then
            self:goto_item(p, 1)
            return
        end
    end
end

--- Re-resolve, assign keys, paint, and (re)wire the keymaps + cursor. Called on open, on resize, and when the
--- window is re-entered (e.g. returning after an action opened a finder in the area).
function D:update()
    if self.closed or not (self.buf and api.nvim_buf_is_valid(self.buf)) then
        return
    end
    self.opts = cfg()
    self.items = render.resolve(self, self.opts.sections)
    self:assign_keys()
    render.paint(self)
    self:map_keys()
    -- keep the logical selection (pane + item index) across re-paints — restore by INDEX, not by the (now
    -- shifted) cursor row; the first paint, with no selection yet, lands on the first item.
    self:select(true)
end

--- The window size (width × height), accounting for the statusline row.
---@return { width: integer, height: integer }
function D:size()
    return {
        width = api.nvim_win_get_width(self.win),
        height = api.nvim_win_get_height(self.win),
    }
end

--- The SINGLE teardown: delete the autocmd group ONCE. Idempotent — safe to call from BufWipeout, WinClosed
--- and `q` without the double-free that bit the snacks dashboard.
function D:close()
    if self.closed then
        return
    end
    self.closed = true
    if self.augroup then
        pcall(api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
    end
    if self.buf then -- stop hiding the cursor for this (now gone) buffer
        local ok, cur = pcall(require, "lvim-utils.cursor")
        if ok then
            pcall(cur.mark_hide_buffer, self.buf, nil)
        end
    end
    -- restore the global chrome we hid on auto-open, and the window's original options + winhighlight (a file
    -- may now occupy self.win — without this it inherits the dashboard's chrome-less, number-less look).
    if self._chrome then
        vim.o.showtabline, vim.o.laststatus = self._chrome.showtabline, self._chrome.laststatus
        self._chrome = nil
    end
    if self.win and api.nvim_win_is_valid(self.win) then
        for k, v in pairs(self._saved_wo or {}) do
            pcall(api.nvim_set_option_value, k, v, { win = self.win })
        end
        pcall(function()
            vim.wo[self.win].winhighlight = self._saved_winhl or ""
        end)
    end
    if _current == self then
        _current = nil
    end
end

--- Apply the configured buffer + window options (a clean, chrome-free scratch). The window's ORIGINAL values
--- are saved so D:close can restore them — otherwise a file opened IN the dashboard window inherits the
--- dashboard's chrome-less options (no number column, dashboard winhighlight, …).
function D:set_options()
    for k, v in pairs(self.opts.bo or {}) do
        pcall(api.nvim_set_option_value, k, v, { buf = self.buf })
    end
    if self.win and api.nvim_win_is_valid(self.win) then
        self._saved_wo = {}
        for k, v in pairs(self.opts.wo or {}) do
            local ok, cur = pcall(api.nvim_get_option_value, k, { win = self.win })
            self._saved_wo[k] = ok and cur or nil
            pcall(api.nvim_set_option_value, k, v, { win = self.win })
        end
        self._saved_winhl = vim.wo[self.win].winhighlight
        vim.wo[self.win].winhighlight = "Normal:" .. (self.opts.hl.normal or "LvimUiDashboardNormal")
    end
end

--- Register the lifecycle autocmds (one augroup). The guiding rule: the dashboard does NOT re-paint while a
--- finder it launched owns the screen (the `_acting` freeze, set by D:action) — that finder churns the layout
--- (resizes, window re-stacks, the area growing), and re-painting against that transient geometry is what
--- re-stacked the panes to one column / re-centred it. A single clean re-paint happens when focus RETURNS.
function D:init()
    self.augroup = api.nvim_create_augroup("LvimUtilsDashboard_" .. self.buf, { clear = true })
    api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = self.augroup,
        callback = function()
            vim.schedule(function()
                if self.closed or not (self.win and api.nvim_win_is_valid(self.win)) then
                    return
                end
                if self._acting then
                    -- frozen while a finder is up: unfreeze + re-paint only once the window is back to full
                    -- height (the finder/area closed); otherwise leave the dashboard exactly as it is.
                    if self:window_shrunk() then
                        return
                    end
                    self._acting = false
                elseif api.nvim_get_current_win() ~= self.win then
                    return -- another window owns the screen — don't react to its resizes
                end
                local s = self:size()
                local changed = not self._size or s.width ~= self._size.width or s.height ~= self._size.height
                self._size = s
                if changed then
                    self:update()
                end
            end)
        end,
    })
    -- ONE teardown path: the buffer is `bufhidden=wipe`, so closing the window wipes it → BufWipeout → close().
    api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = self.augroup,
        buffer = self.buf,
        callback = function()
            self:close()
        end,
    })
    -- Focus RETURNS to the dashboard (a finder closed): re-acquire the window handle and re-paint ONCE against
    -- the now-stable geometry — fixing any pane re-stack the finder caused. The cursor is pinned to the top, so
    -- this never scrolls/jumps; the selection (by index) is restored by update().
    api.nvim_create_autocmd("WinEnter", {
        group = self.augroup,
        callback = function()
            if not self.closed and api.nvim_get_current_buf() == self.buf then
                local w = api.nvim_get_current_win()
                if w ~= self.win then
                    self.win = w
                end
                -- Focus returned to the dashboard. If a finder is STILL open (e.g. parked out of its input with
                -- the area still up — our window is short), stay FROZEN so it keeps its columns and position.
                -- Re-paint only once the window is back to full height (the finder fully closed).
                if self._acting and self:window_shrunk() then
                    return
                end
                self._acting = false
                self._size = self:size()
                self:update()
            end
        end,
    })
end

-- ─── public api ───────────────────────────────────────────────────────────────

--- Open the dashboard. `opts.buf` / `opts.win` reuse an existing buffer/window (the auto-open uses the empty
--- start buffer); otherwise a fresh scratch buffer is shown in the current window.
---@param opts? { buf?: integer, win?: integer }
---@return LvimDashboard
function M.open(opts)
    opts = opts or {}
    if _current and not _current.closed then
        pcall(function()
            _current:close()
        end)
    end
    local self = setmetatable({}, D)
    self.opts = cfg()
    self.ns = NS
    self.buf = (opts.buf and api.nvim_buf_is_valid(opts.buf)) and opts.buf or api.nvim_create_buf(false, true)
    self.win = (opts.win and api.nvim_win_is_valid(opts.win)) and opts.win or api.nvim_get_current_win()
    self.closed = false
    api.nvim_win_set_buf(self.win, self.buf)
    self:set_options()
    self:init()
    -- hide the hardware cursor while the greeter is up (the active row is shown by its tinted cell) — via the
    -- canonical lvim-utils.cursor module, by buffer handle (no filetype registration needed).
    if self.opts.hide_cursor then
        local ok, cur = pcall(require, "lvim-utils.cursor")
        if ok then
            pcall(cur.mark_hide_buffer, self.buf, true)
        end
    end
    self._size = self:size()
    self:update()
    self:upgrade_icons() -- re-paint with per-type devicons once the lazy plugin is ready
    _current = self
    return self
end

--- Open a finder for `source` ("files" / "grep" / "oldfiles" / …) — via `config.dashboard.preset.pick` when
--- set, else lvim-utils.picker. `extra` is appended cwd/args (from `:LvimDashboard pick <source> [cwd]`).
---@param source? string
---@param extra? string
function M.pick(source, extra)
    source = source or "files"
    local preset = (cfg().preset or {})
    if type(preset.pick) == "function" then
        return preset.pick(source, extra and { cwd = extra } or nil)
    end
    local ok, picker = pcall(require, "lvim-utils.picker")
    if not ok then
        return
    end
    -- map the snacks-style source names onto the lvim-utils finders
    local fn = ({ files = "files", oldfiles = "oldfiles", grep = "grep", live_grep = "grep" })[source] or source
    if type(picker[fn]) == "function" then
        if extra and extra ~= "" and (fn == "files" or fn == "grep") then
            -- a cwd argument: switch to it first so the finder lists there
            pcall(vim.cmd.lcd, vim.fn.fnameescape(extra))
        end
        picker[fn]()
    end
end

-- ─── auto-open on startup ─────────────────────────────────────────────────────

--- Whether the empty startup conditions hold (no file args, a single empty unnamed buffer, interactive TTY) —
--- so the dashboard should replace the blank start screen.
---@return boolean
local function should_auto_open()
    if vim.fn.argc(-1) > 0 then
        return false -- launched with file args
    end
    if api.nvim_buf_get_name(0) ~= "" then
        return false -- the current buffer is a real file
    end
    if vim.bo.modified or vim.bo.buftype ~= "" then
        return false
    end
    if api.nvim_buf_line_count(0) > 1 or (api.nvim_buf_get_lines(0, 0, 1, false)[1] or "") ~= "" then
        return false -- the buffer already has content (e.g. piped stdin)
    end
    -- exactly one ordinary (non-floating) window
    local normal = {}
    for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(w).relative == "" then
            normal[#normal + 1] = w
        end
    end
    if #normal ~= 1 then
        return false
    end
    -- interactive only (skip headless / piped stdin)
    if #api.nvim_list_uis() == 0 then
        return false
    end
    return true
end

--- Auto-open on VimEnter (or immediately if already in the editor at setup time).
local function arm_auto_open()
    local opened = false
    local function try()
        if opened or not should_auto_open() then
            return
        end
        opened = true
        -- save + hide the global chrome while the greeter is up; D:close restores it (a separate
        -- BufWipeout autocmd is unreliable — D:close deletes the augroup it would live in, so the restore
        -- could be torn down before it runs, leaving laststatus = 0 and the editor chrome-less).
        local dash = M.open({ buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() })
        dash._chrome = { showtabline = vim.o.showtabline, laststatus = vim.o.laststatus }
        vim.o.showtabline, vim.o.laststatus = 0, 0
    end
    if vim.v.vim_did_enter == 1 then
        try()
    else
        -- Render on VimEnter, SYNCHRONOUSLY — the window dims + UI are ready by then (in a TUI), and VimEnter
        -- runs BEFORE the first screen paint, so the greeter is on screen at once: no flash of the empty buffer
        -- and no flash of the chrome (any tabline/statusline the chrome sets in its own VimEnter is overwritten
        -- here before the paint). A late-attaching GUI (no UI at VimEnter) falls through to the UIEnter fallback;
        -- `should_auto_open` + the `opened` guard make it fire exactly once whichever gets there first.
        api.nvim_create_autocmd("VimEnter", { once = true, callback = try })
        api.nvim_create_autocmd("UIEnter", {
            once = true,
            callback = function()
                vim.schedule(try)
            end,
        })
    end
end

-- ─── setup / command ──────────────────────────────────────────────────────────

--- Register `:LvimDashboard [open|pick <source> [cwd]]` and (when `auto_open`) the empty-startup auto-open.
--- Called from lvim-utils.setup() once the config is merged. No-op when `config.dashboard.enable` is false.
function M.setup()
    if not cfg().enable then
        return
    end
    api.nvim_create_user_command("LvimDashboard", function(o)
        local sub = o.fargs[1]
        if sub == "pick" then
            M.pick(o.fargs[2], o.fargs[3])
        else
            M.open()
        end
    end, {
        nargs = "*",
        complete = function(lead)
            return vim.tbl_filter(function(s)
                return s:find(lead, 1, true) == 1
            end, { "open", "pick" })
        end,
        desc = "LvimDashboard — open the start dashboard (:LvimDashboard [open|pick <source>])",
    })
    if cfg().auto_open then
        arm_auto_open()
    end
end

--- :checkhealth hook for the dashboard (called from lvim-utils.health).
---@param h table  the vim.health reporter ({ ok, warn, info })
function M.health(h)
    local c = cfg()
    if not c.enable then
        h.info("dashboard disabled (config.dashboard.enable = false)")
        return
    end
    h.ok("dashboard enabled" .. (c.auto_open and " (auto-open on empty startup)" or ""))
    local n = #(c.preset.keys or {})
    if (not c.preset.header or c.preset.header == "") and n == 0 then
        h.warn("dashboard preset is empty — define preset.header / preset.keys (or your own sections) in config")
    else
        h.info(("dashboard preset: %d key(s), header %s"):format(n, (c.preset.header ~= "") and "set" or "empty"))
    end
end

return M
