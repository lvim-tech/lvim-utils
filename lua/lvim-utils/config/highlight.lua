-- lvim-utils.config.highlight: the highlight-group definitions for every lvim-utils UI component. Returns a
-- FACTORY function (not a table) so callers can re-evaluate it against the CURRENT palette on a colorscheme
-- change — the reason it lives here as `return function(c)` rather than a plain config table.
--
-- NOTHING here is a design decision any more: every tint strength and every accent comes from
-- `config/ui.lua` (`lvim-utils.config.ui` — the shared chrome theme spec). This file only says WHICH role
-- each group plays; the spec says what a role looks like. So retuning the chrome is a config edit, never a
-- code edit — and the whole set moves together, because every plugin's chrome is built from this one scale.
--
-- The style it encodes (the lvim-keys-helper convention, applied everywhere): the panel is a uniform
-- `bg_dark`; every coloured chrome cell is its OWN accent blended toward that bg — a STRONG tint for the
-- prominent cells (title / name boxes, active tabs/buttons, key badges) and a BODY tint for the secondary
-- ones (subtitles, inactive, stripes, labels, separators). List BODY rows stay fg-only — their selection is
-- shown via CursorLine, so a tinted text span there would fight the cursorline.
--
---@module "lvim-utils.config.highlight"

---@param c? table  the live palette (passed by highlight.bind); falls back to a require
---@return table<string, table>  map of highlight-group name → its highlight definition
return function(c)
    -- Required inside the factory so each rebuild re-reads the live palette/blend helpers.
    c = c or require("lvim-utils.colors")
    local hl = require("lvim-utils.highlight")
    local bg = c.bg_dark

    -- The theme spec. On the very first factory call the config module may still be mid-load (`ui` not set
    -- yet) → the file's own defaults apply; every rebuild picks up the user's values.
    local ok_cfg, cfg = pcall(require, "lvim-utils.config")
    local ui_cfg = (ok_cfg and cfg.ui) or {}
    local spec = ok_cfg and cfg.ui or require("lvim-utils.config.ui")
    local T = ui_cfg.tint or spec.tint
    local A = ui_cfg.accent or spec.accent

    --- Resolve an accent: a palette KEY ("blue") or a literal "#rrggbb".
    ---@param v string?
    ---@param fallback string
    ---@return string
    local function col(v, fallback)
        v = v or fallback
        if type(v) == "string" and v:sub(1, 1) == "#" then
            return v
        end
        return c[v] or c[fallback] or c.blue
    end

    -- All chrome + notify tints blend toward c.bg (matching the Messages groups LvimUiMsg*) — same blend
    -- base, same colours, so popups and notifications share one look.
    ---@param color string  a resolved hex colour
    ---@param t number      a strength from the tint scale
    local function mtint(color, t)
        return hl.blend(color, c.bg, t)
    end

    -- Panel background follows the theme's `styles.floats` via the synced `bg_float` (already NONE when
    -- transparent, the float "dark" shade, or the editor bg for "normal"); defaults to bg_dark.
    local panel_bg = c.bg_float or (c.transparent and c.none or bg)

    -- Resolved accents (one lookup each, then reused below).
    local a_title = col(A.title, "blue")
    local a_sub = col(A.subtitle, "yellow")
    local a_border = col(A.border, "blue")
    local a_sep = col(A.separator, "red")
    local a_cursor = col(A.cursorline, "blue")
    local a_spacer = col(A.spacer, "magenta")
    local tab = A.tab or {}
    local a_tab, a_tab_icon, a_tab_text = col(tab.box, "red"), col(tab.icon, "blue"), col(tab.text, "yellow")
    local a_btn = col(A.button, "orange")
    local a_row, a_row_icon = col(A.row, "yellow"), col(A.row_icon, "teal")
    local a_item = col(A.item, "yellow")
    local a_path = col(A.path, "blue")
    local ftr = A.footer or {}
    local a_fkey, a_flabel = col(ftr.key, "blue"), col(ftr.label, "yellow")
    local a_fsep, a_fchev = col(ftr.sep, "red"), col(ftr.chevron, "yellow")
    local a_barfill, a_barsep = col(A.bar_fill, "yellow"), col(A.bar_sep, "blue")
    local pk = A.picker or {}
    local pe = A.peek or {}
    local nt = A.notify or {}
    local ma = A.msgarea or {}
    local db = A.dashboard or {}
    local title_cfg = ui_cfg.title or spec.title
    local a_zone = col(title_cfg.accent, "blue")
    local t_zone = title_cfg.tint or T.strong

    --- The four notify/message groups per level share one shape — build them from the accent map.
    ---@param level string  "info"|"warn"|"error"|"debug"
    ---@param fallback string
    ---@return string
    local function nlevel(level, fallback)
        return col(nt[level], fallback)
    end
    local n_info, n_warn = nlevel("info", "blue"), nlevel("warn", "orange")
    local n_err, n_dbg = nlevel("error", "red"), nlevel("debug", "purple")

    return {
        -- ── Window chrome (the panel itself — uniform bg, no tint) ─────────────────────────────────────
        LvimUiNormal = { bg = panel_bg, fg = c.fg },
        LvimUiBorder = { bg = panel_bg, fg = a_border },
        LvimUiSeparator = { fg = a_sep }, -- the ────── divider row between groups in a list/form
        LvimUiCursorLine = { bg = mtint(a_cursor, T.cursorline) }, -- the active list row: the faintest wash in the set
        LvimUiInput = { bg = c.bg_input, fg = c.fg },

        -- ── Title block (title = STRONG; subtitle / info = BODY; the icon is its own box) ──────────────
        LvimUiTitle = { fg = a_title, bg = mtint(a_title, T.strong), bold = true },
        LvimUiTitleIcon = { fg = a_title, bg = mtint(a_title, T.icon), bold = true },
        LvimUiSubtitle = { fg = a_sub, bg = mtint(a_sub, T.body) },
        -- Semantic subtitle variants — fg only (NO bg), one per `type`.
        LvimUiSubtitleInfo = { fg = n_info },
        LvimUiSubtitleWarn = { fg = n_warn },
        LvimUiSubtitleError = { fg = n_err },
        LvimUiInfo = { fg = a_sub, bg = mtint(a_sub, T.body) },

        -- ── Message area (lvim-msgarea): a docked panel — own dark bg + a full-width title bar ─────────
        LvimUiMsgAreaNormal = { fg = c.fg, bg = c.bg_dark },
        LvimUiMsgAreaTitle = { fg = a_zone, bg = mtint(a_zone, t_zone), bold = true },
        LvimUiMsgAreaTitleFill = { bg = mtint(a_zone, t_zone) },
        -- The intercepted completion grid rendered IN the zone (blink stays the engine; we draw it). Striped
        -- by accent: the WHOLE row takes its accent as fg over a BODY tint; the selected cell raises it to
        -- STRONG (+ bold), one solid block. fg and bg share the colour ("fg = the tint").
        LvimUiMsgAreaItem = { fg = c.fg, bg = c.bg_dark },
        LvimUiMsgAreaItemKind = { fg = col(ma.kind, "cyan"), bg = c.bg_dark },
        LvimUiMsgAreaItemSource = { fg = c.comment, bg = c.bg_dark }, -- the right-aligned [source] tag, dim
        LvimUiMsgAreaRowOdd = { fg = col(ma.row_odd, "blue"), bg = mtint(col(ma.row_odd, "blue"), T.body) },
        LvimUiMsgAreaRowEven = { fg = col(ma.row_even, "yellow"), bg = mtint(col(ma.row_even, "yellow"), T.body) },
        LvimUiMsgAreaSelOdd = {
            fg = col(ma.row_odd, "blue"),
            bg = mtint(col(ma.row_odd, "blue"), T.strong),
            bold = true,
        },
        LvimUiMsgAreaSelEven = {
            fg = col(ma.row_even, "yellow"),
            bg = mtint(col(ma.row_even, "yellow"), T.strong),
            bold = true,
        },
        LvimUiMsgAreaMatch = { fg = col(ma.match, "red"), bold = true }, -- the typed query inside an item

        -- ── Picker (the finder prompt + its panes) ─────────────────────────────────────────────────────
        LvimUiPickerPrompt = { fg = col(pk.prompt, "blue"), bg = mtint(col(pk.prompt, "blue"), T.badge), bold = true },
        LvimUiPickerInput = { fg = col(pk.input, "blue"), bg = mtint(col(pk.input, "blue"), T.input) },
        LvimUiPickerCursor = { bg = col(pk.cursor, "blue"), fg = c.bg }, -- the fzf caret (a thin bar via guicursor)
        LvimUiPickerMarker = { fg = col(pk.marker, "red"), bold = true }, -- the multi-select mark dot
        LvimUiPickerSeparator = { fg = col(pk.separator, "red"), bg = panel_bg }, -- the thin divider line
        LvimUiPickerPreviewDir = {
            fg = col(pk.preview_dir, "yellow"),
            bg = mtint(col(pk.preview_dir, "yellow"), T.badge),
        },

        -- ── Start dashboard ───────────────────────────────────────────────────────────────────────────
        LvimUiDashboardHeader = { fg = col(db.header, "green_dark") },
        LvimUiDashboardFooter = { fg = col(db.footer, "red_dark") },
        LvimUiDashboardIcon = { fg = col(db.icon, "red_dark") },
        LvimUiDashboardKey = { fg = col(db.key, "orange") },
        LvimUiDashboardDesc = { fg = col(db.desc, "cyan") },
        LvimUiDashboardTitle = { fg = col(db.title, "green_dark"), bold = true },
        LvimUiDashboardFile = { fg = col(db.file, "red_dark") },
        LvimUiDashboardDir = { fg = col(db.dir, "comment") },
        LvimUiDashboardSpecial = { fg = col(db.special, "purple") },
        LvimUiDashboardNormal = { fg = c.fg, bg = c.bg },
        LvimUiDashboardCursorLine = { bg = mtint(a_cursor, T.separator) },

        -- ── Tab bar (three states per box: inactive · active · hover) ──────────────────────────────────
        LvimUiTabActive = { fg = a_tab, bg = mtint(a_tab, T.strong), bold = true },
        LvimUiTabInactive = { fg = a_tab, bg = mtint(a_tab, T.body) },
        LvimUiTabChevron = { fg = a_tab, bg = mtint(a_tab, T.badge), bold = true },
        LvimUiTabIconActive = { fg = a_tab_icon, bg = mtint(a_tab_icon, T.badge), bold = true },
        LvimUiTabIconInactive = { fg = a_tab_icon, bg = mtint(a_tab_icon, T.strong) },
        LvimUiTabIconHover = { fg = a_tab_icon, bg = mtint(a_tab_icon, T.icon), bold = true },
        LvimUiTabTextActive = { fg = a_tab_text, bg = mtint(a_tab_text, T.bright), bold = true },
        LvimUiTabTextInactive = { fg = a_tab_text, bg = mtint(a_tab_text, T.strong) },
        LvimUiTabTextHover = { fg = a_tab_text, bg = mtint(a_tab_text, T.icon), bold = true },

        -- ── Action-bar buttons (active = STRONG, inactive = BODY) ──────────────────────────────────────
        LvimUiButtonActive = { fg = a_btn, bg = mtint(a_btn, T.strong), bold = true },
        LvimUiButtonInactive = { fg = a_btn, bg = mtint(a_btn, T.body) },
        LvimUiButtonIconActive = { fg = a_btn },
        LvimUiButtonIconInactive = { fg = a_btn },
        LvimUiButtonTextActive = { fg = a_btn, bold = true },
        LvimUiButtonTextInactive = { fg = a_btn },

        -- ── Rows (accent fg; the row's line tint comes from CursorLine) ────────────────────────────────
        LvimUiRowIconActive = { fg = a_row },
        LvimUiRowIconInactive = { fg = a_row },
        LvimUiRowItemIconActive = { fg = a_row_icon },
        LvimUiRowItemIconInactive = { fg = a_row_icon },
        LvimUiRowTextActive = { fg = a_row, bold = true },
        LvimUiRowTextInactive = { fg = c.fg },
        -- A DISABLED row — present but INERT in this context: dimmed + struck through, so it stays visible
        -- and reads as inactive without changing its value.
        LvimUiRowDisabled = { fg = mtint(c.fg, T.row_dim), strikethrough = true },
        -- A file row: the NAME in full accent, the leading path the same hue pulled toward the bg.
        LvimUiPathDim = { fg = mtint(a_path, T.path_dim) },
        LvimUiPathName = { fg = a_path, bold = true },

        -- ── Select / multiselect items ────────────────────────────────────────────────────────────────
        LvimUiItemIconActive = { fg = a_item },
        LvimUiItemIconInactive = { fg = a_item },
        LvimUiItemTextActive = { fg = a_item, bold = true },
        LvimUiItemTextInactive = { fg = a_item },
        LvimUiCheckboxSelected = { fg = a_item },
        LvimUiCheckboxEmpty = { fg = a_item },

        -- ── Footer hints (no full-width bar: each badge is its own box) ────────────────────────────────
        LvimUiFooter = { fg = a_fkey, bold = true },
        LvimUiFooterKey = { fg = a_fkey, bg = mtint(a_fkey, T.badge), bold = true },
        LvimUiFooterLabel = { fg = a_flabel, bg = mtint(a_flabel, T.label) },
        -- HOVER/selected: each part keeps its colour and just deepens.
        LvimUiFooterKeyHover = { fg = a_fkey, bg = mtint(a_fkey, T.icon), bold = true },
        LvimUiFooterLabelHover = { fg = a_flabel, bg = mtint(a_flabel, T.bright) },
        LvimUiFooterChevron = { fg = a_fchev, bold = true },
        -- The legend's part-separator (•) dividing the panel keys from the focused-row keys: its own DEEP
        -- box with a lighter dot, so it pops against the keys/labels around it.
        LvimUiFooterSep = { fg = mtint(a_fsep, T.badge), bg = mtint(a_fsep, T.deep), bold = true },
        LvimUiBarChevron = { fg = mtint(a_fsep, T.badge), bg = mtint(a_fsep, T.deep), bold = true },
        -- The continuous full-width strip under a bar's buttons (they sit on top of it).
        LvimUiBarFill = { bg = mtint(a_barfill, T.bar_fill) },
        LvimUiBarSep = { fg = a_barsep, bg = mtint(a_barsep, T.separator) }, -- the ➤ / ● between bar groups
        LvimUiFrameSel = { bg = mtint(a_barsep, T.strong) }, -- the focused bar-button selection (no-accent fallback)
        -- The BACKDROP veil behind an open surface — pure black; `config.dock.<layout>.backdrop.blend`
        -- (winblend) decides how much shows through, so one group reads as a darken OR a soft dim.
        LvimUiBackdrop = { bg = c.black },

        -- ── Spacers / disabled ────────────────────────────────────────────────────────────────────────
        LvimUiSpacer = { fg = a_spacer },
        -- A value that exists but cannot apply here. `comment` alone is nearly identical to the INACTIVE row
        -- text, so on an unfocused row the dim was invisible — blend it further toward the bg.
        LvimUiDisabled = { fg = mtint(c.comment, T.dim), strikethrough = true },

        -- ── Notify panel (mirrors the message groups exactly) ──────────────────────────────────────────
        LvimNotifyNormal = { bg = panel_bg, fg = c.fg },
        LvimNotifyTitle = { fg = a_title, bold = true },
        LvimNotifyInfo = { fg = n_info },
        LvimNotifyWarn = { fg = n_warn },
        LvimNotifyError = { fg = n_err },
        LvimNotifyDebug = { fg = n_dbg },
        -- entry title + header bar → STRONG; the body → BODY; fg is the level's own accent throughout
        LvimNotifyTitleInfo = { fg = n_info, bg = mtint(n_info, T.strong), bold = true },
        LvimNotifyTitleWarn = { fg = n_warn, bg = mtint(n_warn, T.strong), bold = true },
        LvimNotifyTitleError = { fg = n_err, bg = mtint(n_err, T.strong), bold = true },
        LvimNotifyTitleDebug = { fg = n_dbg, bg = mtint(n_dbg, T.strong), bold = true },
        LvimNotifyHeaderInfo = { fg = n_info, bg = mtint(n_info, T.strong), bold = true },
        LvimNotifyHeaderWarn = { fg = n_warn, bg = mtint(n_warn, T.strong), bold = true },
        LvimNotifyHeaderError = { fg = n_err, bg = mtint(n_err, T.strong), bold = true },
        LvimNotifyHeaderDebug = { fg = n_dbg, bg = mtint(n_dbg, T.strong), bold = true },
        LvimNotifyBodyInfo = { fg = n_info, bg = mtint(n_info, T.body) },
        LvimNotifyBodyWarn = { fg = n_warn, bg = mtint(n_warn, T.body) },
        LvimNotifyBodyError = { fg = n_err, bg = mtint(n_err, T.body) },
        LvimNotifyBodyDebug = { fg = n_dbg, bg = mtint(n_dbg, T.body) },
        LvimNotifySepInfo = { bg = mtint(n_info, T.body), fg = mtint(n_info, T.icon) },
        LvimNotifySepWarn = { bg = mtint(n_warn, T.body), fg = mtint(n_warn, T.icon) },
        LvimNotifySepError = { bg = mtint(n_err, T.body), fg = mtint(n_err, T.icon) },
        LvimNotifySepDebug = { bg = mtint(n_dbg, T.body), fg = mtint(n_dbg, T.icon) },

        -- ── Peek (the two-pane location navigator) — a flatter, glance-like look: the only tinted cells are
        -- the title + the winbars; the list itself is fg-only (its selection is the cursorline).
        LvimUiPeekNormal = { bg = panel_bg, fg = c.fg },
        LvimUiPeekBorder = { bg = panel_bg, fg = col(pe.title, "blue") },
        LvimUiPeekTitle = { fg = col(pe.title, "blue"), bg = mtint(col(pe.title, "blue"), T.strong), bold = true },
        LvimUiPeekTitleIcon = { fg = col(pe.icon, "blue"), bg = mtint(col(pe.icon, "blue"), T.bright), bold = true },
        LvimUiPeekCounter = { fg = col(pe.count, "green"), bg = mtint(col(pe.count, "green"), T.badge), bold = true },
        LvimUiPeekKindBar = { fg = col(pe.kind, "green"), bg = mtint(col(pe.kind, "green"), T.badge) },
        LvimUiPeekKind = { fg = col(pe.kind, "green"), bg = mtint(col(pe.kind, "green"), T.bright), bold = true },
        LvimUiPeekFileBar = { fg = col(pe.file, "yellow"), bg = mtint(col(pe.file, "yellow"), T.badge) },
        LvimUiPeekFile = { fg = col(pe.file, "yellow"), bg = mtint(col(pe.file, "yellow"), T.bright), bold = true },
        LvimUiPeekEmpty = { fg = col(pe.file, "yellow"), bg = mtint(col(pe.file, "yellow"), T.badge), bold = true },
        LvimUiPeekFileIcon = {
            fg = col(pe.file, "yellow"),
            bg = mtint(col(pe.file, "yellow"), T.bright),
            bold = true,
        },
        LvimUiPeekGroup = { fg = col(pe.kind, "green"), bold = true }, -- the file NAME (tail)
        LvimUiPeekGroupIcon = { fg = a_sep }, -- the ▸/▾ fold arrows
        LvimUiPeekDir = { fg = col(pe.file, "yellow") }, -- the file PATH (dir)
        LvimUiPeekCount = { fg = c.comment },
        LvimUiPeekText = { fg = c.fg },
        LvimUiPeekGuide = { fg = c.comment },
        LvimUiPeekCursorLine = { fg = col(pe.file, "yellow"), bg = mtint(a_cursor, T.cursorline) },
        LvimUiPeekMatch = { fg = col(pe.match, "blue"), bg = mtint(col(pe.match, "blue"), T.match), bold = true },
        LvimUiPeekFooterKey = { fg = a_fkey, bg = mtint(a_fkey, T.badge), bold = true },
        LvimUiPeekFooterLabel = { fg = a_flabel, bg = mtint(a_flabel, T.label) },
        LvimUiPeekFooterKeyHover = { fg = a_fkey, bg = mtint(a_fkey, T.icon), bold = true },
        LvimUiPeekFooterLabelHover = { fg = a_flabel, bg = mtint(a_flabel, T.bright) },
        -- The filter bar: fg-only, no background. Active = the full accent (bold); inactive = the same
        -- accent kept mostly intact (`tint.filter_off`) so it stays readable.
        LvimUiPeekFilterActive = { fg = col(pe.filter, "green"), bold = true },
        LvimUiPeekFilterInactive = { fg = mtint(col(pe.filter, "green"), T.filter_off) },
        LvimUiPeekFilterSep = { fg = a_flabel }, -- the ● separator before/between filter groups
        -- The keyboard selection drawn OVER a focused bar button (bg-only, so the button keeps its fg).
        LvimUiPeekFilterSelected = { bg = mtint(c.fg, T.selection), bold = true },
        LvimUiPeekHover = { bg = mtint(c.fg, T.hover) }, -- a mouse hover — clearly weaker than the selection
        LvimUiPeekFilterChevron = { fg = a_fchev, bold = true },
        LvimUiPeekFooterChevron = { fg = a_fchev, bold = true },
    }
end
