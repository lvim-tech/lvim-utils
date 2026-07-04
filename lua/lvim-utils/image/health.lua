-- lvim-utils.image.health: `:checkhealth lvim-utils.image` — reports the resolved terminal, the chosen
-- graphics protocol + capabilities, the measured cell pixel size, the tty write device, and whether libvips
-- (in-memory non-PNG decode) is available, plus the optional external rasterizers.
--
---@module "lvim-utils.image.health"

local M = {}

--- Run the health checks.
function M.check()
    local h = vim.health
    h.start("lvim-utils.image")

    local image = require("lvim-utils.image")
    image.setup()
    local info = image.info()

    if info.term then
        h.ok("terminal: " .. info.term)
    else
        h.warn("terminal: not resolved yet (the XTVERSION reply may still be pending)")
    end
    h.info(
        ("tmux=%s  zellij=%s  ssh=%s  cell=%dx%d px"):format(
            tostring(info.in_tmux),
            tostring(info.in_zellij),
            tostring(info.is_ssh),
            info.cell.w,
            info.cell.h
        )
    )

    local c = info.caps
    local function cap(name, ok)
        if ok then
            h.ok(name .. ": supported")
        else
            h.info(name .. ": not detected")
        end
    end
    cap("kitty", c.kitty)
    cap("iterm2", c.iterm2)
    cap("sixel", c.sixel)
    cap("ueberzug", c.ueberzug)
    if c.placeholders then
        h.ok("kitty unicode placeholders: supported (inline-anchored images)")
    end

    local proto = require("lvim-utils.image.terminal").pick_protocol(image.config.force)
    if proto then
        h.ok("active protocol: " .. proto)
    else
        h.error("no graphics protocol detected — set `force = true` to assume kitty")
    end

    local ok, decode = pcall(require, "lvim-utils.image.decode")
    if ok and decode.available() then
        h.ok("libvips: available (in-memory decode of JPEG/GIF/WEBP/TIFF/SVG/PDF — no temp files)")
    else
        h.warn("libvips: NOT available — only PNG passthrough works; install libvips for other formats")
    end

    for _, b in ipairs({ "gs", "rsvg-convert" }) do
        if vim.fn.executable(b) == 1 then
            h.ok(b .. ": present (used by libvips for PDF/SVG)")
        else
            h.info(b .. ": missing (optional — needed for PDF/SVG via libvips)")
        end
    end
end

return M
