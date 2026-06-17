-- lvim-utils.ui.preview: a `frame` center-panel provider that shows a file LOCATION by displaying the
-- file's REAL buffer in the panel window. Because it IS the buffer (not a copy), the preview is fully
-- EDITABLE and stays in two-way sync with the file for free: an edit made here lands in the file, and an
-- edit made in another window shows here. It swaps the buffer in, positions the cursor, and gives the
-- pane a file winbar. The diagnostic SIGNS are hidden here (`signcolumn = "no"`) — they belong to the
-- list panel; the preview stays a clean editable view.
--
-- Navigation out of the preview: the frame's panel/sector keys (`<C-h>`/`<C-l>` move panels, `<C-j>`/
-- `<C-k>` move header·center·footer) are bound on the file buffer ONLY while the preview window is
-- focused (added on WinEnter, removed on WinLeave) — a real buffer is shared, so a persistent map would
-- leak into every other window showing the file. They are normal-mode only, so text editing (and
-- insert-mode `<C-h>` = backspace) is untouched.
--
---@module "lvim-utils.ui.preview"

local api = vim.api

local M = {}

-- The frame nav keys bound on the focused preview buffer → the method/dir they drive on the frame.
local NAV = {
    { "<C-h>", "panel", -1 },
    { "<C-l>", "panel", 1 },
    { "<C-j>", "sector", 1 },
    { "<C-k>", "sector", -1 },
}

--- A filetype icon for `filename` from nvim-web-devicons when installed (colour discarded — the winbar
--- paints it), else a generic document glyph.
---@param filename string
---@return string
local function file_icon(filename)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
        local icon = devicons.get_icon(
            vim.fn.fnamemodify(filename, ":t"),
            vim.fn.fnamemodify(filename, ":e"),
            { default = true }
        )
        if icon and icon ~= "" then
            return icon
        end
    end
    return ""
end

---@class LvimUiPreviewOpts
---@field item fun(): table|nil   returns the current location { filename, lnum, col, end_lnum?, end_col? }
---@field number? string          preview gutter: "none" | "normal" | "relative"

--- Create a preview provider.
---@param opts LvimUiPreviewOpts
---@return table provider
function M.new(opts)
    opts = opts or {}
    local cur_file -- the file currently shown (set the winbar only when it changes)
    local frame -- the owning frame state (captured from pan.frame), so the nav keys can reach it
    local nav_buf -- the buffer the nav keys are currently bound on (nil = none)
    local augroup -- the WinEnter/WinLeave group that adds/removes the nav keys

    local function remove_nav()
        if nav_buf and api.nvim_buf_is_valid(nav_buf) then
            for _, m in ipairs(NAV) do
                pcall(vim.keymap.del, "n", m[1], { buffer = nav_buf })
            end
        end
        nav_buf = nil
    end

    local function add_nav(buf)
        if nav_buf == buf then
            return
        end
        remove_nav()
        for _, m in ipairs(NAV) do
            local method, dir = m[2], m[3]
            vim.keymap.set("n", m[1], function()
                if frame then
                    frame[method](dir)
                end
            end, { buffer = buf, nowait = true, silent = true })
        end
        nav_buf = buf
    end

    --- One-time: while the preview window is focused, bind the frame nav keys on its (real) buffer; drop
    --- them again the moment focus leaves, so the shared file buffer is never left mapped elsewhere.
    ---@param pan table
    local function ensure_autocmds(pan)
        if augroup then
            return
        end
        augroup = api.nvim_create_augroup("LvimUiPreviewNav_" .. tostring(pan.win), { clear = true })
        api.nvim_create_autocmd("WinEnter", {
            group = augroup,
            callback = function()
                if api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() == pan.win then
                    add_nav(api.nvim_win_get_buf(pan.win))
                end
            end,
        })
        api.nvim_create_autocmd("WinLeave", {
            group = augroup,
            callback = function()
                if api.nvim_get_current_win() == pan.win then
                    remove_nav()
                end
            end,
        })
    end

    return {
        on_close = function()
            remove_nav()
            if augroup then
                pcall(api.nvim_del_augroup_by_id, augroup)
                augroup = nil
            end
        end,
        update = function(pan, _geom)
            local it = opts.item and opts.item()
            if not (it and it.filename and pan.win and api.nvim_win_is_valid(pan.win)) then
                return
            end
            frame = pan.frame
            ensure_autocmds(pan)
            -- If the user is IN the preview (editing it), don't swap its buffer or move its cursor out from
            -- under them on a list-navigation / live-reload refresh — leave the edit alone.
            if api.nvim_get_current_win() == pan.win then
                return
            end
            -- Show the REAL file buffer — editable, and bidirectionally in sync with the file (it is the
            -- buffer). Only swap when it actually changes (navigating rows of the same file just moves the
            -- cursor). `nvim_win_set_buf` (not `:edit`) avoids E37 on a modified buffer.
            local pbuf = vim.fn.bufadd(it.filename)
            vim.fn.bufload(pbuf)
            if api.nvim_win_get_buf(pan.win) ~= pbuf then
                api.nvim_win_set_buf(pan.win, pbuf)
            end

            if cur_file ~= it.filename then
                cur_file = it.filename
                -- Full-width file winbar: filetype icon · name · directory.
                local rel = vim.fn.fnamemodify(it.filename, ":~:.")
                local tail = vim.fn.fnamemodify(it.filename, ":t")
                local dir = vim.fn.fnamemodify(rel, ":h")
                local wb = "%#LvimUiPeekFileIcon# " .. file_icon(it.filename) .. " %#LvimUiPeekFile#" .. tail .. " "
                if dir ~= "." and dir ~= "" then
                    wb = wb .. "%#LvimUiPeekFileBar# " .. dir
                end
                vim.wo[pan.win].winbar = wb .. "%#LvimUiPeekFileBar#%="
            end

            local pn = opts.number or "normal"
            vim.wo[pan.win].number = pn == "normal" or pn == "relative"
            vim.wo[pan.win].relativenumber = pn == "relative"
            vim.wo[pan.win].signcolumn = "no" -- diagnostic signs live in the list panel, not here
            vim.wo[pan.win].foldcolumn = "0"
            vim.wo[pan.win].cursorline = true
            vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiPeekCursorLine"

            -- Place the cursor on the location (no extmark — a highlight on the real buffer would bleed
            -- into every other window showing this file).
            local lnum = math.min(it.lnum or 1, math.max(1, api.nvim_buf_line_count(pbuf)))
            pcall(api.nvim_win_set_cursor, pan.win, { lnum, math.max(0, (it.col or 1) - 1) })
            api.nvim_win_call(pan.win, function()
                vim.cmd("normal! zz")
            end)
        end,
    }
end

return M
