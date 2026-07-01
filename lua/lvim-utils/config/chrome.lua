-- lvim-utils.config.chrome: the live config for the editor-chrome components — statusline, winbar, tabline,
-- statuscolumn — and the folded transient finder/echo OVERLAY (ex `config.status`).
--
-- `setup()` merges the user's `chrome = {…}` into this table in place (via lvim-utils.utils.merge); readers
-- `require("lvim-utils.config").chrome` and see the effective values. Every component is independently
-- toggleable; icons + exclusion lists + click handlers are fully configurable. All glyphs are single-width
-- Nerd-font codepoints.
--
---@module "lvim-utils.config.chrome"

-- Per-COMPONENT exclusion defaults. Each of the four components (statusline / winbar / tabline / statuscolumn)
-- carries its OWN `exclude = { buftype, filetype }` blacklist, so they can be tuned independently (8 lists in
-- all). This returns a FRESH copy each call so the four don't share a table. `extra_ft` appends component-
-- specific filetypes. A buffer whose `buftype` OR `filetype` is listed gets NO chrome for that component — the
-- start dashboard (`lvim-dashboard`, a `nofile` scratch), tool panels, terminals, etc.
---@param extra_ft? string[]
---@return { buftype: string[], filetype: string[] }
local function chrome_exclude(extra_ft)
    local filetype = {
        "lvim-dashboard", -- the lvim-utils start dashboard
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
    }
    for _, ft in ipairs(extra_ft or {}) do
        filetype[#filetype + 1] = ft
    end
    return {
        buftype = { "nofile", "prompt", "help", "terminal" },
        filetype = filetype,
    }
end

return {
    -- ── statusline ────────────────────────────────────────────────────────────
    -- The bottom line, rendered by lvim-utils.chrome.engine. There are NO predefined segments (like heirline) —
    -- YOU define them all in your config. `segments` is a LIST of specs, OR a FUNCTION returning one (resolved
    -- lazily at render time, so no eager require). Each spec:
    --   { name, content = fn(ctx) -> str, hl?, when?, events?, click?, buf?, align? }   (see chrome.engine)
    -- Compose from the helpers — chrome.parts (seg / icons / devicon), chrome.utils, chrome.git. Unset / empty
    -- ⇒ a blank line.
    statusline = {
        enabled = true,
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (no statusline on these buffers).
        exclude = chrome_exclude(),
    },

    -- ── winbar ────────────────────────────────────────────────────────────────
    -- Per-window top line: terminal label / inactive filename / active filename + breadcrumb.
    winbar = {
        enabled = true,
        -- The per-window top line, rendered by lvim-utils.chrome.engine. NO predefined sections (like heirline)
        -- — YOU define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one; each
        -- section's `content = fn(ctx)` gets ctx = { buf, win, active } and gates with `when`. Compose from
        -- chrome.parts (devicon / unique_name / seg / icons) + chrome.utils. Unset ⇒ a blank winbar.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (no winbar on these buffers).
        exclude = chrome_exclude(),
    },

    -- ── tabline ───────────────────────────────────────────────────────────────
    -- vim logo · current-tab windows · `%=` · lvim-space tabs · workspace · project.
    tabline = {
        enabled = true,
        showtabline = 2, -- 0 never / 1 when ≥2 tabpages / 2 always
        -- The top tabline, rendered by lvim-utils.chrome.engine. NO predefined sections (like heirline) — YOU
        -- define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one. Compose from
        -- chrome.parts (seg / icons / excluded / unique_name) + `engine.click_region(key, fn, text)` for
        -- clickable window / tab CELLS (tabby's functionality). Unset ⇒ a blank tabline.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (tabline hidden when the tab holds only these).
        exclude = chrome_exclude(),
    },

    -- ── statuscolumn ──────────────────────────────────────────────────────────
    -- other-sign · diagnostic-sign · `%=` · line numbers (+marks) · git gutter.
    statuscolumn = {
        enabled = true,
        -- The per-line gutter, rendered by lvim-utils.chrome.engine. NO predefined sections (like heirline) —
        -- YOU define them in your config. `segments` = a LIST of specs, OR a FUNCTION returning one; each
        -- section's `content = fn(ctx)` gets ctx = { buf, win, lnum, relnum, virtnum }. Compose from
        -- chrome.gutter (signs / diag_icon / mark_letter / sign_at_mouse) + chrome.parts. Unset ⇒ blank gutter.
        ---@type LvimChromeSegment[]|fun(): LvimChromeSegment[]|nil
        segments = nil,
        -- this component's OWN buftype/filetype blacklist (no statuscolumn gutter on these buffers).
        exclude = chrome_exclude(),
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

    -- ── shared: git poller ──────────────────────────────────────────────────────
    git = {
        poll_ms = 1000, -- .git/HEAD fs_poll interval
    },

    -- ── icons (single-width Nerd-font; override any with a literal glyph) ────────
    icons = {
        vim = "", -- mode pill leader / tabline logo
        folder = "󰉖", -- cwd
        git = "", -- branch
        commit = "", -- hunk position
        separator = "➤", -- breadcrumb / sequence separator (➤)
        lock = "", -- readonly
        save = "", -- modified
        vline = "▌", -- statuscolumn git gutter bar (▌)
        terminal = "", -- winbar terminal label
        lsp = "", -- lsp/lint/format segment
        unix = "",
        dos = "",
        mac = "",
        git_status = {
            added = "",
            deleted = "",
            modified = "",
        },
        diagnostics = {
            error = "",
            warn = "",
            info = "",
            hint = "󰌵",
            global = "",
        },
        -- the 8 scrollbar block chars, tallest (top) → shortest (bottom): █▇▆▅▄▃▂▁
        scrollbar = {
            "█",
            "▇",
            "▆",
            "▅",
            "▄",
            "▃",
            "▂",
            "▁",
        },
    },
}
