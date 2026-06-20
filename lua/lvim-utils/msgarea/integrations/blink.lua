-- lua/lvim-utils/msgarea/integrations/blink.lua
-- blink.cmp ↔ msgarea: the ENGINE stays blink (sources, fuzzy, selection, accept); the PREVIEW is taken
-- over by the zone. We INTERCEPT blink's live list via its `BlinkCmp*` User autocmds and render the items
-- IN the area via its public "completion" SEGMENT handle — NO blink popup. blink's menu is suppressed in cmdline
-- via its `auto_show` (returns false for cmdline), so only the engine runs; insert-mode completion is left
-- to blink's normal popup at the cursor.
--
---@module "lvim-utils.msgarea.integrations.blink"

local api = vim.api

local M = {}

---@type integer? autocmd group
local augroup = nil

--- True while the COMMAND LINE is active (the only context we hijack — insert completion stays at the cursor).
---@return boolean
local function in_cmdline()
    return vim.fn.mode():sub(1, 1) == "c"
end

--- The msgarea module (loose require so blink can run without it).
---@return table?
local function area()
    local ok, m = pcall(require, "lvim-utils.msgarea")
    return ok and m or nil
end

-- The msgarea "completion" SEGMENT handle — the public seam we drive (get-or-create at priority 50).
-- Cached: the name is constant, so the handle is reusable across events (no per-keystroke allocation).
---@type table?
local comp_handle
---@return table?
local function comp()
    if comp_handle then
        return comp_handle
    end
    local m = area()
    if not m or not m.segment then
        return nil
    end
    comp_handle = m.segment("completion", { kind = "grid", priority = 50 })
    return comp_handle
end

--- Grid layout opts read from the msgarea config (columns / max visible rows).
---@return { columns?: integer, max_rows?: integer }
local function grid_opts()
    local mc = require("lvim-utils.config").msgarea or {}
    return { columns = mc.completion_columns, max_rows = mc.completion_max }
end

--- blink's live completion list + selected index, read straight from blink's `list` module — the
--- `BlinkCmp*` event payload does NOT carry the items (confirmed: `ev.data.items` is nil), so this is
--- the reliable source.
---@return table[] items, integer? selected
local function get_list()
    local ok, list = pcall(require, "blink.cmp.completion.list")
    if not ok then
        return {}, nil
    end
    return list.items or {}, list.selected_item_idx
end

--- A per-item glyph for a PATH completion. blink's cmdline source tags EVERY item `Property` (so the
--- kind icon is identical for files, dirs and commands alike); for a file/dir completion we instead pick
--- the glyph from the item's real nature — a directory (trailing "/") gets blink's Folder glyph, a file
--- its nvim-web-devicons glyph (by extension). Only the GLYPH is chosen; the colour stays the row accent.
--- Returns nil to fall back to the kind icon.
---@param label string
---@param kind_icons table<string, string>
---@return string?
local function path_icon(label, kind_icons)
    if label:sub(-1) == "/" then
        local f = vim.trim(kind_icons.Folder or "")
        return f ~= "" and f or nil
    end
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
        local name = label:match("[^/]+$") or label
        local ic = devicons.get_icon(name, name:match("%.([%w_%-]+)$"), { default = true })
        if ic and ic ~= "" then
            return ic
        end
    end
    local f = vim.trim(kind_icons.File or "")
    return f ~= "" and f or nil
end

--- The fuzzy-matched LABEL character indices for the whole list, computed exactly like blink's own
--- renderer (`fuzzy.fuzzy_matched_indices` over the labels at the current line/cursor). Returns a table
--- `matched[i]` = a list of 0-based char indices into `items[i].label`, or an empty table on any failure.
---@param items table[]
---@return table<integer, integer[]>
local function matched_indices(items)
    local ok_f, fuzzy = pcall(require, "blink.cmp.fuzzy")
    local ok_l, list = pcall(require, "blink.cmp.completion.list")
    if not (ok_f and ok_l) or not list.context then
        return {}
    end
    local labels = {}
    for i, it in ipairs(items or {}) do
        labels[i] = it.label or ""
    end
    local ok_m, res = pcall(
        fuzzy.fuzzy_matched_indices,
        list.context.get_line(),
        list.context.get_cursor()[2],
        labels,
        require("blink.cmp.config").completion.keyword.range
    )
    return (ok_m and res) or {}
end

--- Translate blink items into the zone's neutral format `{ text, icon, icon_hl, match }` — the kind icon
--- and highlight resolved exactly like blink's renderer (item value → appearance.kind_icons →
--- BlinkCmpKind<…>), so the zone stays source-agnostic and the blink specifics live HERE. `match` is the
--- fuzzy-matched label char indices (the zone highlights them; non-blink consumers supply their own). For
--- a file/dir cmdline completion the icon is upgraded to a real folder/file glyph (see `path_icon`).
---@param items table[]
---@return table[]
local function to_neutral(items)
    local ok_t, kinds = pcall(function()
        return require("blink.cmp.types").CompletionItemKind
    end)
    local ok_a, appearance = pcall(function()
        return require("blink.cmp.config").appearance
    end)
    local kind_icons = (ok_a and appearance.kind_icons) or {}
    -- The current command-line completion type (Vim API). Path-like types get per-item file/folder icons.
    local compl = vim.fn.getcmdcompltype()
    local is_path = compl == "file" or compl == "dir" or compl == "file_in_path" or compl == "shellcmdline"
    local matched = matched_indices(items)
    local out = {}
    for i, it in ipairs(items or {}) do
        local kind_name = (ok_t and kinds[it.kind]) or "Field"
        local text = it.label or it.insertText or ""
        out[i] = {
            text = text,
            icon = (is_path and path_icon(text, kind_icons))
                or it.kind_icon
                or kind_icons[kind_name]
                or kind_icons.Field,
            icon_hl = it.kind_hl or ("BlinkCmpKind" .. kind_name),
            match = matched[i],
        }
    end
    return out
end

--- The position helper a blink config may still wire as `cmdline_position` (kept for completeness; with the
--- interception ON, blink's cmdline popup is suppressed, so this is only used if a user re-enables it).
---@return integer[]
function M.cmdline_position()
    local pos = vim.g.ui_cmdline_pos
    if pos ~= nil then
        return { pos[1] - 1, pos[2] }
    end
    local height = (vim.o.cmdheight == 0) and 1 or vim.o.cmdheight
    return { vim.o.lines - height - 1, 0 }
end

-- ─── grid navigation ──────────────────────────────────────────────────────────
-- blink owns the selection (a linear index); the zone renders it as a `completion_columns` grid. These
-- move the selection BY the grid: down/up = ± the column count, right/left = ± 1. Wire them into the
-- user's cmdline keymap. They return false when there is no list, so the key falls through to blink.

--- The configured grid column count.
---@return integer
local function columns()
    return math.max(1, (require("lvim-utils.config").msgarea or {}).completion_columns or 1)
end

--- Move blink's selection by `delta` items (clamped); returns false when there is nothing to move.
---@param delta integer
---@return boolean handled
local function move(delta)
    local ok, list = pcall(require, "blink.cmp.completion.list")
    if not ok or not list.items or #list.items == 0 then
        return false
    end
    local total = #list.items
    list.select(math.max(1, math.min(total, (list.selected_item_idx or 0) + delta)))
    return true
end

-- ─── accept (drill / smart-enter) ──────────────────────────────────────────────
-- blink's `accept` no-ops when its menu is not visible — and we suppress that menu in the cmdline. So we
-- accept with `force = true` to bypass the visibility gate (the list still exists, we just render it).

--- The currently selected blink item, or nil.
---@return table?
local function selected_item()
    local ok, list = pcall(require, "blink.cmp.completion.list")
    return ok and list.items and list.items[list.selected_item_idx] or nil
end

--- DRILL IN: accept the selected item (insert it) WITHOUT executing. For a directory it inserts `dir/` and
--- blink re-completes its contents. Returns false (→ fallback) when there is no selection.
---@return boolean
function M.accept()
    if not selected_item() then
        return false
    end
    local ok, cmp = pcall(require, "blink.cmp")
    return ok and cmp.accept({ force = true }) or false
end

--- DRILL OUT: drop the last path component from the command line and re-complete the parent's contents (the
--- inverse of drilling in). Returns false when there is no path component to drop.
---@return boolean
function M.drill_out()
    local line = vim.fn.getcmdline()
    local stripped = (line:gsub("/+$", "")) -- ignore a trailing slash
    local parent = stripped:match("^(.*/)[^/]*$") -- everything up to and including the previous '/'
    if not parent or parent == line then
        return false
    end
    vim.fn.setcmdline(parent)
    -- setcmdline does NOT make blink re-list a SHORTENED line on its own (drilling IN re-lists because
    -- accept re-triggers; drilling out left the zone empty). Force a re-trigger at the new cursor: this
    -- fires BlinkCmpShow (which the zone mirrors) WITHOUT opening blink's own menu — unlike cmp.show(),
    -- the raw trigger does not force_auto_show, so `auto_show = false` is respected and only the engine runs.
    vim.schedule(function()
        local ok, trigger = pcall(require, "blink.cmp.completion.trigger")
        if ok then
            trigger.show({ force = true, trigger_kind = "keyword" })
        end
    end)
    return true
end

--- ENTER: when an item is selected, ACCEPT it first (fill in the rest of the name the user did not type)
--- and THEN execute the command line — so pressing Enter on a partially-typed-but-selected result runs the
--- completed command. With no selection it returns false, so the key falls through to a plain cmdline `<CR>`
--- (run what was typed). `force = true` is needed because the zone suppresses blink's menu, and the `<CR>`
--- is fed from the accept CALLBACK so it runs only after the completed text is in the command line.
---@return boolean
function M.enter()
    if not selected_item() then
        return false
    end
    local ok, cmp = pcall(require, "blink.cmp")
    if not ok then
        return false
    end
    return cmp.accept({
        force = true,
        callback = function()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
        end,
    })
end

function M.grid_down()
    return move(columns())
end
function M.grid_up()
    return move(-columns())
end
function M.grid_right()
    return move(1)
end
function M.grid_left()
    return move(-1)
end

--- Turn the interception on: mirror blink's list into the zone on show / selection-change, clear on hide.
function M.enable()
    if augroup then
        return
    end
    augroup = api.nvim_create_augroup("LvimUtilsMsgAreaBlink", { clear = true })

    -- SHOW (the list changed — e.g. each keystroke re-filters): translate the items and hand the whole
    -- list to the zone's completion segment (the public handle API).
    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "BlinkCmpShow",
        callback = function()
            if not in_cmdline() then
                return
            end
            local c = comp()
            if c then
                local items, sel = get_list()
                c:set_grid(to_neutral(items), sel, grid_opts())
            end
        end,
    })
    -- SELECT (only the cursor moved within an UNCHANGED list — i.e. grid navigation): update just the
    -- index. Re-translating every item here was the source of the navigation lag on large folders.
    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "BlinkCmpListSelect",
        callback = function()
            if not in_cmdline() then
                return
            end
            local c = comp()
            if c then
                local _, sel = get_list()
                c:select(sel)
            end
        end,
    })
    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "BlinkCmpHide",
        callback = function()
            local c = comp()
            if c then
                c:clear()
            end
        end,
    })
end

--- Turn it off and drop any visualised list.
function M.disable()
    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
    local c = comp()
    if c then
        c:clear()
    end
end

return M
