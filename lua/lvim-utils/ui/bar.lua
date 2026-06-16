-- lvim-utils.ui.bar: a responsive horizontal bar of `ui.button`s.
--
-- Renders a list of button specs into a single width-bounded line: ALIGNED (left / center / right)
-- when it fits, else SCROLLED inside the width with ‹ › chevrons on the overflowing side(s) — keeping
-- the focused button `sel` visible. Each button's STATE is chosen here: hover (if `opts.hover == i`) >
-- active (the spec's `.active` flag) > normal. Returns the line plus, in BYTE columns of that line, the
-- hl spans, the chevron ranges, and per-button visible ranges ({ c0, c1, spec }; c0/c1 nil = scrolled
-- out) so the caller can place extmarks, hit-test the mouse and draw its own selection overlay.
--
-- All glyphs are single display width, so a character column equals a display column; the renderer
-- works in char columns and converts to byte offsets against the final line.
--
---@module "lvim-utils.ui.bar"

local button = require("lvim-utils.ui.button")

local M = {}

local CHEVRON_LEFT = "‹"
local CHEVRON_RIGHT = "›"

--- The natural display width of a bar = the sum of its rendered buttons plus the inter-button
--- separators (`sep`, default 2). Lets a caller size a window to fit the bar un-scrolled.
---@param buttons LvimUiButtonSpec[]
---@param sep? string
---@return integer
function M.width(buttons, sep)
    local gap = vim.fn.strdisplaywidth(sep or "  ")
    local total, prev = 0, false
    for _, spec in ipairs(buttons or {}) do
        if spec.separator then
            total = total + 2 * #(spec.pad or "") + vim.fn.strdisplaywidth(spec.separator)
            prev = false
        else
            if prev then
                total = total + gap
            end
            total = total + vim.fn.strdisplaywidth((button.render(spec, "normal")))
            prev = true
        end
    end
    return total
end

---@param opts { buttons: LvimUiButtonSpec[], width: integer, align?: "left"|"center"|"right", chevrons?: { left?: string, right?: string }, sep?: string, sel?: integer, hover?: integer, off?: integer }
---@return { line: string, spans: table[], chevrons: table[], buttons: table[], off: integer }
function M.render(opts)
    local W = opts.width or 0
    local sep = opts.sep or "  "
    local align = opts.align or "center"
    local chev = opts.chevrons or {}
    local cl, cr = chev.left or CHEVRON_LEFT, chev.right or CHEVRON_RIGHT

    -- 1. Assemble the raw bar text, its hl spans and each button's raw byte range (with its spec).
    -- Entries are either button specs (have `.type`) or non-interactive SEPARATORS (have `.separator`,
    -- e.g. the `●` between filter groups) which carry their own padding and are not clickable. The
    -- `buttons` index stays aligned with `opts.buttons`, so `sel`/`hover`/`active` indices match.
    local t, raw_spans, raw_btns = "", {}, {}
    local prev_button = false
    for i, spec in ipairs(opts.buttons or {}) do
        if spec.separator then
            local pad = spec.pad or ""
            local base = #t
            t = t .. pad
            if spec.hl then
                raw_spans[#raw_spans + 1] = { #t, #t + #spec.separator, spec.hl }
            end
            t = t .. spec.separator .. pad
            raw_btns[i] = { base, #t, spec, sep = true } -- placeholder so indices line up; not a button
            prev_button = false
        else
            if prev_button then
                t = t .. sep
            end
            local state = (opts.hover == i and "hover") or (spec.active and "active") or "normal"
            local btxt, bspans = button.render(spec, state)
            local base = #t
            for _, s in ipairs(bspans) do
                raw_spans[#raw_spans + 1] = { base + s[1], base + s[2], s[3] }
            end
            raw_btns[i] = { base, base + #btxt, spec }
            t = t .. btxt
            prev_button = true
        end
    end

    -- 2. Place it into width: aligned when it fits, else a scrolled window with chevrons.
    local tw = vim.fn.strchars(t)
    local line, shift, lo, hi
    local chevrons = {}
    if tw <= W then
        local pad = (align == "left" and 0) or (align == "right" and (W - tw)) or math.floor((W - tw) / 2)
        pad = math.max(0, pad)
        line = string.rep(" ", pad) .. t
        line = line .. string.rep(" ", math.max(0, W - vim.fn.strchars(line)))
        shift, lo, hi = pad, 0, tw
    else
        local inner = math.max(1, W - 4) -- a chevron + one space reserved on EACH side
        -- Default anchor by alignment, then keep the focused button visible.
        local off = opts.off
        if off == nil then
            off = (align == "right" and (tw - inner)) or (align == "center" and math.floor((tw - inner) / 2)) or 0
        end
        local selbtn = opts.sel and raw_btns[opts.sel]
        if selbtn then
            local s0 = vim.fn.strchars(string.sub(t, 1, selbtn[1]))
            local s1 = vim.fn.strchars(string.sub(t, 1, selbtn[2]))
            if s0 < off then
                off = s0
            elseif s1 > off + inner then
                off = s1 - inner
            end
        end
        off = math.max(0, math.min(off, tw - inner))
        local left = off > 0 and cl or " "
        local right = (off + inner) < tw and cr or " "
        local vis = vim.fn.strcharpart(t, off, inner)
        vis = vis .. string.rep(" ", math.max(0, inner - vim.fn.strchars(vis)))
        line = left .. " " .. vis .. " " .. right -- chevron + 1 space + content + 1 space + chevron
        shift, lo, hi = 2 - off, off, off + inner
        opts.off = off
        if off > 0 then
            chevrons[#chevrons + 1] = { 0, vim.fn.byteidx(line, 1) }
        end
        if (off + inner) < tw then
            local rc = vim.fn.strchars(line) - 1
            chevrons[#chevrons + 1] = { vim.fn.byteidx(line, rc), #line }
        end
    end

    -- 3. Map raw (byte) ranges in `t` to byte ranges in the final `line` (nil = scrolled out of view).
    local function vis_bytes(bc0, bc1)
        local c0 = math.max(vim.fn.strchars(string.sub(t, 1, bc0)), lo)
        local c1 = math.min(vim.fn.strchars(string.sub(t, 1, bc1)), hi)
        if c1 <= c0 then
            return nil
        end
        return vim.fn.byteidx(line, c0 + shift), vim.fn.byteidx(line, c1 + shift)
    end
    local spans, buttons = {}, {}
    for _, s in ipairs(raw_spans) do
        local b0, b1 = vis_bytes(s[1], s[2])
        if b0 then
            spans[#spans + 1] = { b0, b1, s[3] }
        end
    end
    for i, b in ipairs(raw_btns) do
        local b0, b1 = vis_bytes(b[1], b[2])
        buttons[i] = { c0 = b0, c1 = b1, spec = b[3], sep = b.sep } -- sep = a non-interactive separator
    end

    return { line = line, spans = spans, chevrons = chevrons, buttons = buttons, off = opts.off or 0 }
end

return M
