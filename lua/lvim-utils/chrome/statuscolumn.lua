-- lvim-utils.chrome.statuscolumn: the per-line gutter, a `%!`-evaluated expression drawn for every screen
-- line: other-sign · diagnostic-sign · `%=` · line number (+ mark) · git gutter.
--
-- Sign extmarks are read per line and bucketed (diagnostic `^DiagnosticSign`, git `^MiniDiffSign`, "other")
-- — the highest-priority one of each is shown. Clicks are wired through `%@…@…%X` regions to the configurable
-- handler table (`config.chrome.statuscolumn.handlers` / `.number_click`) so lvim-utils ships no hard plugin
-- dependency. Ported 1:1 from the user's heirline statuscolumn.
--
---@module "lvim-utils.chrome.statuscolumn"

local api = vim.api
local parts = require("lvim-utils.chrome.parts")

local M = {}

local function scfg()
    return require("lvim-utils.config").chrome.statuscolumn or {}
end

-- ── extmark reader (ported 1:1) ───────────────────────────────────────────────
--- Sign extmarks on `buf` line `lnum` (1-based) passing `filter(hl)`, sorted by priority (highest first).
---@param buf integer
---@param lnum integer
---@param filter fun(hl: string): boolean
---@return { name: string, text: string, sign_hl_group: string, priority: integer }[]
local function get_extmarks(buf, lnum, filter)
    if not api.nvim_buf_is_valid(buf) then
        return {}
    end
    local ok, marks = pcall(api.nvim_buf_get_extmarks, buf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
    if not ok or not marks then
        return {}
    end
    local res = {}
    for _, m in ipairs(marks) do
        local d = m[4] or {}
        local hl = d.sign_hl_group or d.number_hl_group or ""
        if hl ~= "" and filter(hl) then
            res[#res + 1] =
                { name = d.sign_name or hl, text = d.sign_text or "", sign_hl_group = hl, priority = d.priority or 0 }
        end
    end
    table.sort(res, function(a, b)
        return (a.priority or 0) > (b.priority or 0)
    end)
    return res
end

local function f_diag(hl)
    return hl:match("^DiagnosticSign") ~= nil
end
local function f_git(hl)
    return hl:match("^MiniDiffSign") ~= nil
end
local function f_other(hl)
    return not (hl:match("^DiagnosticSign") or hl:match("^MiniDiffSign") or hl:match("^[Gg]it[Ss]ign"))
end

-- ── click handlers (referenced from the `%@…@` regions) ───────────────────────
---@param name? string
local function resolve(name)
    if not name or name == "" then
        return
    end
    for pat, cb in pairs(scfg().handlers or {}) do
        if name:match(pat) then
            return vim.defer_fn(cb, 100)
        end
    end
end

--- Move the cursor to the clicked line and return its (win, buf, lnum).
---@return integer? win, integer? buf, integer? lnum
local function at_mouse()
    local mp = vim.fn.getmousepos() or {}
    local win = mp.winid
    if not win or not api.nvim_win_is_valid(win) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    local lnum = mp.line or vim.v.lnum
    pcall(api.nvim_set_current_win, win)
    pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    return win, buf, lnum
end

function M.on_diag()
    local _, buf, lnum = at_mouse()
    if buf and lnum then
        local s = get_extmarks(buf, lnum, f_diag)[1]
        resolve(s and s.name)
    end
end

function M.on_git()
    local _, buf, lnum = at_mouse()
    if buf and lnum then
        local s = get_extmarks(buf, lnum, f_git)[1]
        resolve(s and s.name)
    end
end

function M.on_other()
    local _, buf, lnum = at_mouse()
    if buf and lnum then
        local s = get_extmarks(buf, lnum, f_other)[1]
        resolve(s and s.name)
    end
end

function M.on_number()
    at_mouse()
    local cb = scfg().number_click
    if type(cb) == "function" then
        cb()
    end
end

--- Wrap `text` in a click region calling `M.<fn>`; "" stays "".
---@param fn string
---@param text string
---@return string
local function clickable(fn, text)
    if text == "" then
        return ""
    end
    return ("%%@v:lua.require'lvim-utils.chrome.statuscolumn'.%s@%s%%X"):format(fn, text)
end

-- ── per-section renderers ─────────────────────────────────────────────────────
local function diag_icon(hl)
    local di = parts.icons().diagnostics
    return (hl == "DiagnosticSignError" and di.error)
        or (hl == "DiagnosticSignWarn" and di.warn)
        or (hl == "DiagnosticSignInfo" and di.info)
        or (hl == "DiagnosticSignHint" and di.hint)
        or di.global
end
-- The statuscolumn uses NATIVE gutter groups (the sign's own `DiagnosticSign*` / `MiniDiffSign*` / extmark
-- group, `LineNr`, `CursorLineNr`) — none of which set a bg — so every cell inherits the colorscheme's own
-- (dimmed) gutter background. That keeps the whole gutter ONE uniform dimmed bg, exactly as before chrome.

---@param buf integer
---@param lnum integer
---@return string
local function diag_sign(buf, lnum)
    local s = get_extmarks(buf, lnum, f_diag)[1]
    if not s then
        return " "
    end
    -- the sign's own DiagnosticSign* group carries the diag colour on the gutter bg; pair it with our icon
    return ("%%#%s#%s %%*"):format(s.sign_hl_group, diag_icon(s.sign_hl_group))
end

---@param buf integer
---@param lnum integer
---@return string
local function other_sign(buf, lnum)
    for _, e in ipairs(get_extmarks(buf, lnum, f_other)) do
        if e.text ~= "" then
            return ("%%#%s#%s %%*"):format(e.sign_hl_group, vim.trim(e.text))
        end
    end
    return ""
end

---@param buf integer
---@param lnum integer
---@return string
local function git_gutter(buf, lnum)
    local bar = parts.icons().vline
    if scfg().git_gutter then
        local s = get_extmarks(buf, lnum, f_git)[1]
        if s then
            return ("%%#%s#%s%%*"):format(s.sign_hl_group, bar)
        end
    end
    return ("%%#LineNr#%s%%*"):format(bar) -- the gutter's own dim bar when there is no hunk
end

---@param buf integer
---@return string
local function mark_letter(buf)
    local line = vim.v.lnum
    local marks = vim.list_extend(vim.fn.getmarklist(), vim.fn.getmarklist(buf))
    for _, m in ipairs(marks) do
        local letter = m.mark:match("^[`']?([a-zA-Z])$")
        if letter and m.pos[1] == buf and m.pos[2] == line then
            return letter
        end
    end
    return ""
end

---@param buf integer
---@param win integer
---@return string
local function line_number(buf, win)
    local ft = vim.bo[buf].filetype
    if ft == "qf" or ft == "replacer" or ft == "org" or vim.v.virtnum ~= 0 then
        return ""
    end
    if not vim.wo[win].number then
        return ""
    end
    local mark = scfg().marks and mark_letter(buf) or ""
    local max_len = #tostring(api.nvim_buf_line_count(buf))
    if mark ~= "" then
        local pad = (vim.v.relnum == 0) and string.rep(" ", math.max(0, max_len - 1)) or ""
        return ("%%#LvimUiChromeMark#%s%s%%*"):format(pad, mark)
    end
    local lnum
    if vim.v.relnum == 0 then
        lnum = vim.v.lnum
    else
        lnum = vim.wo[win].relativenumber and vim.v.relnum or vim.v.lnum
    end
    local str = tostring(lnum)
    local pad = string.rep(" ", math.max(0, max_len - #str))
    -- cursor line → bright CursorLineNr; other lines → dim LineNr — both the colorscheme's own (no bg set)
    local hl = (vim.v.relnum == 0) and "CursorLineNr" or "LineNr"
    return ("%%#%s#%s%s%%*"):format(hl, pad, str)
end

--- The `%!`-evaluated statuscolumn string for the current line. All cells use native (no-bg) gutter groups,
--- so the gaps + cells inherit the colorscheme's own dimmed gutter bg — one uniform dimmed gutter.
---@return string
function M.render()
    local win = vim.g.statusline_winid
    if not win or win == 0 or not api.nvim_win_is_valid(win) then
        win = api.nvim_get_current_win()
    end
    local buf = api.nvim_win_get_buf(win)
    local lnum = vim.v.lnum

    return table.concat({
        clickable("on_other", other_sign(buf, lnum)),
        clickable("on_diag", diag_sign(buf, lnum)),
        "%=",
        clickable("on_number", line_number(buf, win)),
        " ",
        clickable("on_git", git_gutter(buf, lnum)),
        " ",
    })
end

return M
