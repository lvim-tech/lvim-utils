-- lvim-utils.image.inline: TOGGLEABLE inline rendering of a document buffer's images. When enabled for a
-- buffer, every image discovered by image/doc is drawn as virtual lines UNDER its source line (via
-- image/placement's inline path — the buffer text is never touched), and the set is reconciled after edits
-- (debounced) and on resize. A buffer-local key opens the full float viewer for the image under the cursor.
--
-- Lifetime: one prepared Image per source path is cached per buffer and transmitted to the terminal once;
-- reconciles only add/remove the cheap extmark placements, so scrolling and small edits never re-decode or
-- re-transmit. On disable / buffer wipe every image + placement is torn down so nothing leaks on the terminal.
--
---@module "lvim-utils.image.inline"

local api = vim.api
local config = require("lvim-utils.image.config")
local doc = require("lvim-utils.image.doc")
local Placement = require("lvim-utils.image.placement")
local Image = require("lvim-utils.image.image")

local M = {}

---@class lvim-utils.image.inline.Buf
---@field ns integer                                             per-buffer extmark namespace
---@field aug integer                                            per-buffer autocmd group
---@field enabled boolean
---@field gen integer                                            debounce generation counter
---@field key string|nil                                         the mapped open-key (to delete on disable)
---@field images table<string, { img: lvim-utils.image.Image, pid: integer }>  cached prepared images by src
---@field placements table<string, lvim-utils.image.InlinePlacement>           active placements by "row\0src"
---@field anchors { row: integer, src: string }[]               last reconcile's anchors (for under-cursor open)

---@type table<integer, lvim-utils.image.inline.Buf>
local bufs = {}

-- Global inline placement-id sequence (one per cached image, stable across that image's reconciles).
local pid_seq = 0

--- Normalise a buffer argument: nil / 0 → the current buffer.
---@param buf integer|nil
---@return integer
local function cur(buf)
    if buf == nil or buf == 0 then
        return api.nvim_get_current_buf()
    end
    return buf
end

--- The cell box (max width × max height) an inline image may occupy in `buf`'s window. Width is a fraction
--- of the window (≤1) or absolute cells; height is capped so a tall image can't dominate the document.
---@param buf integer
---@return integer max_w, integer max_h, integer win
local function box(buf)
    local win = vim.fn.bufwinid(buf)
    local cols = (win ~= -1) and api.nvim_win_get_width(win) or vim.o.columns
    local mw = config.inline.max_width
    local max_w = mw <= 1 and math.floor(cols * mw) or math.floor(mw)
    max_w = math.max(1, math.min(max_w, cols))
    local mh = config.inline.max_height
    local lines = (win ~= -1) and api.nvim_win_get_height(win) or vim.o.lines
    local max_h = mh <= 1 and math.floor(lines * mh) or math.floor(mh)
    return max_w, math.max(1, max_h), win
end

--- Get (or lazily prepare + cache) the Image for `src` in `buf`. nil when it can't be prepared.
---@param st lvim-utils.image.inline.Buf
---@param src string
---@return { img: lvim-utils.image.Image, pid: integer }|nil
local function get_image(st, src)
    local cached = st.images[src]
    if cached then
        return cached
    end
    local img = Image.new(src)
    if not (img and img:prepare()) then
        return nil
    end
    pid_seq = pid_seq + 1
    cached = { img = img, pid = pid_seq }
    st.images[src] = cached
    return cached
end

--- Reconcile the placements of `buf` to match the images currently in its text. `hard` first drops every
--- cached image (deleting them from the terminal) so they re-transmit at the new geometry — used on resize,
--- where the cell box (and therefore each image's cols/rows) changed.
---@param buf integer
---@param hard? boolean
local function reconcile(buf, hard)
    local st = bufs[buf]
    if not st or not st.enabled or not api.nvim_buf_is_valid(buf) then
        return
    end

    if hard then
        for _, pl in pairs(st.placements) do
            pl:clear()
        end
        for _, c in pairs(st.images) do
            c.img:delete()
        end
        st.placements, st.images = {}, {}
    end

    local anchors = doc.discover(buf)
    st.anchors = anchors

    -- Desired placement set, keyed by row+src so an image moving lines re-anchors cleanly.
    local desired = {}
    for _, a in ipairs(anchors) do
        desired[a.row .. "\0" .. a.src] = a
    end

    -- Drop placements that are no longer present.
    for key, pl in pairs(st.placements) do
        if not desired[key] then
            pl:clear()
            st.placements[key] = nil
        end
    end

    local max_w, max_h, win = box(buf)
    if win == -1 then
        return -- not visible; can't size yet — a BufWinEnter reconcile will pick it up
    end

    -- Add placements that are newly present.
    for key, a in pairs(desired) do
        if not st.placements[key] then
            local c = get_image(st, a.src)
            if c then
                local pl = Placement.inline(c.img, {
                    buf = buf,
                    ns = st.ns,
                    row = a.row,
                    pid = c.pid,
                    max_w = max_w,
                    max_h = max_h,
                })
                if pl then
                    st.placements[key] = pl
                end
            end
        end
    end

    -- Free cached images no longer referenced by any anchor (source removed from the text).
    local live = {}
    for _, a in ipairs(anchors) do
        live[a.src] = true
    end
    for src, c in pairs(st.images) do
        if not live[src] then
            c.img:delete()
            st.images[src] = nil
        end
    end
end

--- Debounce a reconcile of `buf` (coalesces a burst of edits into one rebuild after `config.inline.debounce`).
---@param buf integer
local function schedule(buf)
    local st = bufs[buf]
    if not st then
        return
    end
    st.gen = st.gen + 1
    local g = st.gen
    vim.defer_fn(function()
        local s = bufs[buf]
        if s and s.enabled and s.gen == g then
            reconcile(buf)
        end
    end, config.inline.debounce)
end

--- Whether inline rendering is currently on for `buf` (nil / 0 → current buffer).
---@param buf? integer
---@return boolean
function M.is_enabled(buf)
    local st = bufs[cur(buf)]
    return st ~= nil and st.enabled
end

--- Enable inline image rendering for `buf`: wire the reconcile autocmds + the under-cursor open key and do
--- the first render. Idempotent.
---@param buf integer
function M.enable(buf)
    buf = cur(buf)
    if not api.nvim_buf_is_valid(buf) or (bufs[buf] and bufs[buf].enabled) then
        return
    end
    local st = bufs[buf]
        or {
            ns = api.nvim_create_namespace("lvim-utils.image.inline." .. buf),
            aug = api.nvim_create_augroup("LvimImageInline_" .. buf, { clear = true }),
            gen = 0,
            images = {},
            placements = {},
            anchors = {},
        }
    st.enabled = true
    bufs[buf] = st

    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
        group = st.aug,
        buffer = buf,
        callback = function()
            schedule(buf)
        end,
    })
    -- On BufWinEnter the buffer is (re)shown → size + render; on a resize the cell box changed → hard rebuild.
    api.nvim_create_autocmd("BufWinEnter", {
        group = st.aug,
        buffer = buf,
        callback = function()
            reconcile(buf)
        end,
    })
    api.nvim_create_autocmd("VimResized", {
        group = st.aug,
        callback = function()
            if bufs[buf] and bufs[buf].enabled then
                reconcile(buf, true)
            end
        end,
    })
    api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = st.aug,
        buffer = buf,
        callback = function()
            M.disable(buf)
        end,
    })

    -- Buffer-local under-cursor open key (only while inline is on).
    local key = config.inline.open_key
    if key and key ~= "" then
        st.key = key
        vim.keymap.set("n", key, function()
            M.open_under_cursor(buf)
        end, { buffer = buf, desc = "Open the image under the cursor in the viewer" })
    end

    reconcile(buf)
end

--- Disable inline rendering for `buf`: tear down placements, images, autocmds, and the open key.
---@param buf integer
function M.disable(buf)
    buf = cur(buf)
    local st = bufs[buf]
    if not st then
        return
    end
    for _, pl in pairs(st.placements) do
        pl:clear()
    end
    for _, c in pairs(st.images) do
        c.img:delete()
    end
    if st.key and api.nvim_buf_is_valid(buf) then
        pcall(vim.keymap.del, "n", st.key, { buffer = buf })
    end
    pcall(api.nvim_del_augroup_by_id, st.aug)
    if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_clear_namespace, buf, st.ns, 0, -1)
    end
    bufs[buf] = nil
end

--- Toggle inline rendering for `buf`.
---@param buf? integer
function M.toggle(buf)
    buf = cur(buf)
    if M.is_enabled(buf) then
        M.disable(buf)
    else
        M.enable(buf)
    end
end

--- Open the full float viewer for the image whose source line the cursor is on. When the cursor is not on an
--- image line, fall through to the key's default normal-mode behaviour (so the open key stays usable). Uses a
--- FRESH discovery so it is correct even between debounced reconciles.
---@param buf? integer
function M.open_under_cursor(buf)
    buf = cur(buf)
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local src
    for _, a in ipairs(doc.discover(buf)) do
        if a.row == row then
            src = a.src
            break
        end
    end
    if src then
        require("lvim-utils.image").show(src)
    elseif bufs[buf] and bufs[buf].key then
        -- Not on an image — replay the key's native normal-mode action (no remap, so this map won't recurse).
        api.nvim_feedkeys(api.nvim_replace_termcodes(bufs[buf].key, true, false, true), "n", false)
    end
end

--- Install the AUTO-ENABLE hook (called once from image.setup): when `config.inline.enabled` is on, every
--- document buffer of a `config.inline.filetypes` type gets inline rendering turned on as it loads — and any
--- such buffer already open at setup time is enabled immediately. `enabled = false` leaves inline purely
--- on-demand (`:LvimImageInline`). Idempotent.
local did_setup = false
function M.setup()
    if did_setup then
        return
    end
    did_setup = true
    if not config.inline.enabled then
        return
    end
    local fts = config.inline.filetypes or {}
    -- Auto-enable is DEFERRED (vim.schedule): enabling renders images, which resolves the tty + transmits —
    -- work that must stay OFF the startup / initial-paint path (a markdown opened at launch would otherwise
    -- block). The FileType may fire during startup; scheduling pushes the render to the next tick. Manual
    -- `:LvimImageInline` stays immediate (it is user-triggered, never on the startup path).
    api.nvim_create_autocmd("FileType", {
        group = api.nvim_create_augroup("LvimImageInlineAuto", { clear = true }),
        pattern = fts,
        callback = function(ev)
            vim.schedule(function()
                M.enable(ev.buf)
            end)
        end,
    })
    -- Enable for matching buffers already loaded (their FileType fired before setup ran) — also deferred.
    local want = {}
    for _, ft in ipairs(fts) do
        want[ft] = true
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) and want[vim.bo[b].filetype] then
            vim.schedule(function()
                M.enable(b)
            end)
        end
    end
end

return M
