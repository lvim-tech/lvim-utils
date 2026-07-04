-- lvim-utils.image.buf: open an image FILE directly as a buffer. A `BufReadCmd` on image extensions takes
-- over the (binary) file load and instead renders the image full-window, centred, re-fit on resize and torn
-- down on wipe. This is what makes `nvim picture.png` (or `:edit picture.jpg`) show the picture. PNGs pass
-- through; everything else is decoded in memory by image/decode.lua — no temp files.
--
---@module "lvim-utils.image.buf"

local api = vim.api
local config = require("lvim-utils.image.config")

local M = {}

--- `*.ext` patterns (both cases) for every configured format — drives the BufReadCmd registration.
---@return string[]
local function patterns()
    local pats = {}
    for _, e in ipairs(config.formats) do
        pats[#pats + 1] = "*." .. e
        pats[#pats + 1] = "*." .. e:upper()
    end
    return pats
end

--- Render `src` centred + fit into image buffer `buf` shown in `win`. Returns the Placement, or nil on
--- failure (leaving an error line in the buffer).
---@param buf integer
---@param win integer
---@param src string
---@return lvim-utils.image.Placement|nil
local function display(buf, win, src)
    local Image = require("lvim-utils.image.image")
    local img = Image.new(src)
    if not (img and img:prepare()) then
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            { "", "  [lvim-utils.image] " .. ((img and img.err) or "cannot display") }
        )
        vim.bo[buf].modifiable = false
        return nil
    end
    local Placement = require("lvim-utils.image.placement")
    return Placement.new(img, {
        buf = buf,
        win = win,
        max_w = api.nvim_win_get_width(win),
        max_h = api.nvim_win_get_height(win),
        center = true,
    })
end

--- `BufReadCmd` handler: take over an opened image file, mark its buffer a throwaway image scratch, apply the
--- viewer window options, and render — re-fit on resize, cleaned up on wipe.
---@param ev { buf: integer, match: string, file: string }
function M.open(ev)
    local image = require("lvim-utils.image")
    image.setup()
    if not image.supported() then
        return -- no graphics protocol → leave the buffer be
    end
    local buf = ev.buf
    local src = vim.fn.fnamemodify((ev.match ~= "" and ev.match) or ev.file or api.nvim_buf_get_name(buf), ":p")
    local win = api.nvim_get_current_win()

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "lvim-image"
    for _, opt in ipairs({ "number", "relativenumber", "list", "wrap", "cursorline" }) do
        pcall(function()
            vim.wo[win][opt] = false
        end)
    end
    pcall(function()
        vim.wo[win].signcolumn = "no"
    end)
    pcall(function()
        require("lvim-utils.cursor").mark_hide_buffer(buf, true)
    end)

    ---@type lvim-utils.image.Placement|nil
    local pl
    local function render()
        if not (api.nvim_buf_is_valid(buf) and api.nvim_win_is_valid(win)) then
            return
        end
        if pl then
            pl:close()
        end
        pl = display(buf, win, src)
    end
    render()

    local grp = api.nvim_create_augroup("LvimImageBuf_" .. buf, { clear = true })
    api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = grp,
        buffer = buf,
        callback = function()
            vim.schedule(render)
        end,
    })
    api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = grp,
        buffer = buf,
        once = true,
        callback = function()
            if pl then
                pl:close()
            end
        end,
    })
end

--- Register the `BufReadCmd` so opening an image file displays it. Idempotent.
function M.setup()
    api.nvim_create_autocmd("BufReadCmd", {
        group = api.nvim_create_augroup("LvimImageBufReadCmd", { clear = true }),
        pattern = patterns(),
        callback = M.open,
    })
end

return M
