-- lvim-utils.image: display images inside Neovim across ALL terminal graphics protocols (kitty, iTerm2,
-- sixel, ueberzugpp), decoding non-PNG sources to pixels IN MEMORY via libvips — no ImageMagick, no PNG
-- copies written to disk. This is the entry point: config merge + terminal setup, the public API, and a
-- standalone float VIEWER (`show`). Protocol encoders live in image/protocols/*, detection + terminal I/O in
-- image/terminal, sizing in image/util, the Image identity in image/image, and rendering in image/placement.
--
---@module "lvim-utils.image"

local api = vim.api
local config = require("lvim-utils.image.config")
local terminal = require("lvim-utils.image.terminal")
local merge = require("lvim-utils.utils").merge

local M = {}

M.config = config

local did_setup = false

--- Ensure setup ran (so the API works even if the user never called `setup`).
local function ensure()
    if not did_setup then
        M.setup()
    end
end

--- Merge user opts into the live config and initialise terminal detection + tmux passthrough. Safe to call
--- more than once; detection runs only on the first call.
---@param opts? lvim-utils.image.Config
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if not did_setup then
        did_setup = true
        terminal.setup()
        require("lvim-utils.image.buf").setup() -- `nvim picture.png` shows the picture
        api.nvim_create_user_command("LvimImage", function(a)
            M.show(a.args ~= "" and a.args or vim.fn.expand("%:p"))
        end, { nargs = "?", complete = "file", desc = "Show an image in a floating viewer" })
    end
end

--- Render `src` into an EXISTING buffer + window (centred, fit) — the shared entry point for the file-buffer
--- viewer, picker previews, and inline document rendering. Returns the Placement, or nil on failure.
---@param buf integer
---@param win integer
---@param src string
---@param opts? { center?: boolean, max_width?: integer, max_height?: integer }
---@return lvim-utils.image.Placement|nil
function M.attach(buf, win, src, opts)
    ensure()
    opts = opts or {}
    if not (config.enabled and M.supported()) then
        return nil
    end
    local Image = require("lvim-utils.image.image")
    local img = Image.new(src)
    if not (img and img:prepare()) then
        return nil
    end
    local Placement = require("lvim-utils.image.placement")
    return Placement.new(img, {
        buf = buf,
        win = win,
        max_w = opts.max_width or api.nvim_win_get_width(win),
        max_h = opts.max_height or api.nvim_win_get_height(win),
        center = opts.center ~= false,
    })
end

--- Whether `path` is a displayable image (by extension) — for callers (pickers/doc) deciding to use images.
---@param path string
---@return boolean
function M.is_image(path)
    local e = (path:match("%.([%w]+)$") or ""):lower()
    for _, fmt in ipairs(config.formats) do
        if fmt == e then
            return true
        end
    end
    return false
end

--- Human-readable byte size (B / KiB / MiB / GiB).
---@param n integer
---@return string
local function human_size(n)
    local units = { "B", "KiB", "MiB", "GiB" }
    local i, v = 1, n
    while v >= 1024 and i < #units do
        v, i = v / 1024, i + 1
    end
    return (i == 1) and string.format("%d %s", v, units[i]) or string.format("%.1f %s", v, units[i])
end

--- Gather `{ label, value }` rows describing an image for the viewer's DETAILS panel: name, path, type,
--- resolution, file size, modified time, aspect. `img` is an already-prepared Image (for w/h).
---@param src string
---@param img lvim-utils.image.Image
---@return { label: string, value: string }[]
function M.details(src, img)
    local rows = {}
    local function add(label, value)
        rows[#rows + 1] = { label = label, value = value }
    end
    add("Name", vim.fn.fnamemodify(src, ":t"))
    add("Path", src)
    add("Type", (src:match("%.([%w]+)$") or "?"):upper())
    add("Resolution", string.format("%d × %d px", img.w or 0, img.h or 0))
    if img.w and img.h and img.h > 0 then
        add("Aspect", string.format("%.3f : 1", img.w / img.h))
    end
    local st = (vim.uv or vim.loop).fs_stat(src)
    if st then
        add("File size", human_size(st.size))
        add("Modified", os.date("%Y-%m-%d %H:%M", st.mtime.sec))
    end
    add("Protocol", img.protocol)
    return rows
end

--- Whether an image display path exists on this terminal.
---@return boolean
function M.supported()
    ensure()
    return terminal.supported() or config.force
end

--- Open the composite floating VIEWER for `src` — a lvim-utils.ui surface with a border-title (the file
--- name), the image, a toggleable `d` DETAILS side panel, and a `d`/`q` footer bar. Returns the surface
--- state handle (with `.close`), or nil on failure (with a notify).
---@param src string
---@param opts? { details?: boolean, max_width?: integer, max_height?: integer }
---@return table|nil
function M.show(src, opts)
    ensure()
    if not config.enabled then
        return nil
    end
    if not M.supported() then
        vim.notify("[lvim-utils.image] no supported graphics protocol on this terminal", vim.log.levels.WARN)
        return nil
    end
    return require("lvim-utils.image.viewer").open(src, opts)
end

--- `:checkhealth`-style summary of the detected terminal + capabilities.
---@return lvim-utils.image.terminal.State
function M.info()
    ensure()
    return terminal.info()
end

return M
