-- lua/lvim-utils/picker/fzf.lua
-- The fzf-TUI finder backend — the SAME surface chassis as the tint picker (picker/init.lua), but the LIST is
-- the real `fzf` binary running as a TUI inside a terminal panel, the way fzf-lua does it. This is the only
-- way to match fzf-lua's productivity over huge candidate sets (e.g. ~/, 1.6M files): fzf (C) owns parsing,
-- matching, ranking AND rendering — Neovim does NOTHING per keystroke — and the producer (fd/rg) streams
-- DIRECTLY into fzf, so the list fills + re-ranks CONTINUOUSLY while you type, never blocking the editor.
--
-- What stays ours (the unified chassis): the surface (area / float / bottom, the msgarea host, the statusline
-- title, the footer hint bar, close/escape) and a REAL Neovim PREVIEW window (treesitter + the devicon
-- winbar). The preview follows fzf's selection via fzf's `focus` event, which writes the focused line into a
-- fifo we read (the fzf-lua "builtin previewer" model: `--preview-window=hidden` + a focus bind that calls
-- back into the editor). The fzf TUI is themed from the live lvim palette through `--color` + the window's
-- `winhl`, so it matches the theme even though fzf — not us — paints the rows.
--
-- Used by the heavy / command-driven finders (files, grep, git_files, directories, buffers). The structured,
-- in-memory finders (lsp locations, diagnostics, …) keep the tint-striped Lua list in picker/init.lua.
--
---@module "lvim-utils.picker.fzf"

local api = vim.api
local uv = vim.uv or vim.loop
local source = require("lvim-utils.picker.source")
local status = require("lvim-utils.chrome.overlay")
local preview = require("lvim-utils.ui.preview")

local NS = api.nvim_create_namespace("lvim-utils-fzf-preview")

local M = {}

--- True when this backend can run: the `fzf` binary is on PATH, `vim.system` exists (async producers) and
--- `mkfifo` is available (the focus→preview channel). Callers fall back to the tint picker otherwise.
---@return boolean
function M.available()
    return source.has("fzf") and type(vim.system) == "function" and source.has("mkfifo")
end

-- ─── theming: the live palette → fzf `--color` ────────────────────────────────
-- fzf paints the list itself, so we cannot apply Neovim highlight GROUPS to its rows — we EXTRACT the colors
-- from the live palette and hand fzf its fixed set of color roles (the fzf-lua model). `bg:-1` keeps the list
-- background TRANSPARENT so it inherits the panel's `Normal` (LvimUiPeekNormal via the window `winhl`), so the
-- fzf bg always matches the surrounding chassis. The selected line echoes the tint canon: a STRONG blue tint.

--- A "#rrggbb" hex of `attr` ("fg"/"bg") from highlight group `group`, or `fallback` when unset — so the fzf
--- TUI input colours track the SAME groups the tint finder uses (configurable via config.picker.hl), not
--- baked-in palette constants.
---@param group string
---@param attr "fg"|"bg"
---@param fallback string
---@return string
local function hl_hex(group, attr, fallback)
    local h = vim.api.nvim_get_hl(0, { name = group, link = false })
    local v = h and h[attr]
    return (type(v) == "number") and ("#%06x"):format(v) or fallback
end

--- The configured highlight-group NAMES for the input field (`config.picker.hl.input` / `.prompt`).
---@return string input_group, string prompt_group
local function input_groups()
    local phl = (require("lvim-utils.config").picker or {}).hl or {}
    return phl.input or "LvimUiPickerInput", phl.prompt or "LvimUiPickerPrompt"
end

--- Build fzf's `--color` value. The INPUT field (query text + field tint) reads the `hl.input` group so it is
--- configurable + consistent with the tint finder; the rest tracks the live palette. Recomputed per open.
---@return string
local function fzf_colors()
    local c = require("lvim-utils.colors")
    local blend = require("lvim-utils.highlight").blend
    local sel_bg = blend(c.blue, c.bg, 0.20) -- the active (current) row: a blue tint 0.2, full-width (--highlight-line)
    -- The diagnostics finder's two-tone search, kept to ONE row: a STRONG-tint badge box (done in fzf_prompt
    -- via ANSI) + a LIGHT-tint typed FIELD (`input-bg`). fzf only paints `input-bg` on a BORDERED input
    -- section, so the caller adds `--input-border=right` — a RIGHT border is a COLUMN, not an extra row, so the
    -- search stays a single row; we colour that border to the SAME field tint so it dissolves (invisible).
    local input_g = input_groups()
    local input_fg = hl_hex(input_g, "fg", c.blue) -- the typed text colour (= the tint finder's input fg)
    local input_bg = hl_hex(input_g, "bg", blend(c.blue, c.bg, 0.10)) -- the typed FIELD tint
    local spec = {
        "fg:" .. c.fg,
        "bg:-1", -- transparent → inherits the panel Normal (themed via winhl)
        "hl:" .. c.red, -- matched characters (the LvimUiMsgAreaMatch red)
        "fg+:" .. c.fg,
        "bg+:" .. sel_bg, -- the selected line
        "hl+:" .. c.red,
        "info:" .. c.comment,
        "border:" .. c.comment,
        "query:" .. input_fg,
        "input-bg:" .. input_bg,
        "input-border:" .. input_bg, -- dissolved into the field (no visible rule)
        "pointer:" .. c.blue,
        "marker:" .. c.red, -- the multi-select mark dot (●) — red
        "spinner:" .. c.yellow,
        "header:" .. c.comment,
    }
    return table.concat(spec, ",")
end

--- A "#rrggbb" hex colour as the "R;G;B" decimal triplet an ANSI truecolor escape needs.
---@param hex string
---@return string
local function hexrgb(hex)
    local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
    return ("%d;%d;%d"):format(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

--- The fzf `--prompt` string: the shared `config.picker.prompt` badge (icon + label with the same pads as the
--- tint finder), wrapped in ANSI so it renders as the STRONG-tint badge box of the diagnostics finder —
--- LvimUiPickerPrompt: blue fg, bold, on a `mtint(blue, 0.3)` bg. fzf paints ANSI in `--prompt`, so the badge
--- gets its OWN background even though fzf has no `prompt-bg` colour role; after the reset the typed query
--- runs on the light `input-bg` field (see fzf_colors). Ends with `input_gap` spaces on that field.
---@return string
local function fzf_prompt()
    local c = require("lvim-utils.colors")
    local blend = require("lvim-utils.highlight").blend
    local pcfg = (require("lvim-utils.config").picker or {}).prompt or {}
    local sp = string.rep
    local icon, label = pcfg.icon or "", pcfg.label or ""
    local badge = sp(" ", pcfg.pad_left or 1)
    if icon ~= "" then
        badge = badge .. icon
    end
    if icon ~= "" and label ~= "" then
        badge = badge .. sp(" ", pcfg.icon_gap or 1)
    end
    if label ~= "" then
        badge = badge .. label
    end
    badge = badge .. sp(" ", pcfg.pad_right or 1)
    -- the badge box colours come from the `hl.prompt` group (LvimUiPickerPrompt) — configurable + consistent
    -- with the tint finder's badge — extracted to ANSI (fzf has no prompt-bg colour role).
    local _, prompt_g = input_groups()
    local fg = hl_hex(prompt_g, "fg", c.blue)
    local bg = hl_hex(prompt_g, "bg", blend(c.blue, c.bg, 0.30))
    local ESC = string.char(27)
    local style = ESC .. "[1m" .. ESC .. "[38;2;" .. hexrgb(fg) .. "m" .. ESC .. "[48;2;" .. hexrgb(bg) .. "m"
    return style .. badge .. ESC .. "[0m" .. sp(" ", pcfg.input_gap or 1)
end

-- ─── fzf → editor channels (fifos) ────────────────────────────────────────────
-- fzf events (`focus`, `result`/`load`) write a line into a fifo via `execute-silent`; we read it async and
-- drive the editor — the preview window (focused line) and the title-bar stats (match/total counts). This is
-- the editor-side of fzf-lua's builtin-previewer model, minus a second process: the MAIN editor is the
-- reader, no RPC server needed.

--- Create a fifo and start reading lines from it. `on_line(line)` fires (scheduled) with the LATEST line in
--- each read. Returns `{ path, close }` — `path` goes into the fzf bind; `close` stops the reader and removes
--- the fifo. Returns nil when a fifo cannot be made (caller then runs without that channel).
---@param on_line fun(line: string)
---@return { path: string, close: fun() }?
local function make_fifo(on_line)
    local path = vim.fn.tempname()
    vim.fn.system({ "mkfifo", path })
    if vim.v.shell_error ~= 0 then
        return nil
    end
    -- O_RDWR ("r+") so the open returns immediately instead of blocking until fzf opens the write end.
    local fd = uv.fs_open(path, "r+", tonumber("0666", 8))
    if not fd then
        os.remove(path)
        return nil
    end
    local pipe = uv.new_pipe(false)
    pipe:open(fd)
    local buf = ""
    pipe:read_start(function(err, data)
        if err or not data then
            return
        end
        buf = buf .. data
        local latest
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then
                break
            end
            latest = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
        end
        if latest then
            vim.schedule(function()
                on_line(latest)
            end)
        end
    end)
    return {
        path = path,
        close = function()
            pcall(function()
                pipe:read_stop()
            end)
            pcall(function()
                pipe:close()
            end) -- closes fd
            os.remove(path)
        end,
    }
end

-- ─── preview (a real Neovim window) ───────────────────────────────────────────

--- Set the preview panel's winbar to the selected file (devicon + name + dimmed dir), the lvim-lsp peek look —
--- the same bar the tint picker draws, so both backends share one preview chrome.
---@param pan table
---@param item table?
local function set_preview_winbar(pan, item)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    local function esc(s)
        return (tostring(s or ""):gsub("%%", "%%%%"))
    end
    local FILE, DIR, BAR = "LvimUiPeekFile", "LvimUiPickerPreviewDir", "LvimUiPeekFileBar"
    local path = item and item.path
    if path and path ~= "" then
        local rel = vim.fn.fnamemodify(path, ":~:.")
        local tail = vim.fn.fnamemodify(rel, ":t")
        local dir = vim.fn.fnamemodify(rel, ":h")
        dir = (dir == "." or dir == "") and "" or (dir .. "/")
        local icon = ""
        local ok_dev, dev = pcall(require, "nvim-web-devicons")
        if ok_dev then
            local gl = dev.get_icon(tail, vim.fn.fnamemodify(tail, ":e"), { default = true })
            icon = gl and (gl .. " ") or ""
        end
        vim.wo[pan.win].winbar = ("%%#%s# %s%s %%#%s# %s %%#%s#%%="):format(
            FILE,
            esc(icon),
            esc(tail),
            DIR,
            esc(dir),
            BAR
        )
    else
        -- a focused result with no path → its text (the no-item case is handled in `render_preview`)
        vim.wo[pan.win].winbar = ("%%#%s# %s %%#%s#%%="):format(FILE, esc(item and item.text or ""), BAR)
    end
end

-- ─── open ─────────────────────────────────────────────────────────────────────

---@class LvimFzfOpts
---@field title? string  the statusline / float title
---@field icon? string  an optional leading glyph for the title
---@field cmd? string[]  the producer argv (FZF_DEFAULT_COMMAND): fzf runs + streams it (files / dirs / git)
---@field contents? string[]  a STATIC candidate list (e.g. buffers) — fed to fzf via a temp file
---@field reload? string  a shell command with a literal `{q}` placeholder (grep): fzf RE-RUNS it per keystroke
---@field fzf_args? string[]  extra raw fzf flags for this finder (e.g. `--delimiter` / `--with-nth`)
---@field parse? fun(line: string): table  turn a selected/focused fzf line into an item (default `{ path = line }`)
---@field preview? fun(item: table): string[], string?, integer?  preview lines (+ filetype, + focus line)
---@field on_confirm fun(item: table)  called with the chosen item
---@field on_cancel? fun()  called when dismissed without a choice
---@field empty_preview? string  the "nothing to preview" placeholder bar text (default "Nothing to preview")
---@field layout? "float"|"bottom"|"area"
---@field height? integer  rows for the docked layouts
---@field max_rows? integer  list/preview height (default 15)
---@field statusline? boolean  publish the title to the bottom statusline (default true)

--- Open the fzf-TUI finder.
---@param opts LvimFzfOpts
function M.open(opts)
    opts = opts or {}
    opts.layout = opts.layout or (require("lvim-utils.config").picker or {}).layout or "area"
    -- Close whatever finder is open (EITHER backend, via the shared registry) so this one replaces it in
    -- place — its docked area is released first, instead of a new finder stacking above the old one.
    source.close_active()

    local surface = require("lvim-utils.ui.surface")
    local maxr = opts.max_rows or 15
    local empty_preview = opts.empty_preview
        or (require("lvim-utils.config").picker or {}).empty_preview
        or "Nothing to preview"
    local opener = api.nvim_get_current_win()
    local parse = opts.parse or function(line)
        return { path = line, text = line }
    end

    local state = {
        closed = false,
        normal = false, -- NORMAL mode on the list: <Esc> left fzf's input, j/k drive fzf via chansend
        st = nil,
        list_pan = nil,
        preview_pan = nil,
        term_buf = nil,
        term_chan = nil,
        cur_item = nil,
        outfile = vim.fn.tempname(),
        fifo = nil, ---@type { path: string, close: fun() }?
        count_fifo = nil, ---@type { path: string, close: fun() }?
        counts = { match = 0, total = 0 }, -- fed live from fzf ($FZF_MATCH_COUNT / $FZF_TOTAL_COUNT)
        msgarea = nil,
    }
    -- this finder's entry in the shared "open finder" registry (so the next open closes us first)
    local active_entry = {
        close = function()
            if not state.closed and state.st then
                pcall(state.st.close)
            end
        end,
    }

    -- statusline title (default on, docked layouts only) — the title goes to the bottom statusline; the
    -- match counter is fzf's own `X/Y` in its info line (top-right, updated live by fzf).
    local docked_layout = opts.layout == "bottom" or opts.layout == "area"
    local sl = opts.statusline
    if sl == nil then
        sl = (require("lvim-utils.config").picker or {}).statusline ~= false
    end
    local use_status = docked_layout and status.is_enabled() and sl

    -- The title bar — the SAME one the tint finder shows (title left, match/total stats right): published to
    -- the bottom statusline when docked + enabled, else drawn as a header band at the top of the panel. fzf's
    -- OWN counter is hidden (--info=hidden); the stats come live from fzf ($FZF_MATCH_COUNT / $FZF_TOTAL_COUNT
    -- via the count fifo), so they climb during the stream and narrow as you filter.
    local show_title_row = (not use_status) and opts.title ~= nil and opts.title ~= ""
    -- panel CONTENT heights (mirror the tint picker): the LIST fits the live match count, the PREVIEW fits the
    -- focused file's line count — both capped at `max_rows`. `refit` relayouts when either changes, so the
    -- panels + the auto-fit area track the content live.
    local function list_rows()
        return math.min(math.max(state.counts.match or 0, 1), maxr)
    end
    local function file_rows()
        local it = state.cur_item
        if it and it.path and it.path ~= "" then
            local b = vim.fn.bufadd(it.path)
            pcall(vim.fn.bufload, b)
            return math.min(api.nvim_buf_line_count(b), maxr)
        end
        return 1
    end
    local last_fit
    local function refit()
        local key = list_rows() .. ":" .. file_rows()
        if key ~= last_fit and state.st and state.st.relayout then
            last_fit = key
            state.st.relayout()
        end
    end
    --- Apply fzf's live match/total to the title bar (statusline or the header band).
    ---@param match integer
    ---@param total integer
    local function update_counts(match, total)
        state.counts.match, state.counts.total = match, total
        if state.closed then
            return
        end
        if use_status then
            status.set({ title = opts.title, icon = opts.icon, current = match, total = total })
        elseif state.st and state.st.refresh_chrome then
            state.st.refresh_chrome()
        end
        refit() -- the match count changed → re-fit the list panel + the auto area
    end

    -- ── park / return (leave fzf for the editor, keep the finder open) ──
    -- PARK: leave fzf's input + focus the editor (the finder stays open, fzf keeps running). A transient
    -- normal-mode map on the SAME key returns. RETURN: focus the fzf terminal → its WinEnter autocmd
    -- re-enters terminal-mode (back in fzf, exactly where you left it) and clears the parked state + map.
    -- ── keys (ALL configurable, config.picker.keys) ──
    local kcfg = (require("lvim-utils.config").picker or {}).keys or {}
    --- A config key value (a single key, a list, or ""/{}) → a flat list of vim-notation keys.
    ---@param v string|string[]|nil
    ---@return string[]
    local function keylist(v)
        if type(v) == "table" then
            return v
        end
        return (type(v) == "string" and v ~= "") and { v } or {}
    end
    --- vim key notation → fzf key notation: "<Tab>"→"tab", "<C-q>"→"ctrl-q", "<CR>"→"enter", "<Esc>"→"esc".
    ---@param k string
    ---@return string
    local function fzfkey(k)
        local s = (k or ""):gsub("^<(.+)>$", "%1"):lower()
        s = s:gsub("^c%-", "ctrl-"):gsub("^[ma]%-", "alt-")
        return ({ cr = "enter", ["return"] = "enter", esc = "esc", tab = "tab", space = "space", bs = "bspace" })[s]
            or s
    end
    local park_key = keylist(kcfg.park)[1] or ""
    local qf_key = keylist(kcfg.quickfix)[1] -- the one key that accepts-into-quickfix (via fzf --expect)
    --- Drop the transient return-map (idempotent).
    local function clear_park_map()
        if state.parked and park_key ~= "" then
            pcall(vim.keymap.del, "n", park_key)
        end
        state.parked = false
    end
    --- Return focus to the fzf terminal (the WinEnter autocmd does startinsert + clear_park_map).
    local function unpark()
        if state.list_pan and state.list_pan.win and api.nvim_win_is_valid(state.list_pan.win) then
            api.nvim_set_current_win(state.list_pan.win)
        end
    end
    --- Leave fzf's input for the editor, keeping the finder open; arm the return-map.
    local function park()
        if state.closed or not (opener and api.nvim_win_is_valid(opener)) then
            return
        end
        state.parked = true
        vim.cmd("stopinsert")
        api.nvim_set_current_win(opener)
        if park_key ~= "" then
            vim.keymap.set("n", park_key, unpark, { nowait = true, silent = true, desc = "Return to the finder" })
        end
    end

    -- ── preview rendering (the real Neovim window) ──
    -- The preview window's options — re-asserted on EVERY render, because setting the file's real `filetype`
    -- (below) fires its ftplugin / FileType autocmds, which on some filetypes (e.g. markdown) flip `number`
    -- off or install their own statuscolumn. Forcing them AFTER the ft keeps the preview consistent across
    -- files: plain line numbers, no sign / fold / statuscolumn gutter, the blue cursorline.
    local function apply_preview_opts(win)
        if not (win and api.nvim_win_is_valid(win)) then
            return
        end
        vim.wo[win].wrap = false
        vim.wo[win].number = true
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn = "no"
        vim.wo[win].foldcolumn = "0"
        vim.wo[win].statuscolumn = ""
        vim.wo[win].cursorline = true
        vim.wo[win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiCursorLine"
    end

    local function render_preview(pan, item)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win) and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        if not item then
            -- NOTHING focused → the single styled "nothing to preview" bar (no winbar → no empty body row)
            vim.wo[pan.win].winbar = ""
            preview.render_empty(pan.buf, NS, empty_preview)
            return
        end
        set_preview_winbar(pan, item)
        api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1) -- drop any prior empty-bar tint before the real preview
        ---@type string[], string?, integer?
        local lines, ft, focus = { "" }, "", nil
        if opts.preview then
            local pl, pf, fo = opts.preview(item)
            lines = (type(pl) == "table" and pl) or (pl and { tostring(pl) }) or { "" }
            ft, focus = pf, fo
        end
        vim.bo[pan.buf].modifiable = true
        pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, lines)
        vim.bo[pan.buf].modifiable = false
        if ft and ft ~= "" and vim.bo[pan.buf].filetype ~= ft then
            pcall(api.nvim_set_option_value, "filetype", ft, { buf = pan.buf })
        elseif (not ft or ft == "") and vim.bo[pan.buf].filetype ~= "" then
            pcall(api.nvim_set_option_value, "filetype", "", { buf = pan.buf })
        end
        apply_preview_opts(pan.win) -- re-assert after the ft so an ftplugin can't strip the numbers / gutter
        if focus then
            pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(focus, #lines)), 0 })
            api.nvim_win_call(pan.win, function()
                vim.cmd("normal! zz")
            end)
        end
    end

    -- fzf focus → update the preview to the focused line's item.
    local function on_focus(line)
        if state.closed or line == "" then
            return
        end
        state.cur_item = parse(line)
        render_preview(state.preview_pan, state.cur_item)
        refit() -- the focused file changed → re-fit the preview panel + the auto area
    end

    -- Scroll the PREVIEW window (a real nvim window) from the fzf terminal — half a page down/up, like the
    -- tint finder's <C-d>/<C-u>. `nvim_win_call` runs the scroll IN the preview window; focus stays in fzf.
    -- `zz` after each scroll keeps the cursor (and so the cursorline) CENTERED in the preview.
    ---@param dir 1|-1
    local function scroll_preview(dir)
        local p = state.preview_pan
        if not (p and p.win and api.nvim_win_is_valid(p.win)) then
            return
        end
        api.nvim_win_call(p.win, function()
            vim.cmd("normal! " .. api.nvim_replace_termcodes(dir > 0 and "<C-d>" or "<C-u>", true, false, true))
            vim.cmd("normal! zz")
        end)
    end

    -- ── close / confirm / cancel ──
    --- Send the selected rows to the quickfix list (each parsed into a file/buffer + line/col + text).
    ---@param items string[]  the raw selected fzf lines
    local function to_quickfix(items)
        local qf = {}
        for _, line in ipairs(items) do
            local it = parse(line)
            if it then
                qf[#qf + 1] = {
                    filename = it.path,
                    bufnr = (not it.path) and it.bufnr or nil,
                    -- 0 (not 1) when the entry has no real position (a plain file pick), so consumers can tell a
                    -- file list from a grep/diagnostic one; vim still jumps to the file's top.
                    lnum = it.lnum or 0,
                    col = it.col or 0,
                    text = it.text or line,
                }
            end
        end
        if #qf > 0 then
            vim.fn.setqflist({}, " ", { title = opts.title or "Picker", items = qf })
            vim.cmd("botright copen")
        end
    end

    local confirmed = false
    --- `lines` = every line fzf wrote to the outfile. With `--expect` (a quickfix key configured), line 1 is
    --- the pressed key ("" for plain accept) and the rest are the selected/marked rows; without it, all lines
    --- are the selection. The quickfix key routes to to_quickfix; anything else opens the first row.
    ---@param code integer
    ---@param lines string[]?
    local function finish(code, lines)
        if state.closed then
            return
        end
        if use_status then
            status.clear()
        end
        if state.st then
            pcall(state.st.close) -- triggers surface on_close → resource cleanup below
        end
        local key, items = "", {}
        if code == 0 and lines and #lines > 0 then
            local start = 1
            if qf_key then -- --expect prints the key as line 1
                key = lines[1] or ""
                start = 2
            end
            for i = start, #lines do
                if lines[i] ~= "" then
                    items[#items + 1] = lines[i]
                end
            end
        end
        if #items == 0 then
            if opts.on_cancel then
                opts.on_cancel()
            end
            return
        end
        confirmed = true
        if qf_key and key == fzfkey(qf_key) then
            to_quickfix(items)
        elseif opts.on_confirm then
            opts.on_confirm(parse(items[1]))
        end
    end

    -- ── the fzf command (run in the terminal panel) ──
    -- Build the shell command line: `fzf <args> > outfile`. fzf draws its TUI on the tty (the pty of the
    -- panel window) and writes the SELECTED line to stdout, which we redirect to `outfile` and read on exit
    -- (the fzf-lua selection protocol). `FZF_DEFAULT_COMMAND` (the producer) is passed via the job env.
    local function shellesc(s)
        return vim.fn.shellescape(s)
    end
    local function build_fzf_cmdline()
        local args = {
            "fzf",
            "--ansi",
            "--layout=reverse",
            "--info=hidden", -- hide fzf's own counter — the match/total stats live in OUR title bar instead
            "--no-separator", -- no rule under the prompt → the list sits DIRECTLY below the search row
            "--no-scrollbar", -- no scrollbar column (the thin `▌` bar down the left/right of the list)
            "--highlight-line", -- the active row's tint covers the WHOLE row, not just the text
            "--multi", -- Tab marks/unmarks rows (multi-select); the mark dot shows in the blank front column
            "--marker=" .. ((require("lvim-utils.config").picker or {}).marker or "●"),
            "--prompt=" .. fzf_prompt(),
            "--pointer=", -- no active-row arrow (the row is shown by --highlight-line); also shifts the item
            -- text one column left so it starts directly UNDER the prompt's search glyph

            "--gutter= ", -- blank the gutter column (fzf's default gutter char is a `▌` — the thin left bar)
            "--input-border=right", -- bordered input section → fzf paints the light field tint (input-bg); a
            -- LEFT border is a COLUMN (not an extra row), so the search stays ONE row tall, dissolved into the tint
            "--color=" .. fzf_colors(),
            "--preview-window=hidden", -- we drive our OWN Neovim preview, not fzf's
        }
        -- the focus → preview fifo bind (only when a preview + fifo are live)
        if opts.preview and state.fifo then
            local w = ("echo {} > %s"):format(shellesc(state.fifo.path))
            args[#args + 1] = "--bind=focus:execute-silent(" .. w .. ")"
        end
        -- the match/total → title-bar stats: fzf sets $FZF_MATCH_COUNT / $FZF_TOTAL_COUNT for bind children;
        -- `result` fires after every filter (incl. each streamed batch), `load` at the final count.
        if state.count_fifo then
            local cw = ('printf "%%s %%s\\n" "$FZF_MATCH_COUNT" "$FZF_TOTAL_COUNT" > %s'):format(
                shellesc(state.count_fifo.path)
            )
            args[#args + 1] = "--bind=result:execute-silent(" .. cw .. ")"
            args[#args + 1] = "--bind=load:execute-silent(" .. cw .. ")"
        end
        -- LIVE mode (grep): fzf does NO fuzzy filtering of its own (`--disabled`); each query RELOADS the
        -- producer (`{q}` = the shell-quoted query fzf substitutes), so fzf re-renders the new results
        -- continuously while you type. The reload string is NOT shell-escaped (it IS a shell command).
        if opts.reload then
            args[#args + 1] = "--disabled"
            args[#args + 1] = "--bind=change:reload(" .. opts.reload .. ")"
            args[#args + 1] = "--bind=start:reload(" .. opts.reload .. ")"
        end
        -- mark / unmark with the configured key, then advance to the next row (multi-select toggle+down)
        for _, k in ipairs(keylist(kcfg.mark)) do
            args[#args + 1] = "--bind=" .. fzfkey(k) .. ":toggle+down"
        end
        -- quickfix: the configured key ACCEPTS the finder; `--expect` makes fzf print that key as the first
        -- output line, so on exit we know to send the marked rows to the quickfix list (vs a plain open).
        if qf_key then
            args[#args + 1] = "--expect=" .. fzfkey(qf_key)
        end
        -- extra per-finder fzf flags (e.g. buffers: `--delimiter` / `--with-nth` to hide the bufnr field)
        for _, a in ipairs(opts.fzf_args or {}) do
            args[#args + 1] = a
        end
        local parts = {}
        for _, a in ipairs(args) do
            parts[#parts + 1] = shellesc(a)
        end
        -- The INPUT caret SHAPE is the embedded terminal's (libvterm) cursor, NOT `guicursor` (which only
        -- gives the colour here) — fzf emits no cursor-shape escape, so libvterm keeps its block default.
        -- Emit a DECSCUSR "steady bar" (`ESC [ 6 q`) into the terminal BEFORE fzf so the caret is a thin bar.
        return "printf '\\033[6 q'; " .. table.concat(parts, " ") .. " > " .. shellesc(state.outfile)
    end

    -- the producer env (FZF_DEFAULT_COMMAND): the static list command, or `cat` of a contents temp file.
    local function producer_env()
        if opts.cmd then
            local parts = {}
            for _, a in ipairs(opts.cmd) do
                parts[#parts + 1] = shellesc(a)
            end
            return table.concat(parts, " ")
        elseif opts.contents then
            local f = vim.fn.tempname()
            local fh = io.open(f, "w")
            if fh then
                fh:write(table.concat(opts.contents, "\n"))
                if #opts.contents > 0 then
                    fh:write("\n")
                end
                fh:close()
            end
            state.contents_file = f
            return "cat " .. shellesc(f)
        end
        -- reload (grep) mode: an EMPTY initial producer (`true`) so fzf does not fall back to its built-in
        -- file walker; `start:reload` / `change:reload` provide the results once the user types.
        return "true"
    end

    -- ── the terminal LIST provider (hosts fzf) ──
    local function start_fzf(pan)
        if state.term_started or not (pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        state.term_started = true
        -- the fzf→editor fifos must exist before the cmdline references their paths
        if opts.preview and not state.fifo then
            state.fifo = make_fifo(on_focus)
        end
        if not state.count_fifo then
            -- each line is "match total"; drive the title bar's stats from it
            state.count_fifo = make_fifo(function(line)
                local m, t = tonumber((line:match("^(%d+)%s"))), tonumber((line:match("%s(%d+)%s*$")))
                if m and t then
                    update_counts(math.floor(m), math.floor(t))
                end
            end)
        end
        local tbuf = api.nvim_create_buf(false, true)
        state.term_buf = tbuf
        api.nvim_win_set_buf(pan.win, tbuf)
        -- The terminal panel is fzf's TUI ONLY: strip EVERY editor chrome the user's global config draws in the
        -- window gutter (winbar, number, sign / fold / STATUSCOLUMN columns — e.g. a `▌` cursorline rule down
        -- the left edge), so fzf's search band sits at the very top and the list runs edge to edge. Must run
        -- AFTER `termopen` (its TermOpen autocmd re-applies the user's window options) and be re-asserted on
        -- WinEnter, so it sticks instead of being overwritten back.
        local function strip_chrome()
            if pan.win and api.nvim_win_is_valid(pan.win) then
                vim.wo[pan.win].winbar = ""
                vim.wo[pan.win].number = false
                vim.wo[pan.win].relativenumber = false
                vim.wo[pan.win].signcolumn = "no"
                vim.wo[pan.win].foldcolumn = "0"
                vim.wo[pan.win].statuscolumn = ""
                vim.wo[pan.win].cursorline = false
            end
        end
        local env = { FZF_DEFAULT_OPTS = "" } -- neutralise the user's global opts; we pass our own
        local prod = producer_env()
        if prod then
            env.FZF_DEFAULT_COMMAND = prod
        end
        local cmdline = build_fzf_cmdline()
        api.nvim_win_call(pan.win, function()
            state.term_chan = vim.fn.termopen({ "sh", "-c", cmdline }, {
                env = env,
                on_exit = function(_, code)
                    local lines = {}
                    local f = io.open(state.outfile)
                    if f then
                        for line in f:lines() do
                            lines[#lines + 1] = line
                        end
                        f:close()
                    end
                    vim.schedule(function()
                        finish(code, lines)
                    end)
                end,
            })
        end)
        vim.bo[tbuf].filetype = "lvim-picker-fzf"
        -- the fzf INPUT caret (config.picker.caret), through the cursor module so it coexists with
        -- cursor-hiding instead of being clobbered by it. The query text colour is the input group's fg.
        pcall(require("lvim-utils.cursor").mark_cursor_buffer, tbuf, source.caret_fragment("t"))
        strip_chrome() -- after termopen + filetype, so the TermOpen/FileType chrome is overwritten, not us
        vim.schedule(strip_chrome) -- and once more next tick, beating any deferred chrome the user applies
        -- Keep the terminal in TERMINAL-mode whenever its window is entered, so fzf always receives the
        -- keystrokes (a stray focus bounce — LSP attach, msgarea reflow — must not leave keys going to the
        -- editor behind us). The single source of truth for "the fzf list has focus → fzf reads the keys".
        state.term_augroup = api.nvim_create_augroup("LvimFzfTerm_" .. tbuf, { clear = true })
        api.nvim_create_autocmd("WinEnter", {
            group = state.term_augroup,
            buffer = tbuf,
            callback = function()
                if not state.closed and state.term_chan then
                    clear_park_map() -- returning to the finder (however we got here) ends the parked state
                    strip_chrome() -- re-assert in case entering re-applied the user's gutter chrome
                    if not state.normal then -- in NORMAL mode we deliberately stay out of terminal-mode (j/k overlay)
                        vim.cmd("startinsert")
                    end
                end
            end,
        })
        local kopts = { buffer = tbuf, nowait = true, silent = true }
        -- park: leave fzf's input for the editor, keeping the finder open (terminal-mode, not passed to fzf)
        if park_key ~= "" then
            vim.keymap.set("t", park_key, park, kopts)
        end
        -- fzf owns these keys: pass the configured control keys it relies on STRAIGHT through to the terminal,
        -- overriding any inherited terminal-mode mapping (a user / plugin TermOpen often binds `<Esc>` to leave
        -- terminal-mode — that would swallow fzf's abort and strand the picker in normal mode). Buffer-local,
        -- so it only affects THIS fzf terminal and dies with the buffer. accept (→ open), mark (→ toggle),
        -- quickfix (→ accept-into-qf via --expect), abort (→ cancel), and nav all keep fzf's own bindings.
        for _, group in ipairs({ kcfg.accept, kcfg.mark, kcfg.quickfix, kcfg.abort, kcfg.nav }) do
            for _, lhs in ipairs(keylist(group)) do
                if lhs ~= "<Esc>" then -- <Esc> drops to NORMAL on the list (below), not passed to fzf as abort
                    vim.keymap.set("t", lhs, lhs, kopts)
                end
            end
        end
        -- NORMAL mode on the list (Telescope-style): <Esc> leaves fzf's input WITHOUT closing — fzf keeps
        -- running, and a normal-mode overlay drives it. `j`/`k` chansend Down/Up into the fzf PTY (so it moves
        -- the selection + the preview follows via the focus fifo); `i`/`a` return to typing; `<CR>` accepts;
        -- `q`/`<Esc>` close (send fzf its abort). The surface keys (rotate, panel nav) are also live here.
        local function feed(keys)
            if state.term_chan then
                pcall(vim.fn.chansend, state.term_chan, keys)
            end
        end
        local function to_insert()
            state.normal = false
            vim.cmd("startinsert")
        end
        vim.keymap.set("t", "<Esc>", function()
            state.normal = true
            -- LEAVE terminal-mode (stopinsert does NOT exit it) → NORMAL on the terminal buffer; fzf keeps running
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
        end, kopts)
        vim.keymap.set("n", "j", function()
            feed("\27[B")
        end, kopts)
        vim.keymap.set("n", "k", function()
            feed("\27[A")
        end, kopts)
        vim.keymap.set("n", "i", to_insert, kopts)
        vim.keymap.set("n", "a", to_insert, kopts)
        vim.keymap.set("n", "<CR>", function()
            feed("\r")
        end, kopts)
        for _, lhs in ipairs({ "q", "<Esc>" }) do
            vim.keymap.set("n", lhs, function()
                feed("\27") -- fzf abort → on_exit → the finder closes
            end, kopts)
        end
        for _, r in ipairs({ { "<C-n>", 1 }, { "<C-p>", -1 } }) do
            vim.keymap.set("n", r[1], function()
                if state.st and state.st.rotate_preview then
                    state.st.rotate_preview(r[2])
                end
            end, kopts)
        end
        -- forward the fzf-owned actions (mark / quickfix) to the PTY in NORMAL too, so <Tab> marks + <C-q> sends
        -- to the quickfix exactly like in insert (chansend the raw key bytes fzf is bound to)
        for _, group in ipairs({ kcfg.mark, kcfg.quickfix }) do
            for _, lhs in ipairs(keylist(group)) do
                vim.keymap.set("n", lhs, function()
                    feed(api.nvim_replace_termcodes(lhs, true, false, true))
                end, kopts)
            end
        end
        -- NORMAL: <C-d>/<C-u> scroll the PREVIEW (as in insert); every OTHER Neovim scroll/page motion is blocked
        -- so it can't scroll the fzf terminal render under us (which would move the cursor + corrupt the display).
        if opts.preview then
            for _, lhs in ipairs(keylist(kcfg.preview_down)) do
                vim.keymap.set("n", lhs, function()
                    scroll_preview(1)
                end, kopts)
            end
            for _, lhs in ipairs(keylist(kcfg.preview_up)) do
                vim.keymap.set("n", lhs, function()
                    scroll_preview(-1)
                end, kopts)
            end
        end
        for _, lhs in ipairs({ "<C-f>", "<C-b>", "<C-e>", "<C-y>", "<PageDown>", "<PageUp>", "gg", "G", "H", "M", "L" }) do
            vim.keymap.set("n", lhs, "<Nop>", kopts)
        end
        -- the preview-scroll keys scroll the PREVIEW (a real nvim window) instead of going to fzf — matching
        -- the tint finder. (fzf's own scroll/query editing on these keys is given up here.)
        if opts.preview then
            for _, lhs in ipairs(keylist(kcfg.preview_down)) do
                vim.keymap.set("t", lhs, function()
                    scroll_preview(1)
                end, kopts)
            end
            for _, lhs in ipairs(keylist(kcfg.preview_up)) do
                vim.keymap.set("t", lhs, function()
                    scroll_preview(-1)
                end, kopts)
            end
        end
    end

    local list_provider = {
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.36)), list_rows() + 1 -- the LIST: matches + fzf's prompt row
        end,
        update = function(pan)
            state.list_pan = pan
            start_fzf(pan)
        end,
        keys = function(_, pan, st)
            state.list_pan, state.st = pan, st
        end,
    }

    -- ── the preview provider (real Neovim window) ──
    local preview_provider = opts.preview
            and {
                size = function()
                    -- with a focus: file lines + winbar; nothing focused: a SINGLE styled "nothing to preview" row
                    return math.max(40, math.floor(vim.o.columns * 0.5)), (state.cur_item and file_rows() + 1) or 1
                end,
                update = function(pan)
                    state.preview_pan = pan
                    apply_preview_opts(pan.win) -- render_preview re-asserts these after the ft too
                    render_preview(pan, state.cur_item)
                end,
                keys = function(_, pan)
                    state.preview_pan = pan
                end,
            }
        or nil

    -- ── layout (mirror the tint picker's surface wiring) ──
    local bottom = opts.layout == "bottom"
    local area = opts.layout == "area"
    local docked = bottom or area
    if area then
        local ok_ma, m = pcall(require, "lvim-utils.msgarea")
        if ok_ma and m.is_enabled and m.is_enabled() then
            state.msgarea = m
        end
    end
    local msgarea = state.msgarea

    local pbord = docked and "none" or nil
    local list_block = {
        id = "list",
        provider = list_provider,
        border = pbord,
        size = { width = { fixed = 0.4 } },
    }
    local preview_block = preview_provider and { id = "preview", provider = preview_provider, border = pbord }
    local blocks = preview_block and { list_block, preview_block } or { list_block }

    local size
    if docked then
        local cap = opts.height or (maxr + 4)
        size = { height = { auto = true, max = cap } }
    else
        size = { width = { fixed = 0.85 }, height = { fixed = 0.7 } }
    end

    -- footer hints — labelled from the configured keys (first of a list), so they track config.picker.keys.
    local function klabel(v)
        return (keylist(v)[1] or ""):gsub("[<>]", "")
    end
    local footer_items = {
        { key = klabel(kcfg.accept), name = "open" },
        { key = "C-j/k", name = "move" },
        { key = klabel(kcfg.mark), name = "mark" },
        { key = klabel(kcfg.quickfix), name = "qf" },
        { key = klabel(kcfg.abort), name = "close" },
    }
    if opts.preview then -- scroll the preview window from the fzf list
        footer_items[#footer_items + 1] = { key = klabel(kcfg.preview_down) .. "/u", name = "preview" }
    end
    if park_key ~= "" then -- the park toggle (leave to the editor / return)
        footer_items[#footer_items + 1] = { key = klabel(kcfg.park), name = "buffer" }
    end

    local host = msgarea
        and function(h)
            local seg = msgarea.segment("lvim-fzf-host", { priority = 5 })
            seg:configure({
                on_descend = function()
                    if state.list_pan and state.list_pan.win and api.nvim_win_is_valid(state.list_pan.win) then
                        api.nvim_set_current_win(state.list_pan.win)
                        vim.cmd("startinsert")
                    end
                    return true
                end,
            })
            return seg:reserve(h, function(rect)
                if state.st and state.st.reposition then
                    state.st.reposition(rect)
                end
            end)
        end

    surface.open({
        mode = "float",
        position = area and "cmdline" or (bottom and "bottom") or nil,
        host = host,
        on_escape_above = function()
            if opener and api.nvim_win_is_valid(opener) then
                api.nvim_set_current_win(opener)
            end
        end,
        zindex = (host and 210) or (area and 200) or nil,
        header_air = false,
        border = docked and "none" or "rounded",
        separator = "│",
        separator_hl = "LvimUiPickerSeparator",
        size = size,
        -- so the surface can rotate the preview (C-n/C-p) + switch the dock height per stack direction
        preview_side = preview_provider and (opts.preview_side or "right") or nil,
        preview_heights = preview_provider
                and (opts.preview_heights or (require("lvim-utils.config").picker or {}).preview_heights)
            or nil,
        -- the title bar (title left + match/total stats right) as a header band — the SAME `title_counter`
        -- band the tint finder draws — shown when not publishing to the statusline; +1 air row under it.
        header = show_title_row and {
            bars = {
                {
                    title_counter = true,
                    text = opts.title,
                    count = function()
                        local m, t = state.counts.match, state.counts.total
                        return (t > 0) and (m .. "/" .. t) or tostring(m)
                    end,
                    hl = "LvimUiPeekTitle",
                    count_hl = "LvimUiSubtitle",
                },
                { text = "" },
            },
        } or nil,
        content = { blocks = blocks },
        footer = { bars = { { items = footer_items } } },
        close_keys = {},
        on_close = function()
            state.closed = true
            clear_park_map() -- drop the transient return-map if the finder closed while parked
            if state.term_buf then -- drop the custom input caret registration (the cursor module restores normal)
                pcall(require("lvim-utils.cursor").mark_cursor_buffer, state.term_buf, nil)
            end
            if state.term_augroup then
                pcall(api.nvim_del_augroup_by_id, state.term_augroup)
                state.term_augroup = nil
            end
            -- kill fzf if it is still running (the surface was closed some other way)
            if state.term_chan then
                pcall(vim.fn.jobstop, state.term_chan)
                state.term_chan = nil
            end
            if state.fifo then
                pcall(state.fifo.close)
                state.fifo = nil
            end
            if state.count_fifo then
                pcall(state.count_fifo.close)
                state.count_fifo = nil
            end
            if state.outfile then
                os.remove(state.outfile)
            end
            if state.contents_file then
                os.remove(state.contents_file)
            end
            if use_status then
                status.clear()
            end
            if msgarea then
                pcall(function()
                    msgarea.segment("lvim-fzf-host"):release()
                end)
            end
            source.clear_active(active_entry)
        end,
    })

    source.set_active(active_entry)

    if use_status then
        status.set({ title = opts.title, icon = opts.icon })
    end

    -- Focus the fzf list (terminal) through the chassis' own focus API, so it grabs focus the same way the
    -- tint picker's input band does; the WinEnter autocmd then enters terminal-mode. Scheduled so the surface
    -- has finished placing + focusing the panels first.
    vim.schedule(function()
        if state.closed then
            return
        end
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        elseif state.list_pan and state.list_pan.win and api.nvim_win_is_valid(state.list_pan.win) then
            api.nvim_set_current_win(state.list_pan.win)
        end
        if state.list_pan and state.list_pan.win and api.nvim_get_current_win() == state.list_pan.win then
            vim.cmd("startinsert")
        end
    end)
end

return M
