-- lvim-utils.image.viewer: the composite image viewer, built on lvim-utils.ui.surface (NOT a hand-rolled
-- float). One surface with a title (the file name), a MAIN panel that shows the image (via an `update`
-- provider so the placement OWNS the buffer), and a toggleable DETAILS panel with coloured `Label  value`
-- rows (the accents chosen by config, from the palette). Both panels are plain blocks INSIDE the popup so its
-- auto width contains them; `d` toggles the details (reopen with/without the block), `q` closes. The border
-- comes from config (the shared `config.ui.border`, overridable per-viewer) — nothing hardcoded.
--
---@module "lvim-utils.image.viewer"

local api = vim.api
local surface = require("lvim-utils.ui.surface")
local colors = require("lvim-utils.colors")
local config = require("lvim-utils.image.config")

local M = {}

--- Resolve a size knob to an absolute cell count: a fraction ≤ 1 scales `total`, a value > 1 is absolute,
--- nil/0 falls back to `default`.
---@param v number|nil
---@param total integer
---@param default integer
---@return integer
local function budget(v, total, default)
    if not v or v <= 0 then
        return default
    end
    return v <= 1 and math.floor(v * total) or math.floor(v)
end

-- Highlight groups for the detail rows — coloured text in two config-chosen palette accents, recomputed from
-- the LIVE palette on every open so they track a colorscheme change.
local function ensure_hl()
    -- Coloured TEXT (no bg box, so nothing overflows the panel). The accents come from the palette by the NAME
    -- set in config (config.detail_label / detail_value) — no hardcoded colour; a colorscheme change re-tints.
    local label = colors[config.detail_label] or colors.blue
    local value = colors[config.detail_value] or colors.yellow
    api.nvim_set_hl(0, "LvimImageDetailLabel", { fg = label, bold = true })
    api.nvim_set_hl(0, "LvimImageDetailValue", { fg = value })
end

--- Build the DETAILS panel provider from `{ label, value }` rows. Each row is a fixed-width label box (blue)
--- + a value box (yellow) filling the panel width; more rows than the panel is tall simply scroll.
---@param rows { label: string, value: string }[]
---@param cap_height integer  natural height (capped to the image height so the IMAGE drives the layout)
---@return table
local function details_provider(rows, cap_height)
    local box = 4
    for _, r in ipairs(rows) do
        box = math.max(box, #r.label + 3)
    end
    return {
        -- Cursor stays VISIBLE here (no hide_cursor) so you can see where you are / how far you've scrolled;
        -- cursorline marks the current row.
        cursorline = true,
        keys = function(map)
            -- Read-only viewer: swallow file-explorer / edit keys that would otherwise leak to GLOBAL maps
            -- (e.g. `-` opening a directory browser). Scrolling (j/k/gg/G/<C-d>/<C-u>) and the frame's d/q
            -- close keys still work.
            for _, k in ipairs({ "-", "i", "a", "o", "O", "x", "p", "r", "c", "s" }) do
                map(k, function() end)
            end
        end,
        size = function()
            -- Width MUST match the block's fixed width (44) — the container sizes itself from this provider
            -- natural width, so a smaller value here makes the panel spill past the container's right edge.
            return 44, math.min(#rows, cap_height)
        end,
        render = function(width)
            local lines, hls = {}, {}
            local valw = math.max(1, width - box - 1) -- value column width → long values WRAP into it
            for _, r in ipairs(rows) do
                -- split the value into width-fitting chunks; continuation lines keep the label column blank
                local v, chunks = r.value, {}
                repeat
                    chunks[#chunks + 1] = v:sub(1, valw)
                    v = v:sub(valw + 1)
                until v == ""
                for ci, chunk in ipairs(chunks) do
                    local label = ci == 1 and (" " .. r.label) or ""
                    local lbl = label .. string.rep(" ", math.max(0, box - #label))
                    local line = lbl .. " " .. chunk
                    local row = #lines
                    lines[row + 1] = line
                    if ci == 1 then
                        hls[#hls + 1] = { row, 0, #label, "LvimImageDetailLabel" }
                    end
                    hls[#hls + 1] = { row, box, #line, "LvimImageDetailValue" }
                end
            end
            return lines, hls
        end,
    }
end

--- Open the composite viewer for `src`. Returns the surface state handle (with `.close`), or nil on failure.
---@param src string
---@param opts? { details?: boolean, max_width?: integer, max_height?: integer }
---@return table|nil
function M.open(src, opts)
    opts = opts or {}
    local Image = require("lvim-utils.image.image")
    local img = Image.new(src)
    if not (img and img:prepare()) then
        vim.notify("[lvim-utils.image] " .. ((img and img.err) or "cannot open image"), vim.log.levels.ERROR)
        return nil
    end
    ensure_hl()

    -- Cap the image to the configured fraction of the editor, LEAVING room for the details panel + chrome, so
    -- the popup sizes tightly around the image rather than sprawling.
    local max_w = opts.max_width or budget(config.max_width, vim.o.columns, math.floor(vim.o.columns * 0.8)) - 50
    local max_h = opts.max_height or budget(config.max_height, vim.o.lines, math.floor(vim.o.lines * 0.8)) - 4
    local icols, irows = img:cells(math.max(10, max_w), math.max(5, max_h))

    local image_provider = {
        hide_cursor = true,
        size = function()
            return icols, irows
        end,
        update = function(pan, L)
            -- The placement OWNS this buffer; re-issue on every relayout (toggle/resize changes L.width/height).
            if pan._pl then
                pan._pl:close()
            end
            local Placement = require("lvim-utils.image.placement")
            pan._pl =
                Placement.new(img, { buf = pan.buf, win = pan.win, max_w = L.width, max_h = L.height, center = true })
        end,
        on_close = function(pan)
            if pan._pl then
                pan._pl:close()
            end
        end,
    }

    local rows = require("lvim-utils.image").details(src, img)
    local show_details = opts.details ~= false -- details shown by default

    -- Both panels are PLAIN blocks INSIDE the popup, so its auto width includes them. (The `id="preview"` dock
    -- seam places the side panel OUTSIDE the computed width, so it spilled past the popup edge.) Toggling the
    -- details therefore reopens the viewer with/without the details block.
    local blocks = {
        -- Fix the image panel to the image's own width so the popup hugs it (no flex sprawl).
        { id = "image", provider = image_provider, size = { width = { fixed = icols } } },
    }
    if show_details then
        blocks[#blocks + 1] =
            { id = "details", provider = details_provider(rows, irows), size = { width = { fixed = 44 } } }
    end

    local function toggle(st)
        st.close()
        vim.schedule(function()
            M.open(src, vim.tbl_extend("force", opts, { details = not show_details }))
        end)
    end

    return surface.open({
        mode = "float",
        -- The container itself has NO border (title + footer bars span full width). The configured `border`
        -- wraps only the PANEL GROUP (image + details) as a `group_border` — a 1-cell " " gutter left/right by
        -- default — so it works whether or not the details block is present.
        group_border = config.border,
        title = "  " .. vim.fn.fnamemodify(src, ":t"),
        title_pos = "center",
        panel_border = "none",
        size = { width = { auto = true, max = 0.92 }, height = { auto = true, max = 0.9 } },
        content = { blocks = blocks },
        footer = {
            bars = {
                {
                    align = "center",
                    fill = true,
                    items = {
                        { key = "d", name = show_details and "hide info" or "details", run = toggle },
                        {
                            key = "q",
                            name = "close",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
    })
end

return M
