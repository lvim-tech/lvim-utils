-- lua/lvim-utils/config/picker.lua
-- Shared config for the finder (lvim-utils.picker) — applies to EVERY finder (files / grep / buffers / …)
-- so they share one look. EVERYTHING visual is configurable here: the prompt badge content and a `hl`
-- table mapping every element to a highlight group (all overridable). setup() merges user opts in place;
-- readers do `require("lvim-utils.config").picker`.
--
---@module "lvim-utils.config.picker"

return {
    -- The DEFAULT layout for every finder when a call (or `:LvimPicker <finder>`) gives no explicit one:
    -- "area" (the cmdheight/msgarea zone — the modern default) | "float" (a centred float) | "bottom" (a
    -- bottom dock). A per-call `opts.layout` (or a `:LvimPicker <finder> <layout>` arg) overrides it.
    layout = "area",

    -- RENDERER for the heavy, command-driven finders (files / grep / git_files / directories / buffers):
    -- `true` (default) = the real fzf TUI runs inside the finder's list panel (fzf — in C — owns parsing,
    -- matching, ranking AND rendering, so it stays instant and updates CONTINUOUSLY while you type even over
    -- huge trees like ~/ with millions of files); `false` = the Lua tint-striped list (the lvim look, but it
    -- materialises + renders candidates itself, so it is slower at extreme scale). The preview stays a real
    -- Neovim window either way. The STRUCTURED finders (lsp locations / diagnostics / marks / …) always use
    -- the tint list — their data is small and in-memory, so the fzf TUI buys nothing there. Needs `fzf` +
    -- `mkfifo` on PATH; falls back to the tint list automatically when missing.
    fzf_tui = true,

    -- (fzf finders) ALL terminal keys — every one configurable. Editor-side keys (preview scroll, park,
    -- quickfix) are handled by Neovim; the rest pass straight to fzf with its own bindings. The fzf-internal
    -- actions (mark, quickfix-accept) also get the matching fzf `--bind` / `--expect` wiring automatically.
    -- A value may be a single key or a LIST of keys (all bound to that action). "" / {} disables an action.
    keys = {
        accept = "<CR>", -- open / confirm the focused item
        mark = "<Tab>", -- toggle the focused row's mark (multi-select)
        quickfix = "<C-q>", -- send every marked row (or the focused one) to the quickfix list, then close
        preview_down = "<C-d>", -- scroll the preview down
        preview_up = "<C-u>", -- scroll the preview up
        -- PARK: a focus toggle that keeps the finder OPEN. In fzf's input it focuses the editor (the real
        -- buffer) without closing; in the editor (parked) it returns to fzf's input exactly where you left.
        park = "<C-o>",
        abort = { "<Esc>", "<C-c>" }, -- cancel the finder
        nav = { "<C-j>", "<C-k>", "<C-n>", "<C-p>" }, -- passed through to fzf's own up/down navigation
    },

    -- The MARK indicator drawn in the one blank column in front of a marked row (multi-select), in red — both
    -- backends. A small, vertically-centred bullet reads cleanly in that single space.
    marker = "•",

    -- Publish the finder's title + match counter + query to the bottom statusline (lvim-utils.chrome.overlay) for
    -- EVERY docked finder (area/bottom) — diagnostics, buffers, any plugin's picker. false = each finder draws
    -- the title/counter IN its own navigator instead. A per-call `opts.statusline` overrides this global.
    statusline = true,

    -- How the `files` / `directories` finders LIST entries — the engine and what it ignores, so the picker
    -- matches your fd / rg / fzf-lua setup. (The `grep` finder is ripgrep-only and uses its own command.)
    source = {
        -- The listing tool. "auto" = the first available (fd → fdfind → rg → find); or force one of
        -- "fd" | "fdfind" | "rg" | "find". `rg` lists files only (directories fall back to fd/find).
        engine = "auto",
        -- Directory / file names to EXCLUDE entirely (e.g. ".git", ".jj", "node_modules"). Defaults match
        -- fzf-lua (the `.git` + `.jj` VCS dirs).
        exclude = { ".git", ".jj" },
        -- Include dotfiles / dot-directories (fd / rg `--hidden`).
        hidden = true,
        -- Follow symbolic links (fd / rg `--follow`).
        follow = false,
        -- Honour `.gitignore` / `.ignore` / `.fdignore` (the tool default). false = list ignored files too
        -- (fd / rg `--no-ignore`). `find` has no ignore-file support and always lists everything but `exclude`.
        respect_gitignore = true,
        -- Entry types the FILES finder lists (fd `--type`): "f" = files, "l" = symlinks, "x" = executable, …
        -- Defaults to files + symlinks, like fzf-lua. (Ignored by rg / find, which list regular files.)
        file_types = { "f", "l" },
    },

    -- The PROMPT badge shown before the typed query: an icon and/or label (either may be "" — icon only /
    -- text only / icon + text). A per-call `opts.prompt` string overrides it.
    prompt = {
        icon = "➤", -- the leading glyph (the canon pointer; set your own nf glyph via setup, or "" for none)
        label = "", -- optional text after the icon (e.g. "Search"); "" for none
        -- Spacing around the badge (all configurable): `pad_left` before the icon, `icon_gap` between the
        -- icon and the label (only when both are present), `pad_right` after the icon/label (all on the
        -- badge's strong tint), `input_gap` between the badge and the typed text (on the input's light tint).
        pad_left = 1,
        icon_gap = 1,
        pad_right = 1,
        input_gap = 1,
    },

    -- The INPUT CARET — the cursor in the typed-query field, shared by EVERY finder (the fzf-TUI ones and the
    -- tint/lsp ones). `hl` is the highlight group for its COLOUR (the group's `fg` is the bar colour); `shape`
    -- is a `guicursor` shape spec: "ver25" (a 25%-wide vertical bar — the default thin blue line) | "block" |
    -- "hor20" | … The typed TEXT colour is the `hl.input` group's `fg` (below) — change it there.
    caret = {
        hl = "LvimUiPickerCursor",
        shape = "ver25",
    },

    -- Highlight groups for EVERY element — all overridable (and shared by all finders). Swap any to restyle
    -- the whole finder. The INPUT text colour is `input` (its fg); the caret colour is `caret.hl` above.
    hl = {
        prompt = "LvimUiPickerPrompt", -- the icon + label badge (default: blue tint 0.3, bold)
        input = "LvimUiPickerInput", -- the typed-text area (default: blue tint 0.1)
        marker = "LvimUiPickerMarker", -- the multi-select mark dot (default: red)
        separator = "LvimUiPickerSeparator", -- the list↔preview divider (default: a muted grey)
        -- list rows (tint canon — odd blue / even yellow stripes, the selected row a STRONG tint)
        row_odd = "LvimUiMsgAreaRowOdd",
        row_even = "LvimUiMsgAreaRowEven",
        sel_odd = "LvimUiMsgAreaSelOdd",
        sel_even = "LvimUiMsgAreaSelEven",
        match = "LvimUiMsgAreaMatch", -- the fuzzy-matched characters
        -- panel winbars (the lvim-lsp peek look)
        list_title = "LvimUiPeekTitle", -- the list title (single-panel layout)
        list_count = "LvimUiPeekCount", -- the result count
        preview_file = "LvimUiPeekFile", -- the previewed file name
        preview_dir = "LvimUiPickerPreviewDir", -- its directory (muted fg on the winbar bg)
        bar = "LvimUiPeekFileBar", -- the winbar fill / blank prompt row
    },

    -- The preview winbar (the file title bar on the preview panel).
    preview = {
        show_icon = true, -- show the file's devicon before the name (needs nvim-web-devicons)
        dir_pad_left = 1, -- spaces before the path
        dir_pad_right = 1, -- spaces after the path
    },

    -- (area / docked layouts WITH a preview) The area's HEIGHT for each preview-stack direction — shared by
    -- EVERY finder (diagnostics, files, grep, the qf browser …): `horizontal` when the preview sits side-by-side
    -- (left/right), `vertical` when it is stacked (above/below — usually taller so both panels get room). A
    -- value ≤ 1 is a fraction of the screen height; > 1 an absolute row count. `<C-n>` / `<C-p>` rotate the
    -- preview through the four sides live and switch between these two heights. A per-call `opts.preview_heights`
    -- overrides (e.g. the qf browser's `config.browser.height`).
    preview_heights = {
        horizontal = 0.33,
        vertical = 0.66,
    },

    -- Shown when there are NO results — in the list body AND in the preview's winbar (where the file name
    -- would be). A per-call `opts.empty_text` overrides it.
    empty_text = "[no matches]",

    -- The PREVIEW placeholder text — the styled "nothing to preview" bar (LvimUiPeekEmpty) shown when nothing
    -- is focused. Identical across all backends. A per-call `opts.empty_preview` overrides it.
    empty_preview = "Nothing to preview",

    -- Soft-wrap the LIST rows (no "↳" continuation marker) so a match far to the right of a long row stays
    -- visible instead of being truncated off-screen. A per-call `opts.list_wrap` overrides it.
    list_wrap = false,
}
