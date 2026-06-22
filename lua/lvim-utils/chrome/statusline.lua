-- lvim-utils.chrome.statusline: the bottom status line — 16 segments rendered as a single `%!`-evaluated
-- expression string of `%#LvimUiChrome…#…%*` segments.
--
-- `render()` has three modes, in precedence order:
--   1. the transient OVERLAY (a finder / the command-line published a title+counter) → `overlay.line()`;
--   2. the FLOAT GUARD — when a UI float (a picker / the msgarea zone) is focused, show the LAST REGULAR
--      buffer's minimal info instead of the float's "[Scratch]" (the folded `status.native_guard`);
--   3. otherwise the full 16-segment line for the current buffer.
--
-- Left→right: mode · cwd · file · git · hunks · macro · %= · diagnostics · lsp · filetype · encoding ·
-- fileformat · spell · wordcount · ruler · scrollbar. Ported 1:1 from the user's heirline statusline.
--
---@module "lvim-utils.chrome.statusline"

local api = vim.api
local parts = require("lvim-utils.chrome.parts")
local git_poller = require("lvim-utils.chrome.git")

local M = {}

-- ── float guard ───────────────────────────────────────────────────────────────
---@type integer?  the last window that was NOT one of our UI floats
local last_regular = nil

--- True when `win` is a UI float — a floating window over a special (non-file) buffer.
---@param win integer
---@return boolean
local function is_ui_float(win)
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative == "" then
        return false
    end
    return vim.bo[api.nvim_win_get_buf(win)].buftype ~= ""
end

--- Track the last regular (non-UI-float) window. Called from the chrome autocmds.
function M.track_window()
    local w = api.nvim_get_current_win()
    if not is_ui_float(w) then
        last_regular = w
    end
end

--- The minimal guard line for the last regular window (path · [+] · [RO] · %= line,col).
---@param win integer
---@return string
local function guard_line(win)
    local buf = api.nvim_win_get_buf(win)
    local name = api.nvim_buf_get_name(buf)
    local path = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
    local mod = vim.bo[buf].modified and " [+]" or ""
    local ro = vim.bo[buf].readonly and " [RO]" or ""
    local ok, pos = pcall(api.nvim_win_get_cursor, win)
    local lc = ok and ("%d,%d"):format(pos[1], pos[2] + 1) or ""
    return (" %s%s%s%%=%s "):format(path, mod, ro, lc)
end

-- ── helpers ─────────────────────────────────────────────────────────────────
---@return string  the bar background hex (for inline devicon groups)
local function bar_bg()
    return require("lvim-utils.colors").bg_dark
end

--- Human-readable byte size (e.g. "12.3 KB").
---@param bytes integer
---@return string
local function size_str(bytes)
    local units = { "B", "KB", "MB", "GB" }
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return (i == 1 and "%d %s" or "%.1f %s"):format(bytes, units[i])
end

-- ── segment builders (each returns "" to skip) ──────────────────────────────

local function s_mode()
    local m = vim.fn.mode(1)
    parts.mode = m:sub(1, 1)
    local label = parts.MODE_LABEL[m] or m
    local grp = parts.MODE_GROUP[parts.mode] or "ModeN"
    return parts.seg(grp, (" %s  %%(%s%%)  "):format(parts.icons().vim, label))
end

local function s_cwd()
    local cwd = vim.fn.fnamemodify(vim.fn.getcwd(0), ":~")
    if #cwd >= 0.25 * vim.o.columns then
        cwd = vim.fn.pathshorten(cwd)
    end
    local trail = cwd:sub(-1) == "/" and "" or "/"
    return parts.seg("Blue", (" %s %s%s"):format(parts.icons().folder, cwd, trail))
end

local function s_file(buf)
    local ic = parts.icons()
    local name = api.nvim_buf_get_name(buf)
    local rel = vim.fn.fnamemodify(name, ":.")
    local out = {}
    if rel ~= "" then
        local fn = rel
        if #fn >= 0.25 * vim.o.columns then
            fn = vim.fn.pathshorten(fn)
        end
        out[#out + 1] = parts.seg(parts.MODE_ACCENT[parts.mode] or "Green", fn .. " ")
    end
    local icon, grp = parts.devicon(buf, bar_bg())
    if icon then
        out[#out + 1] = ("%%#%s# %s %%*"):format(grp, icon)
    end
    local fsize = vim.fn.getfsize(name)
    fsize = (fsize and fsize > 0) and fsize or 0
    if fsize > 0 then
        out[#out + 1] = parts.seg("Blue", " " .. size_str(fsize) .. " ")
    end
    if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
        out[#out + 1] = parts.seg("Red", " " .. ic.lock .. " ")
    end
    if vim.bo[buf].modified then
        out[#out + 1] = parts.seg("Red", " " .. ic.save .. " ")
    end
    out[#out + 1] = "%<"
    return table.concat(out)
end

--- Diff line counts for `buf`: vgit's per-buffer status, else mini.diff's summary, else zeros.
---@param buf integer
---@return { added: integer, removed: integer, changed: integer }
local function diff_counts(buf)
    local s = vim.b[buf].vgit_status
    if not s then
        local ok, md = pcall(require, "mini.diff")
        if ok then
            local data = md.get_buf_data(buf)
            local sum = data and data.summary
            if sum then
                s = { added = sum.add, removed = sum.delete, changed = sum.change }
            end
        end
    end
    s = s or {}
    return { added = s.added or 0, removed = s.removed or 0, changed = s.changed or 0 }
end

local function s_git(buf)
    local g = git_poller.get()
    if not (g and g.head and g.head.branch) then
        return ""
    end
    local ic = parts.icons()
    local out = { parts.seg("Orange", (" %s %s (%s) "):format(ic.git, g.head.branch, g.head.abbrev)) }
    local d = diff_counts(buf)
    if d.added > 0 then
        out[#out + 1] = parts.seg("GitAdd", (" %s %d"):format(ic.git_status.added, d.added))
    end
    if d.removed > 0 then
        out[#out + 1] = parts.seg("GitDelete", (" %s %d"):format(ic.git_status.deleted, d.removed))
    end
    if d.changed > 0 then
        out[#out + 1] = parts.seg("GitChange", (" %s %d"):format(ic.git_status.modified, d.changed))
    end
    return table.concat(out)
end

--- Normalise a mini.diff hunk across field-name variants.
---@param h table
---@return table
local function hunk_fields(h)
    return {
        buf_start = h.buf_start or (h.new and h.new.start) or h.new_start,
        buf_count = h.buf_count or (h.new and h.new.count) or h.new_count,
        old_count = h.old_count or (h.old and h.old.count) or h.orig_count or h.ref_count or (h.ref and h.ref.count),
        type = h.type or h.kind,
    }
end

local function s_hunks(buf)
    local g = git_poller.get()
    if not (g and g.head) then
        return ""
    end
    local ok, md = pcall(require, "mini.diff")
    if not ok then
        return ""
    end
    local data = md.get_buf_data(buf)
    local hunks = data and data.hunks or {}
    if #hunks == 0 then
        return ""
    end

    local lnum = vim.fn.line(".")
    local idx, htype, cur = nil, nil, nil
    for i, h in ipairs(hunks) do
        local f = hunk_fields(h)
        if f.buf_start and f.buf_count then
            local first = f.buf_start
            local last = f.buf_start + math.max(f.buf_count - 1, 0)
            if f.type == "delete" then
                if lnum == first or (first == 0 and lnum == 1) then
                    idx, htype, cur = i, f.type, f
                    break
                end
            elseif lnum >= first and lnum <= last then
                idx, htype, cur = i, f.type, f
                break
            end
        end
    end

    -- compound change+delete: a change hunk with old & new lines, followed by an adjacent delete hunk
    local second = nil
    if cur and type(htype) == "string" and htype:match("change") then
        if (cur.old_count or 0) > 0 and (cur.buf_count or 0) > 0 then
            local nh = hunks[idx + 1]
            if nh then
                local nf = hunk_fields(nh)
                local expected = (cur.buf_start or 0) + (cur.buf_count or 0)
                local adjacent = nf.buf_start == expected or (nf.buf_start == 0 and expected == 1)
                if nf.type == "delete" and adjacent then
                    second = idx + 1
                end
            end
        end
    end

    local ic = parts.icons()
    local out = { parts.seg("Blue", "  " .. ic.commit .. " ") }
    local type_group = (htype == "add" and "GitAdd")
        or (htype == "change" and "GitChange")
        or ((htype == "delete" or htype == "remove") and "GitDelete")
        or "Blue"
    out[#out + 1] = parts.seg(idx and type_group or "Blue", tostring(idx or "-"))
    if second then
        out[#out + 1] = parts.seg("Blue", ",")
        out[#out + 1] = parts.seg("GitDelete", tostring(second))
    end
    out[#out + 1] = parts.seg("Blue", ("/%d "):format(#hunks))
    return table.concat(out)
end

local function s_macro()
    if vim.fn.reg_recording() == "" or vim.o.cmdheight ~= 0 then
        return ""
    end
    return parts.seg("Red", " [") .. parts.seg("Green", vim.fn.reg_recording()) .. parts.seg("Red", "]")
end

local function s_diagnostics(buf)
    local sev = vim.diagnostic.severity
    -- one `count` call (a per-severity table) instead of four `get` calls — the statusline redraws often
    local c = vim.diagnostic.count(buf)
    local e, w, i, h = c[sev.ERROR] or 0, c[sev.WARN] or 0, c[sev.INFO] or 0, c[sev.HINT] or 0
    if e + w + i + h == 0 then
        return ""
    end
    local di = parts.icons().diagnostics
    local out = {}
    if e > 0 then
        out[#out + 1] = parts.seg("DiagError", ("%s %d "):format(di.error, e))
    end
    if w > 0 then
        out[#out + 1] = parts.seg("DiagWarn", ("%s %d "):format(di.warn, w))
    end
    if i > 0 then
        out[#out + 1] = parts.seg("DiagInfo", ("%s %d "):format(di.info, i))
    end
    if h > 0 then
        out[#out + 1] = parts.seg("DiagHint", ("%s %d "):format(di.hint, h))
    end
    return table.concat(out)
end

--- LSP servers + EFM linters/formatters for `buf` (all dependencies pcall-guarded). EXPENSIVE (queries
--- clients + mason) — computed only on lsp/buffer/ft change and CACHED; the render reads the cache.
local function compute_lsp(buf)
    local clients = vim.lsp.get_clients({ bufnr = buf })
    if #clients == 0 then
        return ""
    end
    local lsp = {}
    for _, c in ipairs(clients) do
        if c.name ~= "efm" then
            lsp[#lsp + 1] = c.name
        end
    end

    local linters, formatters = {}, {}
    local ok_mgr, mgr = pcall(require, "lvim-ls.core.manager")
    local ok_state, ls_state = pcall(require, "lvim-ls.state")
    local ok_pkg, pkg = pcall(require, "lvim-pkg")
    if ok_mgr and ok_state and ok_pkg then
        local efm_off = mgr.is_server_disabled_globally("efm") or mgr.is_server_disabled_for_buffer("efm", buf)
        if not efm_off then
            local ft = vim.bo[buf].filetype
            local function collect(field, out)
                for _, entry in pairs(ls_state.file_types or {}) do
                    if vim.tbl_contains(entry.filetypes or {}, ft) then
                        for _, tool in ipairs(entry[field] or {}) do
                            local name = type(tool) == "table" and tool[1] or tool
                            if pkg.is_installed("mason", name) then
                                out[#out + 1] = name
                            end
                        end
                    end
                end
            end
            collect("linters", linters)
            collect("formatters", formatters)
        end
    end

    local ic = parts.icons()
    local segs = {}
    if #lsp > 0 then
        segs[#segs + 1] = "LSP [" .. table.concat(parts.remove_duplicate(lsp), ", ") .. "]"
    end
    if #linters > 0 then
        segs[#segs + 1] = "Li [" .. table.concat(parts.remove_duplicate(linters), ", ") .. "]"
    end
    if #formatters > 0 then
        segs[#segs + 1] = "Fo [" .. table.concat(parts.remove_duplicate(formatters), ", ") .. "]"
    end
    if #segs == 0 then
        return ""
    end
    return parts.seg("Blue", (" %s  %s"):format(ic.lsp, table.concat(segs, " | ")))
end

---@type table<integer, string>  per-buffer cached LSP segment
local lsp_cache = {}

--- Recompute + cache `buf`'s LSP segment. Driven by the chrome autocmds (LspAttach/Detach, BufWinEnter,
--- FileType) so the heavy query runs on change, not on every statusline redraw.
---@param buf? integer
function M.refresh_lsp(buf)
    buf = buf or api.nvim_get_current_buf()
    if api.nvim_buf_is_valid(buf) then
        lsp_cache[buf] = compute_lsp(buf)
    end
end

--- Clear a buffer's cached LSP segment (on wipeout) to avoid an unbounded cache.
---@param buf integer
function M.forget(buf)
    lsp_cache[buf] = nil
end

---@param buf integer
---@return string
local function s_lsp(buf)
    local c = lsp_cache[buf]
    if c == nil then
        c = compute_lsp(buf)
        lsp_cache[buf] = c
    end
    return c
end

local function s_filetype(buf)
    local ft = vim.bo[buf].filetype
    if ft == "" then
        return ""
    end
    return parts.seg("Green", "  " .. ft:upper())
end

local function s_encoding(buf)
    local enc = vim.bo[buf].fileencoding
    if enc == "" then
        return ""
    end
    return parts.seg("Orange", " " .. enc:upper())
end

local function s_fileformat(buf)
    local f = vim.bo[buf].fileformat
    if f == "" then
        return ""
    end
    local ic = parts.icons()
    local sym = { unix = ic.unix, dos = ic.dos, mac = ic.mac }
    return parts.seg("Orange", " " .. (sym[f] or f) .. " ")
end

local function s_spell()
    local ok, st = pcall(require, "lvim-linguistics.status")
    if not (ok and st.spell_has and st.spell_has()) then
        return ""
    end
    return parts.seg("Green", " SPELL: " .. st.spell_get())
end

local function s_wordcount()
    local wc = vim.fn.wordcount()
    local txt
    if parts.mode == "v" or parts.mode == "V" then
        txt = (wc.visual_words or 0) .. "/" .. (wc.words or 0)
    else
        txt = tostring(wc.words or 0)
    end
    return parts.seg("Cyan", " " .. txt)
end

local function s_ruler()
    return parts.seg("Red", " %7(%l/%3L%):%2c %P")
end

local function s_scrollbar()
    local cur, total = vim.fn.line("."), vim.fn.line("$")
    local chars = parts.icons().scrollbar
    local idx = math.max(1, math.min(#chars, math.ceil((cur / math.max(total, 1)) * #chars)))
    return parts.seg("Red", "  " .. chars[idx])
end

-- ── render ──────────────────────────────────────────────────────────────────

--- The `%!`-evaluated statusline string.
---@return string
function M.render()
    local overlay = require("lvim-utils.chrome.overlay")
    if overlay.is_enabled() and overlay.is_active() then
        return overlay.line()
    end

    local cur = api.nvim_get_current_win()
    if is_ui_float(cur) and last_regular and api.nvim_win_is_valid(last_regular) then
        return guard_line(last_regular)
    end

    local buf = api.nvim_get_current_buf()
    local seg = (require("lvim-utils.config").chrome.statusline or {}).segments or {}
    local left, right = {}, {}
    local function add(t, on, fn)
        if on then
            t[#t + 1] = fn()
        end
    end
    add(left, seg.mode, s_mode)
    add(left, seg.cwd, s_cwd)
    add(left, seg.file, function()
        return s_file(buf)
    end)
    add(left, seg.git, function()
        return s_git(buf)
    end)
    add(left, seg.hunks, function()
        return s_hunks(buf)
    end)
    add(left, seg.macro, s_macro)
    add(right, seg.diagnostics, function()
        return s_diagnostics(buf)
    end)
    add(right, seg.lsp, function()
        return s_lsp(buf)
    end)
    add(right, seg.filetype, function()
        return s_filetype(buf)
    end)
    add(right, seg.encoding, function()
        return s_encoding(buf)
    end)
    add(right, seg.fileformat, function()
        return s_fileformat(buf)
    end)
    add(right, seg.spell, s_spell)
    add(right, seg.wordcount, s_wordcount)
    add(right, seg.ruler, s_ruler)
    add(right, seg.scrollbar, s_scrollbar)
    -- wrap the flexible gap in our own bar-bg group so the empty middle stays bar-coloured (the global
    -- StatusLine group is themed by the colorscheme and would otherwise show through, breaking continuity).
    return table.concat(left) .. "%#LvimUiChromeFill#%=" .. table.concat(right)
end

return M
