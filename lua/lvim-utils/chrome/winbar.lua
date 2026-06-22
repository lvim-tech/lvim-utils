-- lvim-utils.chrome.winbar: the per-window top line, a `%!`-evaluated expression with three branches
-- (first match wins):
--   1. terminal buffers → filetype label + process name;
--   2. inactive windows → devicon + unique filename;
--   3. active windows   → devicon + unique filename + nvim-navic breadcrumb.
--
-- The drawn window is read from `vim.g.statusline_winid` (set by Neovim during winbar evaluation). The unique
-- filename comes from `parts.unique_name` (no tabby dependency). The breadcrumb is visual (per-kind colours
-- from the navic-kind → treesitter-group map); navic is pcall-guarded and optional via config.
--
---@module "lvim-utils.chrome.winbar"

local api = vim.api
local parts = require("lvim-utils.chrome.parts")

local M = {}

--- navic symbol kind → treesitter highlight group (ported 1:1 from the user's hl.winbar)
---@type table<string, string>
local NAVIC_HL = {
    File = "Directory",
    Module = "@include",
    Namespace = "@namespace",
    Package = "@include",
    Class = "@structure",
    Method = "@method",
    Property = "@property",
    Field = "@field",
    Constructor = "@constructor",
    Enum = "@field",
    Interface = "@type",
    Function = "@function",
    Variable = "@variable",
    Constant = "@constant",
    String = "@string",
    Number = "@number",
    Boolean = "@boolean",
    Array = "@field",
    Object = "@type",
    Key = "@keyword",
    Null = "@comment",
    EnumMember = "@field",
    Struct = "@structure",
    Event = "@keyword",
    Operator = "@operator",
    TypeParameter = "@type",
}

---@return string  the bar background hex (for inline devicon groups)
local function bar_bg()
    return require("lvim-utils.colors").bg_dark
end

--- devicon + unique filename for `win`/`buf`.
---@param win integer
---@param buf integer
---@return string
local function file_icon_name(win, buf)
    local out = {}
    local icon, grp = parts.devicon(buf, bar_bg())
    if icon then
        out[#out + 1] = ("%%#%s# %s %%*"):format(grp, icon)
    end
    out[#out + 1] = parts.seg("Red", parts.unique_name(win) .. "  ")
    return table.concat(out)
end

--- The nvim-navic breadcrumb trail for `win` (visual, per-kind coloured). "" when navic is unavailable.
---@param win integer
---@return string
local function breadcrumb(win)
    local ok, navic = pcall(require, "nvim-navic")
    if not (ok and navic.is_available()) then
        return ""
    end
    local ok_data, data = pcall(navic.get_data, win)
    if not ok_data or not data then
        return ""
    end
    local sep = parts.seg("Blue", " " .. parts.icons().separator .. " ")
    local out = {}
    for i, d in ipairs(data) do
        local ts = NAVIC_HL[d.type] or "@variable"
        local name = (d.name or ""):gsub("%%", "%%%%"):gsub("%s*->%s*", "")
        out[#out + 1] = ("%%#%s#%s %s%%*"):format(ts, d.icon or "", name)
        if i < #data then
            out[#out + 1] = sep
        end
    end
    return table.concat(out)
end

--- The `%!`-evaluated winbar string for the window being drawn.
---@return string
function M.render()
    local win = vim.g.statusline_winid
    if win == nil or win == 0 or not api.nvim_win_is_valid(win) then
        win = api.nvim_get_current_win()
    end
    local buf = api.nvim_win_get_buf(win)

    -- branch 1: terminal
    if vim.bo[buf].buftype == "terminal" then
        local ic = parts.icons()
        local ft = vim.bo[buf].filetype
        local label = ft ~= "" and parts.seg("Blue", "  " .. ft:upper() .. " ") or ""
        local pname = api.nvim_buf_get_name(buf):gsub(".*:", "")
        return label .. parts.seg("Red", ic.terminal .. pname)
    end

    -- branch 2 / 3
    local s = file_icon_name(win, buf)
    local active = win == api.nvim_get_current_win()
    if active and (require("lvim-utils.config").chrome.winbar or {}).breadcrumb ~= false then
        s = s .. breadcrumb(win)
    end
    return s
end

return M
