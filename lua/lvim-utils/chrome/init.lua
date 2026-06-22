-- lvim-utils.chrome: the editor-chrome family — statusline, winbar, tabline, statuscolumn — plus the folded
-- transient finder/echo overlay. One `setup()` registers all four as `%!`-evaluated expressions, self-themes
-- the `LvimUiChrome*` groups from the live palette, starts the shared git poller, and installs the redraw +
-- per-window autocmds. Each component is independently toggleable via `config.chrome`.
--
---@module "lvim-utils.chrome"

local api = vim.api
local parts = require("lvim-utils.chrome.parts")
local git = require("lvim-utils.chrome.git")

local M = {}

M.statusline = require("lvim-utils.chrome.statusline")
M.winbar = require("lvim-utils.chrome.winbar")
M.tabline = require("lvim-utils.chrome.tabline")
M.statuscolumn = require("lvim-utils.chrome.statuscolumn")
M.overlay = require("lvim-utils.chrome.overlay")

local STATUSLINE = "%!v:lua.require'lvim-utils.chrome.statusline'.render()"
local WINBAR = "%!v:lua.require'lvim-utils.chrome.winbar'.render()"
local TABLINE = "%!v:lua.require'lvim-utils.chrome.tabline'.render()"
local STATUSCOLUMN = "%!v:lua.require'lvim-utils.chrome.statuscolumn'.render()"

--- The `LvimUiChrome*` highlight groups, recomputed from the live palette (bound on setup, re-applied on
--- theme change). Accent fg groups sit on the bar bg; mode pills + tab cells are bg-coloured.
---@param colors? table
---@return table<string, table>
local function build(colors)
    local c = colors or require("lvim-utils.colors")
    local bg = c.bg_dark
    local pill_fg = (vim.o.background == "dark") and c.bg or c.fg
    local g = {}
    -- accent fg groups (bold), on the bar bg
    local accents = {
        Blue = c.blue,
        Green = c.green,
        Orange = c.orange,
        Cyan = c.cyan,
        Red = c.red,
        Purple = c.purple,
        Yellow = c.yellow,
    }
    for suffix, col in pairs(accents) do
        g["LvimUiChrome" .. suffix] = { fg = col, bg = bg, bold = true }
    end
    g.LvimUiChromeMark = { fg = c.blue } -- statuscolumn mark letter (NO bg → inherits the gutter's own bg)
    -- the bar FILL: a bar-bg group the statusline/tabline wrap their `%=` gap in, so the empty middle stays
    -- bar-coloured (our own group → the colorscheme never overrides it, unlike the global StatusLine group)
    g.LvimUiChromeFill = { fg = c.fg, bg = bg }
    -- mode pills (bg-coloured)
    g.LvimUiChromeModeN = { bg = c.green, fg = pill_fg, bold = true }
    g.LvimUiChromeModeI = { bg = c.red, fg = pill_fg, bold = true }
    g.LvimUiChromeModeV = { bg = c.orange, fg = pill_fg, bold = true }
    g.LvimUiChromeModeC = { bg = c.purple, fg = pill_fg, bold = true }
    g.LvimUiChromeModeR = { bg = c.cyan, fg = pill_fg, bold = true }
    g.LvimUiChromeModeT = { bg = c.blue, fg = pill_fg, bold = true }
    -- git diff counts
    g.LvimUiChromeGitAdd = { fg = c.git.add, bg = bg }
    g.LvimUiChromeGitChange = { fg = c.git.change, bg = bg }
    g.LvimUiChromeGitDelete = { fg = c.git.delete, bg = bg }
    -- diagnostics
    g.LvimUiChromeDiagError = { fg = c.red, bg = bg }
    g.LvimUiChromeDiagWarn = { fg = c.yellow, bg = bg }
    g.LvimUiChromeDiagInfo = { fg = c.blue, bg = bg }
    g.LvimUiChromeDiagHint = { fg = c.cyan, bg = bg }
    -- tabline cells
    g.LvimUiChromeTabLogo = { bg = c.green, fg = bg, bold = true }
    g.LvimUiChromeTabActive = { bg = c.green, fg = bg, bold = true }
    g.LvimUiChromeTabInactive = { bg = bg, fg = c.green, bold = true }
    g.LvimUiChromeTabWorkspace = { bg = c.orange, fg = bg, bold = true }
    g.LvimUiChromeTabProject = { bg = c.red, fg = bg, bold = true }
    return g
end

--- Force the standard bar groups to the bar bg so the un-highlighted gaps (`%=`, padding) match the segments.
--- `define` always applies (overrides the colorscheme); re-run on ColorScheme.
local function force_bars()
    local c = require("lvim-utils.colors")
    local hl = require("lvim-utils.highlight")
    local bg = c.bg_dark
    hl.define("StatusLine", { bg = bg, fg = c.fg })
    hl.define("StatusLineNC", { bg = bg, fg = c.fg_dim })
    hl.define("WinBar", { bg = bg, fg = c.fg })
    hl.define("WinBarNC", { bg = bg, fg = c.fg_dim })
    hl.define("TabLine", { bg = bg, fg = c.green })
    hl.define("TabLineFill", { bg = bg })
    hl.define("TabLineSel", { bg = c.green, fg = bg, bold = true })
    -- NOTE: the statuscolumn gutter is intentionally NOT forced here — it inherits the colorscheme's own
    -- (dimmed) LineNr / SignColumn / CursorLineNr background, so the gutter stays uniform AND dimmed like
    -- before. The statuscolumn cells use native (no-bg) groups to keep that one continuous gutter bg.
end

--- Apply (or clear) the winbar + statuscolumn for one window, honouring the exclusion lists.
---@param win integer
local function apply_window(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local cfg = require("lvim-utils.config").chrome
    local buf = api.nvim_win_get_buf(win)
    local excluded = parts.excluded(buf) or api.nvim_win_get_config(win).relative ~= ""
    -- only assign when the value actually changes — re-setting a window option forces a redraw, so a guard
    -- here avoids needless flicker on every WinEnter.
    if cfg.winbar.enabled then
        local target = (not excluded) and WINBAR or ""
        if vim.wo[win].winbar ~= target then
            vim.wo[win].winbar = target
        end
    end
    if cfg.statuscolumn.enabled then
        local target = (not excluded) and STATUSCOLUMN or ""
        if vim.wo[win].statuscolumn ~= target then
            vim.wo[win].statuscolumn = target
        end
    end
end

--- Configure and activate the chrome components from `config.chrome`.
function M.setup()
    local cfg = require("lvim-utils.config").chrome
    local hl = require("lvim-utils.highlight")

    -- theming
    hl.bind(build) -- the LvimUiChrome* groups (auto re-applied on theme change)
    force_bars()

    local grp = api.nvim_create_augroup("LvimUiChrome", { clear = true })
    api.nvim_create_autocmd("ColorScheme", { group = grp, callback = force_bars })

    -- `showtabline` for the CURRENT buffer: 0 on excluded buffers (the start dashboard etc.), the configured
    -- value otherwise — so chrome never paints the tabline over the dashboard.
    local function apply_tabline()
        if not cfg.tabline.enabled then
            return
        end
        local target = parts.excluded(api.nvim_get_current_buf()) and 0 or (cfg.tabline.showtabline or 2)
        if vim.o.showtabline ~= target then
            vim.o.showtabline = target
        end
    end

    -- the EXPENSIVE LSP segment is recomputed + cached only when it can change (clients / buffer / filetype)
    api.nvim_create_autocmd({ "LspAttach", "LspDetach", "BufWinEnter", "FileType" }, {
        group = grp,
        callback = function(args)
            M.statusline.refresh_lsp(args.buf)
            pcall(vim.cmd, "redrawstatus")
        end,
    })
    api.nvim_create_autocmd("BufWipeout", {
        group = grp,
        callback = function(args)
            M.statusline.forget(args.buf)
        end,
    })

    -- cheap statusline nudges ONLY for events Neovim does not auto-redraw the line for (mode pill / diagnostic
    -- counts / macro). Cursor-move + buffer-switch redraws are native — forcing them caused the flicker.
    api.nvim_create_autocmd(
        { "ModeChanged", "CmdlineEnter", "CmdlineLeave", "DiagnosticChanged", "RecordingEnter", "RecordingLeave" },
        {
            group = grp,
            callback = function()
                pcall(vim.cmd, "redrawstatus")
            end,
        }
    )

    -- per-window winbar/statuscolumn + tabline state + the float guard. `redrawtabline` keeps the active-window
    -- highlight + the window/tab list current on focus/buffer/tab/close changes (it is otherwise stale).
    api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "FileType", "WinNew", "WinClosed", "TabEnter", "TabClosed" }, {
        group = grp,
        callback = function()
            M.statusline.track_window()
            apply_window(api.nvim_get_current_win())
            apply_tabline()
            pcall(vim.cmd, "redrawtabline")
        end,
    })

    api.nvim_create_autocmd("DirChanged", {
        group = grp,
        callback = function()
            git.start((cfg.git or {}).poll_ms or 1000)
        end,
    })

    -- Paint the actual lines on VimEnter — AFTER the start dashboard (snacks sets laststatus/showtabline = 0)
    -- and other startup UIs have loaded — so chrome never briefly flashes a statusline/tabline over them. If
    -- VimEnter already fired (a live re-setup), activate immediately.
    local function activate()
        git.start((cfg.git or {}).poll_ms or 1000)
        if cfg.statusline.enabled then
            vim.o.statusline = STATUSLINE
        end
        if cfg.tabline.enabled then
            vim.o.tabline = TABLINE
        end
        M.statusline.track_window()
        for _, win in ipairs(api.nvim_list_wins()) do
            apply_window(win)
        end
        apply_tabline()
    end
    if vim.v.vim_did_enter == 1 then
        activate()
    else
        api.nvim_create_autocmd("VimEnter", { group = grp, once = true, callback = activate })
    end
end

return M
