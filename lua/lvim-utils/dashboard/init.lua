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
---@field _snapping? boolean  re-entrancy guard for the cursor snap
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
    if type(action) == "string" then
        if action:sub(1, 1) == ":" then
            vim.cmd(action:sub(2))
        else
            api.nvim_feedkeys(api.nvim_replace_termcodes(action, true, true, true), "m", false)
        end
    elseif type(action) == "function" then
        action(self)
    end
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
        local row = api.nvim_win_get_cursor(self.win)[1] - 1
        for _, it in ipairs(self.items) do
            if it.action and it._row == row then
                return self:action(it.action)
            end
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
    local it = acts[idx]
    self._cur_pane, self._cur_idx = pane, idx
    self._snapping = true
    pcall(api.nvim_win_set_cursor, self.win, { it._row + 1, it._col or 0 })
    self._snapping = false
    self:highlight_item(it)
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
    local idx = self:nearest(to, api.nvim_win_get_cursor(self.win)[1] - 1)
    self:goto_item(to, idx)
end

--- Safety net for non-keyboard cursor moves (mouse, the initial position): pull the cursor onto the nearest
--- actionable of the current pane, so it can never rest on a blank/banner/title row.
function D:snap()
    if self._snapping or not (self.win and api.nvim_win_is_valid(self.win)) then
        return
    end
    local pane = self._cur_pane or 1
    if #self:actionables(pane) == 0 then -- the current pane has none — find any that does
        pane = 0
        for p = 1, #(self.panes or {}) do
            if #self:actionables(p) > 0 then
                pane = p
                break
            end
        end
        if pane == 0 then
            return
        end
    end
    local idx = self:nearest(pane, api.nvim_win_get_cursor(self.win)[1] - 1)
    self:goto_item(pane, idx)
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
    -- KEEP the logical selection (pane + item index) across re-paints — the row numbers shift when the height
    -- changes (the area opening/closing re-centres the dashboard), so restore by index, not by cursor row.
    -- Only the very first paint has no selection yet → land on the nearest clickable item.
    if self._cur_pane and self._cur_idx then
        self:goto_item(self._cur_pane, self._cur_idx)
    else
        self:snap()
    end
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
    if _current == self then
        _current = nil
    end
end

--- Apply the configured buffer + window options (a clean, chrome-free scratch).
function D:set_options()
    for k, v in pairs(self.opts.bo or {}) do
        pcall(api.nvim_set_option_value, k, v, { buf = self.buf })
    end
    if self.win and api.nvim_win_is_valid(self.win) then
        for k, v in pairs(self.opts.wo or {}) do
            pcall(api.nvim_set_option_value, k, v, { win = self.win })
        end
        vim.wo[self.win].winhighlight = "Normal:" .. (self.opts.hl.normal or "LvimUiDashboardNormal")
    end
end

--- Register the lifecycle autocmds (one augroup): resize → re-paint, buffer-wipe / window-close → close once,
--- window re-enter → re-acquire the window, cursor-move → snap.
function D:init()
    self.augroup = api.nvim_create_augroup("LvimUtilsDashboard_" .. self.buf, { clear = true })
    api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = self.augroup,
        callback = function()
            if not self.closed and self.win and api.nvim_win_is_valid(self.win) then
                local s = self:size()
                if not self._size or s.width ~= self._size.width or s.height ~= self._size.height then
                    self._size = s
                    self:update()
                end
            end
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
    -- the dashboard window was re-entered after the layout changed elsewhere → re-acquire + re-paint
    api.nvim_create_autocmd("WinEnter", {
        group = self.augroup,
        callback = function()
            if not self.closed and api.nvim_get_current_buf() == self.buf then
                local w = api.nvim_get_current_win()
                if w ~= self.win then
                    self.win = w
                end
                self:update()
            end
        end,
    })
    api.nvim_create_autocmd("CursorMoved", {
        group = self.augroup,
        buffer = self.buf,
        callback = function()
            self:snap()
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

--- Auto-open on UIEnter (or immediately if already in the editor at setup time).
local function arm_auto_open()
    local function try()
        if should_auto_open() then
            -- save + hide the global chrome while the greeter is up; restore when it closes
            local save = { showtabline = vim.o.showtabline, laststatus = vim.o.laststatus }
            local dash = M.open({ buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() })
            vim.o.showtabline, vim.o.laststatus = 0, 0
            api.nvim_create_autocmd("BufWipeout", {
                group = dash.augroup,
                buffer = dash.buf,
                callback = function()
                    vim.o.showtabline, vim.o.laststatus = save.showtabline, save.laststatus
                end,
            })
        end
    end
    if vim.v.vim_did_enter == 1 then
        try()
    else
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
