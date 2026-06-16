-- lvim-utils.ui.preview: a `frame` center-panel provider that shows a file LOCATION in its REAL buffer
-- (so it keeps the file's own syntax / treesitter), marks the match range, and gives the pane a file
-- winbar. Generic — any consumer that navigates file locations (an LSP locations navigator, a grep /
-- search view, a git diff list) wires it as a panel and feeds the current location via `opts.item()`.
--
-- The pane's window hosts the EXTERNAL file buffer, so the frame's own panel keymaps (which live on the
-- scratch `pan.buf`) do not apply here; this provider maps the back-focus / close / sector keys onto the
-- file buffer itself, routing them through the frame (`pan.frame`).
--
---@module "lvim-utils.ui.preview"

local util = require("lvim-utils.ui.util")

local api = vim.api
local NS = api.nvim_create_namespace("lvim_utils_ui_preview")

local M = {}

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
---@field back_panel? integer     panel index to focus on back/sector key (default 1)
---@field back_key? string        key that returns focus to `back_panel` (default "<C-h>")
---@field match_hl? string        highlight group for the match range (default "LvimUiPeekMatch")

--- Create a preview provider.
---@param opts LvimUiPreviewOpts
---@return table provider
function M.new(opts)
    opts = opts or {}
    local mapped -- the file buffer the back/close keys are currently bound to

    return {
        update = function(pan, _geom)
            local it = opts.item and opts.item()
            if not (it and it.filename and pan.win and api.nvim_win_is_valid(pan.win)) then
                return
            end
            local pbuf = vim.fn.bufadd(it.filename)
            vim.fn.bufload(pbuf)
            api.nvim_win_set_buf(pan.win, pbuf)
            local ft = vim.filetype.match({ filename = it.filename, buf = pbuf })
            if ft and vim.bo[pbuf].filetype ~= ft then
                vim.bo[pbuf].filetype = ft
            end

            -- Full-width file winbar: filetype icon · name · directory.
            local rel = vim.fn.fnamemodify(it.filename, ":~:.")
            local tail = vim.fn.fnamemodify(it.filename, ":t")
            local dir = vim.fn.fnamemodify(rel, ":h")
            local wb = "%#LvimUiPeekFileIcon# " .. file_icon(it.filename) .. " %#LvimUiPeekFile#" .. tail .. " "
            if dir ~= "." and dir ~= "" then
                wb = wb .. "%#LvimUiPeekFileBar# " .. dir
            end
            vim.wo[pan.win].winbar = wb .. "%#LvimUiPeekFileBar#%="

            local pn = opts.number or "normal"
            vim.wo[pan.win].number = pn == "normal" or pn == "relative"
            vim.wo[pan.win].relativenumber = pn == "relative"
            vim.wo[pan.win].signcolumn = "no"
            vim.wo[pan.win].foldcolumn = "0"
            vim.wo[pan.win].cursorline = true
            vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiPeekCursorLine"

            -- Back-focus / close / sector keys on the REAL file buffer (the frame's panel keys are on the
            -- scratch pan.buf, which this window no longer shows). Routed through the frame.
            if mapped ~= pbuf then
                -- This window shows the FILE buffer, so the frame's own panel/sector maps (on the scratch
                -- pan.buf) don't apply — bind them here, routed through the frame: `<C-l>`/`<C-h>` move
                -- between center panels, `<C-j>`/`<C-k>` step the vertical sectors.
                local function fr(method, dir)
                    return function()
                        if pan.frame then
                            pan.frame[method](dir)
                        end
                    end
                end
                vim.keymap.set("n", "<C-h>", fr("panel", -1), { buffer = pbuf, nowait = true, silent = true })
                vim.keymap.set("n", "<C-l>", fr("panel", 1), { buffer = pbuf, nowait = true, silent = true })
                vim.keymap.set("n", "<C-j>", fr("sector", 1), { buffer = pbuf, nowait = true, silent = true })
                vim.keymap.set("n", "<C-k>", fr("sector", -1), { buffer = pbuf, nowait = true, silent = true })
                -- Header button hotkeys (e.g. filters) work from the preview too.
                if pan.frame and pan.frame.map_hotkeys then
                    pan.frame.map_hotkeys(pbuf, {})
                end
                for _, ck in ipairs((pan.frame and pan.frame.cfg.close_keys) or { "q" }) do
                    vim.keymap.set("n", ck, function()
                        if pan.frame then
                            pan.frame.close()
                        end
                    end, { buffer = pbuf, nowait = true, silent = true })
                end
                for _, lk in ipairs((pan.frame and pan.frame.cfg.leave_keys) or {}) do
                    vim.keymap.set("n", lk, function()
                        if pan.frame then
                            pan.frame.leave()
                        end
                    end, { buffer = pbuf, nowait = true, silent = true })
                end
                mapped = pbuf
            end

            -- Cursor + the match-range highlight.
            local lnum = math.min(it.lnum or 1, math.max(1, api.nvim_buf_line_count(pbuf)))
            pcall(api.nvim_win_set_cursor, pan.win, { lnum, math.max(0, (it.col or 1) - 1) })
            api.nvim_win_call(pan.win, function()
                vim.cmd("normal! zz")
            end)
            api.nvim_buf_clear_namespace(pbuf, NS, 0, -1)
            local l1 = (it.end_lnum or it.lnum or 1) - 1
            local c0 = math.max(0, (it.col or 1) - 1)
            local c1 = it.end_col and (it.end_col - 1) or (c0 + 1)
            pcall(api.nvim_buf_set_extmark, pbuf, NS, (it.lnum or 1) - 1, c0, {
                end_row = l1,
                end_col = c1,
                hl_group = opts.match_hl or "LvimUiPeekMatch",
            })
        end,
    }
end

return M
