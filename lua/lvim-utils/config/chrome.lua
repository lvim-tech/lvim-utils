-- lvim-utils.config.chrome: the live config for the editor-chrome components — statusline, winbar, tabline,
-- statuscolumn — and the folded transient finder/echo OVERLAY (ex `config.status`).
--
-- `setup()` merges the user's `chrome = {…}` into this table in place (via lvim-utils.utils.merge); readers
-- `require("lvim-utils.config").chrome` and see the effective values. Every component is independently
-- toggleable; icons + exclusion lists + click handlers are fully configurable. All glyphs are single-width
-- Nerd-font codepoints.
--
---@module "lvim-utils.config.chrome"

-- Nerd-font glyphs are built from their codepoints with nr2char (utf8 = 1) so they survive editing/encoding
-- intact — a literal multibyte glyph can be silently lost in transit; a codepoint cannot. The user can still
-- override any icon with a literal glyph string (utils.merge replaces the value).
---@param cp integer
---@return string
local function nf(cp)
    return vim.fn.nr2char(cp, 1)
end

return {
    -- ── statusline ────────────────────────────────────────────────────────────
    -- The 16-segment bottom line. Each segment can be turned off without touching the others.
    statusline = {
        enabled = true,
        segments = {
            mode = true, -- the vi-mode pill (mode-coloured)
            cwd = true, -- folder + ~-collapsed working directory
            file = true, -- name + devicon + size + readonly/modified flags
            git = true, -- branch + (abbrev) + added/removed/changed line counts
            hunks = true, -- current git-hunk position (N[,M]/Total)
            macro = true, -- macro recording register ([q], only when cmdheight==0)
            diagnostics = true, -- error / warn / info / hint counts
            lsp = true, -- attached LSP servers + EFM linters/formatters
            filetype = true, -- uppercase filetype
            encoding = true, -- file encoding (UTF-8 …)
            fileformat = true, -- line-ending format (unix/dos/mac)
            spell = true, -- active spell language (via lvim-linguistics, optional)
            wordcount = true, -- word count (visual/total in visual mode)
            ruler = true, -- line/total:col percentage
            scrollbar = true, -- single block-char scroll position
        },
    },

    -- ── winbar ────────────────────────────────────────────────────────────────
    -- Per-window top line: terminal label / inactive filename / active filename + breadcrumb.
    winbar = {
        enabled = true,
        breadcrumb = true, -- the nvim-navic code-context trail (optional; needs navic)
    },

    -- ── tabline ───────────────────────────────────────────────────────────────
    -- vim logo · current-tab windows · `%=` · lvim-space tabs · workspace · project.
    tabline = {
        enabled = true,
        lvim_space = true, -- pull tabs/workspace/project from lvim-space.pub (optional)
        showtabline = 2, -- 0 never / 1 when ≥2 tabpages / 2 always
    },

    -- ── statuscolumn ──────────────────────────────────────────────────────────
    -- other-sign · diagnostic-sign · `%=` · line numbers (+marks) · git gutter.
    statuscolumn = {
        enabled = true,
        git_gutter = true, -- the mini.diff-coloured vertical bar (optional; needs mini.diff)
        marks = true, -- substitute a mark letter for the number on marked lines
        -- Click handlers, keyed by a Lua pattern matched against the clicked sign name. Each pcall-guards its
        -- plugin so lvim-utils ships no hard dependency. Override / extend freely.
        handlers = {
            ["Neotest.*"] = function()
                pcall(function()
                    require("neotest").run.run()
                end)
            end,
            ["DiagnosticSign.*"] = function()
                pcall(vim.cmd, "Trouble diagnostics")
            end,
            ["MiniDiffSign.*"] = function()
                pcall(function()
                    require("mini.diff").toggle_overlay()
                end)
            end,
            ["Dap.*"] = function()
                pcall(function()
                    require("dap").continue()
                end)
            end,
        },
        -- Clicking a line number (no sign) — default: toggle a DAP breakpoint.
        number_click = function()
            pcall(function()
                require("dap").toggle_breakpoint()
            end)
        end,
    },

    -- ── transient finder / echo overlay (ex config.status) ──────────────────────
    -- A navigator / the command-line publishes a title + match counter here and the statusline DISPLAYS it,
    -- so the bottom line acts as the echo/info area. Off → each UI draws its own title in place.
    overlay = {
        enabled = true, -- master switch for the echo/info model
        show_action = false, -- show the typed query/command on the left
        show_counter = true, -- show the match counter (current/total) on the right
        icon_pad_left = 1,
        icon_pad_right = 2,
        title_pad_left = 1,
        title_pad_right = 1,
        segment_pad = 1,
    },

    -- ── shared: exclusion lists ─────────────────────────────────────────────────
    -- Buffers/filetypes that should NOT get the normal winbar/statuscolumn (special/tool panels).
    exclude = {
        buftype = { "nofile", "prompt", "help", "terminal" },
        filetype = {
            "snacks_dashboard",
            "alpha",
            "ctrlspace",
            "ctrlspace_help",
            "undotree",
            "diff",
            "Outline",
            "NvimTree",
            "LvimHelper",
            "dashboard",
            "vista",
            "spectre_panel",
            "DiffviewFiles",
            "flutterToolsOutline",
            "log",
            "dapui_scopes",
            "dapui_breakpoints",
            "dapui_stacks",
            "dapui_watches",
            "dapui_console",
            "calendar",
            "neo-tree",
            "neo-tree-popup",
            "noice",
            "toggleterm",
            "git",
            "netrw",
            "dbee",
            "org",
            "fzf",
            "qf",
            "replacer",
        },
    },

    -- ── shared: git poller ──────────────────────────────────────────────────────
    git = {
        poll_ms = 1000, -- .git/HEAD fs_poll interval
    },

    -- ── icons (single-width Nerd-font; override any with a literal glyph) ────────
    icons = {
        vim = nf(0xE62B), -- mode pill leader / tabline logo
        folder = nf(0xF0256), -- cwd
        git = nf(0xF418), -- branch
        commit = nf(0xEAFC), -- hunk position
        separator = nf(0x27A4), -- breadcrumb / sequence separator (➤)
        lock = nf(0xEBE7), -- readonly
        save = nf(0xF0C7), -- modified
        vline = nf(0x258C), -- statuscolumn git gutter bar (▌)
        terminal = nf(0xF489), -- winbar terminal label
        lsp = nf(0xF085), -- lsp/lint/format segment
        unix = nf(0xE712),
        dos = nf(0xE70F),
        mac = nf(0xE711),
        git_status = {
            added = nf(0xF457),
            deleted = nf(0xF458),
            modified = nf(0xF459),
        },
        diagnostics = {
            error = nf(0xF057),
            warn = nf(0xF06A),
            info = nf(0xF05A),
            hint = nf(0xF0335),
            global = nf(0xEAAF),
        },
        -- the 8 scrollbar block chars, tallest (top) → shortest (bottom): █▇▆▅▄▃▂▁
        scrollbar = {
            nf(0x2588),
            nf(0x2587),
            nf(0x2586),
            nf(0x2585),
            nf(0x2584),
            nf(0x2583),
            nf(0x2582),
            nf(0x2581),
        },
    },
}
