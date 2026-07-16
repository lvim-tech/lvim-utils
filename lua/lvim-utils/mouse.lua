-- lvim-utils.mouse: the ecosystem-wide MOUSE-SELECTION LOCK for UI panels.
--
-- A panel (a tree, an outline, a drawer, a picker list, a cheatsheet) is a RENDERED surface, not a text buffer
-- to select in. Neovim, however, treats every buffer as text: a mouse click there runs the NATIVE mouse
-- behaviour, and that behaviour STARTS VISUAL:
--
--   • `<LeftDrag>`     — a real click almost always jitters a pixel, which arrives as a drag → charwise Visual
--   • `<2-LeftMouse>`  — a fast click → double-click → selects the WORD
--   • `<3-LeftMouse>`  — faster still → triple-click → selects the LINE
--   • `<4-LeftMouse>`  — blockwise
--
-- The symptom is a row whose full-width cursorline bar is replaced by a `Visual` patch over the LABEL only —
-- sometimes a single character, sometimes the word, sometimes the whole text, depending on click speed. It is
-- NOT a highlight/namespace bug: no extmark is involved, and pressing `:` to inspect it leaves Visual, which is
-- why it never shows up in a dump.
--
-- `<LeftMouse>` itself is DELIBERATELY kept — rows and bar buttons must stay clickable — and so is the wheel by
-- default (a docked panel is a real, scrollable window). Providers that genuinely use an event (e.g. the tree's
-- `<2-LeftMouse>` fold toggle) are never clobbered: an lhs already bound on the buffer is skipped.
--
---@module "lvim-utils.mouse"

local api = vim.api

local M = {}

--- Mouse events that start a NATIVE selection (Visual) and must never reach a panel.
---@type string[]
M.SELECT_EVENTS = {
    "<LeftDrag>",
    "<LeftRelease>",
    -- NOTE: `<2-LeftMouse>` is NOT swallowed here — it gets its own panel handler below (routed to the panel's
    -- row-click with a click COUNT of 2, so a panel can act on a DOUBLE click); over the editor it still runs the
    -- native word-select. Its drag/release stay swallowed.
    "<2-LeftDrag>",
    "<2-LeftRelease>",
    "<3-LeftMouse>",
    "<3-LeftDrag>",
    "<3-LeftRelease>",
    "<4-LeftMouse>",
    "<4-LeftDrag>",
    "<4-LeftRelease>",
    "<RightMouse>",
    "<RightDrag>",
    "<RightRelease>",
    "<2-RightMouse>",
    "<3-RightMouse>",
    "<4-RightMouse>",
    "<MiddleMouse>",
    "<MiddleDrag>",
    "<MiddleRelease>",
}

--- The wheel. Nopped ONLY for a fit-to-window modal (where a scroll would pull the view and push the panel's
--- top rows off screen); a docked, scrollable panel keeps it.
---@type string[]
M.SCROLL_EVENTS = { "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }

--- The lhs already mapped on `buf` (normal mode), lower-cased — so a provider's real binding is never
--- overwritten by a `<Nop>`.
---@param buf integer
---@return table<string, true>
local function bound_lhs(buf)
    local out = {}
    local ok, maps = pcall(api.nvim_buf_get_keymap, buf, "n")
    if ok then
        for _, m in ipairs(maps) do
            -- a `<Nop>` we (or a chassis) installed has an empty rhs and no callback — that one MAY be replaced
            if m.callback or (m.rhs and m.rhs ~= "" and m.rhs:lower() ~= "<nop>") then
                out[(m.lhs or ""):lower()] = true
            end
        end
    end
    return out
end

---@type table<integer, fun(line: integer, col0: integer, pos: table, count: integer)>  buf → the panel's row-click
--- handler; `count` is 1 for a single click, 2 for a double click (a panel may act only on a double).
local click_handlers = {}

--- Register a panel's row-click handler with the GLOBAL mouse layer.
---
--- Needed because a buffer-local `<LeftMouse>` map only fires when the panel is ALREADY the current buffer. The
--- common case is the opposite: you are editing code and click into the panel — nvim then runs its NATIVE click
--- (moves focus AND parks the cursor on the clicked column, which is what made word-highlighters paint the
--- label), and the panel's own map never runs. The global `<LeftMouse>` below handles that case by focusing the
--- panel, parking the cursor at column 0, and calling this handler with the clicked (line, col0).
---@param buf integer
---@param fn fun(line: integer, col0: integer, pos?: table, count?: integer)  `count` = 1 single, 2 double click
function M.register_click(buf, fn)
    click_handlers[buf] = fn
    api.nvim_buf_attach(buf, false, {
        on_detach = function()
            click_handlers[buf] = nil
        end,
    })
end

---@type boolean  true while a mouse gesture that BEGAN on a panel is still in flight (button down). nvim anchors
--- a Visual selection to the window where the drag STARTED, so a drag that wanders out of the panel would still
--- paint back INTO it — the gesture's origin, not the pointer's current position, must decide.
local in_panel_gesture = false

---@type fun()|nil  an activation deferred until the mouse button is released (see `defer_activation`)
local pending = nil

--- Defer an activation that SWITCHES WINDOWS until the mouse button is RELEASED.
---
--- WHY this is necessary, and why a buffer-local Nop alone is not enough: buffer-local mouse maps resolve
--- against the CURRENT buffer, not the buffer under the pointer. A panel's click handler that leaves the panel
--- — the LSP outline's `jump()` (`nvim_set_current_win(src)`), and even a *transient* `nvim_win_call(src, …)`
--- to run `zz` there (its `peek`/`follow`) — makes CURRENT point at the source buffer WHILE THE BUTTON IS STILL
--- DOWN. The still-pending `<LeftDrag>`/`<LeftRelease>` then miss the panel's Nops, run nvim's NATIVE mouse
--- handler, and start a Visual selection in the window under the pointer — the panel. The row's full-width
--- cursorline bar is replaced by a Visual patch over the label.
---
--- Running the window-switching part AFTER the release keeps the whole gesture inside the locked panel buffer.
--- The click handler should still move its row selection immediately (instant feedback) and defer only the
--- activation.
---@param fn fun()
function M.defer_activation(fn)
    pending = fn
end

--- Run (and clear) a deferred activation. Installed by `lock()` on `<LeftRelease>`; also safe to call directly.
function M.flush_activation()
    local fn = pending
    pending = nil
    if fn then
        pcall(fn)
    end
end

--- Mark a buffer as a locked PANEL.
---
--- The selection events themselves are handled GLOBALLY (see `setup`) — deliberately NOT with buffer-local
--- `<Nop>`s. A buffer-local mapping WINS over a global one, so nopping them here would shadow the global layer
--- the moment the panel became current, and any future seam that needs to SEE those events (rather than merely
--- swallow them) would silently never fire. So this only stamps the buffer; the global maps read the stamp and
--- decide by the window under the pointer.
---
--- The WHEEL is the one thing still bound here, and only on request: a fit-to-window modal must not scroll (the
--- view would pull its top rows off screen), whereas a docked, scrollable panel keeps the wheel.
---@param buf integer
---@param opts? { scroll?: boolean, used?: table<string, true> }  scroll = nop the wheel (fit-to-window modal);
---       used = lhs to leave alone (a caller that binds them AFTER this call)
function M.lock(buf, opts)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    opts = opts or {}
    vim.b[buf].lvim_mouse_locked = true
    if not opts.scroll then
        return
    end
    local skip = opts.used or {}
    local already = bound_lhs(buf)
    for _, lhs in ipairs(M.SCROLL_EVENTS) do
        if not skip[lhs] and not already[lhs:lower()] then
            pcall(vim.keymap.set, { "n", "v", "i" }, lhs, "<Nop>", { buffer = buf, nowait = true, silent = true })
        end
    end
end

--- Whether `ft` is a registered PANEL filetype — the same registry `lvim-utils.cursor` uses to hide the
--- hardware cursor (`cursor.ft` = transient popups, `cursor.panel_ft` = persistent side panels). A surface
--- where the cursor is not the interaction is exactly a surface where a text selection is meaningless.
---@param ft string
---@return boolean
local function is_panel_ft(ft)
    if not ft or ft == "" then
        return false
    end
    local ok, cfg = pcall(require, "lvim-utils.config")
    if not ok or type(cfg) ~= "table" or type(cfg.cursor) ~= "table" then
        return false
    end
    for _, list in ipairs({ cfg.cursor.ft or {}, cfg.cursor.panel_ft or {} }) do
        for _, f in ipairs(list) do
            if f == ft then
                return true
            end
        end
    end
    return false
end

--- Is `buf` a panel we lock? Either we locked it explicitly (`M.lock` stamps it) or its filetype is in the
--- panel registry. Used by the GLOBAL maps, which must decide by the window UNDER THE POINTER.
---@param buf integer
---@return boolean
local function is_locked_buf(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return false
    end
    if vim.b[buf].lvim_mouse_locked == true then
        return true
    end
    return is_panel_ft(vim.bo[buf].filetype)
end

--- Should the CURRENT mouse event be swallowed — i.e. is the pointer over a locked panel, or is a gesture that
--- BEGAN on one still in flight?
---
--- PUBLIC because a mouse map is global by nature and the LAST one registered WINS: any plugin that binds a
--- mouse key globally overrides this module's lock. lvim-ls binds `<2-LeftMouse>` for CodeLens, and its
--- `return "<2-LeftMouse>"` fall-through then runs nvim's NATIVE double-click — which selects the WORD under the
--- pointer. Inside a panel that paints a Visual patch over the row's label (the LSP outline's "dir" selection).
--- Any such map must ask this FIRST and swallow when it answers true.
---@return boolean
function M.should_swallow()
    if in_panel_gesture then
        return true
    end
    local m = vim.fn.getmousepos()
    local win = m.winid
    return win ~= nil and win ~= 0 and api.nvim_win_is_valid(win) and is_locked_buf(api.nvim_win_get_buf(win))
end

--- Install the ecosystem-wide lock.
---
--- CRITICAL: this cannot be done with buffer-local maps alone. A buffer-local mapping resolves against the
--- CURRENT buffer — but the whole point is a click that arrives while the current window is SOMETHING ELSE (you
--- are editing code and click into the outline; or a click handler already switched focus to the source). In
--- that moment nvim runs the NATIVE mouse handler — it moves focus AND parks the cursor on the clicked column,
--- and a jitter/fast click turns into a Visual selection over the row's label. The panel's Nops never get a say.
---
--- So the decision must be made by the window UNDER THE POINTER, not by the current buffer. These GLOBAL `expr`
--- maps do exactly that: if the pointer is over a locked panel, the event is swallowed; anywhere else the map
--- returns the key unchanged, so the editor keeps its perfectly normal mouse selection.
function M.setup()
    -- Is the pointer currently over a locked panel?
    ---@return boolean
    local function over_panel()
        local m = vim.fn.getmousepos()
        local win = m.winid
        return win ~= nil and win ~= 0 and api.nvim_win_is_valid(win) and is_locked_buf(api.nvim_win_get_buf(win))
    end

    for _, lhs in ipairs(M.SELECT_EVENTS) do
        pcall(vim.keymap.set, { "n", "v", "i" }, lhs, function()
            -- A gesture that STARTED on a panel stays swallowed for its whole life, even after the pointer has
            -- been dragged OUT of the panel. This is the case that kept the bug alive: nvim anchors a Visual
            -- selection to the window where the drag BEGAN, so once the pointer wandered into the editor the
            -- drag was no longer "over a panel", passed through as native — and painted a selection back in the
            -- PANEL, over the row's label. Position alone is not enough; the gesture's ORIGIN decides.
            if in_panel_gesture or over_panel() then
                -- ANY left-release ends the gesture and runs the deferred activation — NOT only `<LeftRelease>`:
                -- a DOUBLE click ends on `<2-LeftRelease>` (triple on `<3-…>`), and a panel that activates on a
                -- double click defers its open until release, so only flushing on `<LeftRelease>` left that open
                -- stranded forever.
                if lhs:match("LeftRelease") then
                    in_panel_gesture = false
                    vim.schedule(M.flush_activation) -- gesture over: run the deferred activation (jump / open)
                end
                return "" -- swallow: never a native selection out of a panel gesture
            end
            return lhs -- a gesture that began in the editor: normal mouse behaviour, untouched
        end, { expr = true, silent = true, desc = "lvim-utils: panel mouse-selection lock" })
    end

    -- The CLICK itself, decided by the window under the pointer for the same reason. Natively, a click into a
    -- panel from another window moves focus AND parks the cursor on the clicked COLUMN — which is what made
    -- word-based highlighters (LSP document-highlight / cursorword) paint the row's label. Here we swallow the
    -- native click and reproduce the panel semantics: focus the panel, park the cursor at COLUMN 0 (a panel row
    -- is a widget; the column carries no meaning), then run the panel's registered row-click handler with the
    -- clicked (line, col0) so column-addressable hit-testing (a fold chevron) still works.
    -- `<LeftMouse>` passes click COUNT 1, `<2-LeftMouse>` passes 2 — so a panel that keys on the count (a file
    -- tree that OPENS only on a double click) gets a RELIABLE double. A buffer-local `<2-LeftMouse>` cannot: the
    -- first click's focus is DEFERRED (scheduled below), so the panel is not yet current when the fast second
    -- click arrives, and the buffer-local map never fires. Routing the double through the global layer (decided
    -- by the window UNDER the pointer, not the current buffer) fixes that.
    ---@param native string  the key fed through natively when the pointer is NOT over a panel
    ---@param count integer  the click count (1 = single, 2 = double)
    ---@return string
    local function panel_click(native, count)
        local m = vim.fn.getmousepos()
        local win = m.winid
        if not (win and win ~= 0 and api.nvim_win_is_valid(win)) then
            in_panel_gesture = false
            return native
        end
        local buf = api.nvim_win_get_buf(win)
        if not is_locked_buf(buf) then
            in_panel_gesture = false
            return native -- the editor: untouched native click / word-select
        end
        -- The gesture STARTS on a panel: swallow every drag/release it produces from here on, even if the
        -- pointer is dragged out into the editor (nvim would otherwise anchor a Visual selection back here).
        in_panel_gesture = true
        local line = math.max(1, math.min(m.line, api.nvim_buf_line_count(buf)))
        local col0 = math.max(0, m.column - 1)
        local handler = click_handlers[buf]
        vim.schedule(function()
            if not (api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)) then
                return
            end
            api.nvim_set_current_win(win)
            pcall(api.nvim_win_set_cursor, win, { line, 0 })
            if handler then
                -- `m` (the full getmousepos table) rides along: a panel with column-addressable chrome needs the
                -- SCREEN column (`wincol`), not just the byte column — e.g. to tell a scrollbar hit from a row.
                pcall(handler, line, col0, m, count)
            end
        end)
        return "" -- swallow the native click
    end
    pcall(vim.keymap.set, { "n", "v", "i" }, "<LeftMouse>", function()
        return panel_click("<LeftMouse>", 1)
    end, { expr = true, silent = true, desc = "lvim-utils: panel row click" })
    pcall(vim.keymap.set, { "n", "v", "i" }, "<2-LeftMouse>", function()
        return panel_click("<2-LeftMouse>", 2)
    end, { expr = true, silent = true, desc = "lvim-utils: panel row double-click" })

    -- Buffer-local locking stays as well (it also stamps `b:lvim_mouse_locked`, which the global maps read).
    local group = api.nvim_create_augroup("LvimUtilsMouseLock", { clear = true })
    api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
        group = group,
        callback = function(ev)
            local buf = ev.buf
            vim.schedule(function()
                if api.nvim_buf_is_valid(buf) and is_panel_ft(vim.bo[buf].filetype) then
                    M.lock(buf)
                end
            end)
        end,
    })
end

return M
