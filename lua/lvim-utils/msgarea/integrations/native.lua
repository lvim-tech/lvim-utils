-- lvim-utils.msgarea.integrations.native: NATIVE command-line completion ↔ msgarea: the ENGINE is Neovim's own `getcompletion` (no plugin), the
-- VIEW is the message zone. On every change of a `:` command line we compute the completion candidates and
-- render them IN the area via the public "completion" SEGMENT — AUTOMATICALLY (no <Tab> needed), exactly
-- like the blink integration but with the built-in completion as the source. Navigation + accept are driven
-- by the consumer's cmdline keymaps (the same grid_*/accept/enter API blink exposes), so the user can swap
-- `integrations = { blink = true }` for `{ native = true }` and keep the same keys. Insert-mode / LSP
-- completion is left to the native popup at the cursor — only the COMMAND LINE is mirrored here.
--
---@module "lvim-utils.msgarea.integrations.native"

local api = vim.api
local fuzzy = require("lvim-utils.fuzzy")
local config = require("lvim-utils.config")

local M = {}

---@type integer? autocmd group
local augroup = nil
---@type table[]  the current candidate items ({ text = word, match? }), in display order
local items = {}
---@type integer  the selected 1-based index (0 = none)
local sel = 0
---@type integer  bumped each refresh; the async fuzzy callback applies only if it is still the latest
local gen = 0

--- The msgarea module (loose require so this can load without it).
---@return table?
local function area()
    local ok, m = pcall(require, "lvim-utils.msgarea")
    return ok and m or nil
end

--- Grid layout opts read from the msgarea config (columns / max visible rows).
---@return integer columns, integer? max_rows
local function grid_opts()
    local mc = config.msgarea or {}
    return mc.completion_columns or 1, mc.completion_max
end

--- True while a `:` command line is active (the only context we mirror — search / insert are left native).
---@return boolean
local function in_cmd()
    return vim.fn.getcmdtype() == ":"
end

--- Recompute the native completion candidates for the current command line, FUZZY-rank them, and render
--- them in the zone. To make completion fuzzy (`:Lvc` → `LvimColorscheme`, not just prefix matches) we
--- BROADEN the candidate set: split the line into a `stem` (up to the last space) + the `token` being
--- completed, keep only the token's path-prefix (the directory for a path, empty for a command/option), ask
--- Neovim for everything in that context, then fuzzy-rank by the rest of the token. Async (fuzzy may spawn
--- fzf); a generation guard drops a stale callback. Empty line / no candidates ⇒ clear.
local function refresh()
    local m = area()
    if not m then
        return
    end
    gen = gen + 1
    local mygen = gen
    if not in_cmd() then
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    local line = vim.fn.getcmdline()
    if line == "" then -- nothing typed yet — don't dump the entire command list
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    local stem, token = line:match("^(.*%s)(%S*)$")
    if not stem then
        stem, token = "", line
    end
    local bprefix = token:match("^(.*/)") or "" -- the path-prefix (dir) of the token; "" for a command/option
    local fz = token:sub(#bprefix + 1) -- the part fuzzy-matched against the broadened candidates
    local ok, cands = pcall(vim.fn.getcompletion, stem .. bprefix, "cmdline")
    if not ok or not cands then
        cands = {}
    end
    -- getcompletion omits dotfiles unless the prefix has a leading dot. For FILE/DIR completion with
    -- `completion_hidden`, fetch the dotfile variant (`<prefix>.`) too and merge — dropping the `.`/`..`
    -- pseudo-entries — so hidden files/folders are fuzzy-completable.
    local mc = config.msgarea or {}
    local ctype = vim.fn.getcmdcompltype()
    if mc.completion_hidden ~= false and (ctype:find("file") or ctype:find("dir")) then
        local okh, hidden = pcall(vim.fn.getcompletion, stem .. bprefix .. ".", "cmdline")
        if okh and hidden then
            for _, h in ipairs(hidden) do
                local base = h:match("[^/]*/?$")
                if base ~= "./" and base ~= "../" and base ~= "." and base ~= ".." then
                    cands[#cands + 1] = h
                end
            end
        end
    end
    if #cands == 0 then
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    -- DISPLAY the last path segment only (the basename) so deep paths don't overflow the grid, but keep the
    -- FULL candidate for accept. Fuzzy-match + sort on the basenames (cleaner than matching the whole path).
    local bases = {}
    for i, c in ipairs(cands) do
        bases[i] = c:match("[^/]*/?$") or c -- "~/foo/bar/baz.lua" → "baz.lua"; "dir/" → "dir/"; a command → itself
    end
    fuzzy.filter(bases, fz, function(ranked)
        if mygen ~= gen or not in_cmd() then -- a newer keystroke superseded this, or the cmdline closed
            return
        end
        items = {}
        for i, r in ipairs(ranked) do
            items[i] = { text = bases[r.idx], full = cands[r.idx], match = r.match }
        end
        if #items == 0 then
            sel = 0
            m.clear_completion()
            return
        end
        -- Preselect the best match ONLY while a token is being TYPED (so <CR> completes a partial command /
        -- option, e.g. `:LvimPick`→`LvimPicker`). After a SPACE (the token is empty — the previous word is
        -- finished and the next arg is OPTIONAL, e.g. `:LvimInstaller ` offering its subcommands) preselect
        -- NOTHING, so <CR> runs the bare command instead of auto-accepting the first subcommand. <Tab> still
        -- selects from here either way.
        sel = (token == "") and 0 or 1
        m.set_completion(items, sel)
    end)
end

--- Move the selection by `delta` (clamped) and re-render just the selection (cheap path).
---@param delta integer
local function move(delta)
    if #items == 0 then
        return false
    end
    sel = math.max(1, math.min(#items, sel + delta))
    local m = area()
    if m then
        m.set_completion_selected(sel)
    end
    return true
end

-- ── public navigation API (mirrors the blink integration) ──────────────────────

--- True when a completion menu is currently shown (candidates available) — so a cmdline keymap can decide
--- to consume the key (and schedule the action OUTSIDE textlock) vs fall through to the default behaviour.
---@return boolean
function M.has_menu()
    return #items > 0
end

--- True when accepting the current selection WOULD change the command line (there is something to fill) —
--- read-only, so it is safe to call synchronously from an expr keymap. Lets `<CR>` complete first when the
--- token is still partial (avoids running an ambiguous command), then execute once it is complete.
---@return boolean
function M.would_fill()
    if #items == 0 or sel < 1 then
        return false
    end
    local cand = items[sel].full or items[sel].text
    local line = vim.fn.getcmdline()
    local stem = line:match("^(.*%s)%S*$") or ""
    return (stem .. cand) ~= line
end

--- Move down a whole grid ROW (by the column count).
---@return boolean handled
function M.grid_down()
    local cols = select(1, grid_opts())
    return move(cols)
end

--- Move up a whole grid ROW.
---@return boolean handled
function M.grid_up()
    local cols = select(1, grid_opts())
    return move(-cols)
end

--- Move one cell right.
---@return boolean handled
function M.grid_right()
    return move(1)
end

--- Move one cell left.
---@return boolean handled
function M.grid_left()
    return move(-1)
end

--- Accept the selected candidate: replace the last whitespace-delimited token of the command line with it
--- (handles `:hel`→`help`, `:e /tm`→`/tmp/`, `:color dese`→`desert`). `setcmdline` fires CmdlineChanged, so
--- the zone re-completes for the new token (drilling into a directory just works). Returns false when there
--- is nothing to accept (so the key can fall through).
---@return boolean handled
function M.accept()
    if #items == 0 or sel < 1 then
        return false
    end
    local cand = items[sel].full or items[sel].text -- the FULL candidate (path), not the basename display
    local line = vim.fn.getcmdline()
    local stem = line:match("^(.*%s)%S*$") or "" -- everything up to & incl. the last space (empty = no space)
    pcall(vim.fn.setcmdline, stem .. cand)
    return true
end

--- Drill OUT: strip the last path segment of the current token (go up a directory), then re-complete.
--- `:e ~/foo/bar` → `:e ~/foo/`. No path separator ⇒ not handled (the key falls through).
---@return boolean handled
function M.drill_out()
    local line = vim.fn.getcmdline()
    -- the last whitespace-delimited token is the path being completed
    local stem, token = line:match("^(.*%s)(%S*)$")
    if not stem then
        stem, token = "", line
    end
    if not token:find("/") then
        return false
    end
    -- drop the trailing segment after the last slash (keep the slash): "~/foo/bar" → "~/foo/"
    local up = token:gsub("[^/]*/?$", "")
    pcall(vim.fn.setcmdline, stem .. up)
    return true
end

--- <CR>: accept the selection if the menu is open, else let the command line execute (fallback).
---@return boolean handled
function M.enter()
    if #items > 0 and sel >= 1 then
        return M.accept()
    end
    return false
end

-- ── cmdline keymaps (from config.msgarea.completion_keys) ──────────────────────

-- action name → the public method it invokes.
---@type table<string, string>
local KEY_ACTIONS = {
    next = "grid_down",
    prev = "grid_up",
    right = "grid_right",
    left = "grid_left",
    accept = "accept",
    drill_out = "drill_out",
    enter = "accept", -- special-cased in install_keys: complete-then-execute
}

---@type string[]  the cmdline lhs's we installed (to delete on disable)
local mapped_keys = {}

--- Install the command-line keymaps from `config.msgarea.completion_keys`. Each runs as an EXPR map so it
--- can decide consume-vs-fall-through: when a menu is open it SCHEDULES the action (the move/accept changes
--- the zone's window+buffer — forbidden under the expr textlock, E565) and consumes the key; otherwise the
--- key falls through to its native cmdline behaviour.
local function install_keys()
    local keys = (config.msgarea or {}).completion_keys or {}
    for action, method in pairs(KEY_ACTIONS) do
        for _, lhs in ipairs(keys[action] or {}) do
            vim.keymap.set("c", lhs, function()
                -- `enter` is special: complete the selection FIRST while the token is still partial (so an
                -- ambiguous command like `:LvimPick` is filled, not run → no E464), and only fall through to
                -- execute once there is nothing left to fill.
                if action == "enter" then
                    if M.has_menu() and M.would_fill() then
                        vim.schedule(M.accept)
                        return ""
                    end
                    return api.nvim_replace_termcodes(lhs, true, false, true)
                end
                if M.has_menu() then
                    vim.schedule(function()
                        pcall(M[method])
                    end)
                    return ""
                end
                return api.nvim_replace_termcodes(lhs, true, false, true)
            end, { expr = true, silent = true })
            mapped_keys[#mapped_keys + 1] = lhs
        end
    end
end

--- Remove the installed cmdline keymaps.
local function remove_keys()
    for _, lhs in ipairs(mapped_keys) do
        pcall(vim.keymap.del, "c", lhs)
    end
    mapped_keys = {}
end

-- ── lifecycle ──────────────────────────────────────────────────────────────────

--- Turn the integration on: mirror every `:` command-line change into the zone's completion grid + install
--- the command-line navigation keymaps.
function M.enable()
    if augroup then
        return
    end
    install_keys()
    augroup = api.nvim_create_augroup("LvimUtilsMsgAreaNative", { clear = true })
    api.nvim_create_autocmd("CmdlineChanged", {
        group = augroup,
        callback = function()
            -- Defer: a `setcmdline()` (from accept/drill) fires CmdlineChanged under TEXTLOCK, where the zone
            -- render's buffer writes are forbidden (E565). Scheduling runs the refresh outside textlock.
            if in_cmd() then
                vim.schedule(refresh)
            end
        end,
    })
    api.nvim_create_autocmd("CmdlineLeave", {
        group = augroup,
        callback = function()
            items, sel = {}, 0
            local m = area()
            if m then
                m.clear_completion()
            end
        end,
    })
end

--- Turn it off + drop any shown completion + remove the keymaps.
function M.disable()
    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
    remove_keys()
    items, sel = {}, 0
    local m = area()
    if m then
        pcall(m.clear_completion)
    end
end

return M
