-- lua/lvim-utils/config/highlight.lua
-- Highlight group definitions for lvim-utils UI components.
-- Returns a factory function so callers can re-evaluate with the current palette.
--
-- Style (the lvim-keys-helper convention, applied everywhere): the panel is a uniform
-- `bg_dark`; every coloured chrome cell is its OWN accent blended toward that bg — a
-- STRONG tint for the prominent cells (title / name boxes, active tabs/buttons, key
-- badges) and a LIGHT tint for the secondary ones (subtitles, inactive, stripes, labels,
-- separators). List BODY rows stay fg-only — their selection is shown via CursorLine, so
-- a tinted text span there would fight the cursorline. Tints are configurable via ui.tint.

---@param c? table  the live palette (passed by highlight.bind); falls back to a require
return function(c)
	-- Required inside the factory so each rebuild re-reads the live palette/blend helpers.
	c = c or require("lvim-utils.colors")
	local hl = require("lvim-utils.highlight")
	local bg = c.bg_dark

	-- Tint strengths (overridable via ui.tint). On the very first factory call the config
	-- module is still mid-load (ui not set yet) → the defaults below apply; rebuilds pick
	-- up the user's values.
	local ok_cfg, cfg = pcall(require, "lvim-utils.config")
	local tcfg = (ok_cfg and cfg.ui and cfg.ui.tint) or {}
	local STRONG = tcfg.strong or 0.2 -- prominent / active cell
	local BODY = tcfg.body or 0.05 -- secondary / inactive / body
	-- All chrome + notify tints blend toward c.bg (matching the Messages groups LvimUiMsg*) —
	-- same blend base, same colours, so popups and notifications share one look.
	local function mtint(color, t)
		return hl.blend(color, c.bg, t)
	end
	-- Panel background follows the theme's `styles.floats` via the synced `bg_float` (which is
	-- already NONE when transparent, the float "dark" shade, or the editor bg for "normal").
	-- Defaults to bg_dark when unset, so the panel look is unchanged out of the box. Falls back
	-- to the transparent-or-bg_dark rule if no theme has driven bg_float yet.
	local panel_bg = c.bg_float or (c.transparent and c.none or bg)

	return {
		-- Window chrome (the panel itself — uniform bg, no tint)
		-- The whole popup chrome follows the notify look: accent fg over a tint of that same
		-- accent blended toward c.bg (mtint) — STRONG (0.2) for the prominent/active cell,
		-- BODY (0.05) for the secondary/inactive one. Each element keeps its own role colour.
		LvimUiNormal = { bg = panel_bg, fg = c.fg },
		LvimUiBorder = { bg = panel_bg, fg = c.blue },
		LvimUiSeparator = { fg = c.cyan },
		LvimUiCursorLine = { bg = c.bg }, -- active list row (neutral, no tint)
		LvimUiInput = { bg = c.bg_input, fg = c.fg },

		-- Title block (title = STRONG; subtitle / info = BODY). The optional title icon is its
		-- own box: same blue as the title text, with a 0.5 tint (matching the active tab icon).
		LvimUiTitle = { fg = c.blue, bg = mtint(c.blue, STRONG), bold = true },
		LvimUiTitleIcon = { fg = c.blue, bg = mtint(c.blue, 0.5), bold = true },
		LvimUiSubtitle = { fg = c.orange, bg = mtint(c.orange, BODY) },
		LvimUiInfo = { fg = c.yellow, bg = mtint(c.yellow, BODY) },

		-- Tab bar. Icon + text each render as their own YELLOW-tinted box. Active: icon 0.5,
		-- text 0.4 (a solid yellow block). Inactive: lighter (icon 0.3, text 0.2).
		LvimUiTabActive = { fg = c.red, bg = mtint(c.red, STRONG), bold = true },
		LvimUiTabInactive = { fg = c.red, bg = mtint(c.red, BODY) },
		-- Overflow chevrons (hidden tabs) — red with a 0.3 tint, padded 1 space front/back.
		LvimUiTabChevron = { fg = c.red, bg = mtint(c.red, 0.3), bold = true },
		LvimUiTabIconActive = { fg = c.yellow, bg = mtint(c.yellow, 0.5) },
		LvimUiTabIconInactive = { fg = c.yellow, bg = mtint(c.yellow, 0.3) },
		LvimUiTabTextActive = { fg = c.yellow, bg = mtint(c.yellow, 0.4), bold = true },
		LvimUiTabTextInactive = { fg = c.yellow, bg = mtint(c.yellow, 0.2) },

		-- Action bar buttons (active = STRONG, inactive = BODY)
		LvimUiButtonActive = { fg = c.orange, bg = mtint(c.orange, STRONG), bold = true },
		LvimUiButtonInactive = { fg = c.orange, bg = mtint(c.orange, BODY) },
		LvimUiButtonIconActive = { fg = c.orange },
		LvimUiButtonIconInactive = { fg = c.orange },
		LvimUiButtonTextActive = { fg = c.orange, bold = true },
		LvimUiButtonTextInactive = { fg = c.orange },

		-- Tabs rows icon / text (accent fg; the row line tint comes from CursorLine/ItemBody)
		LvimUiRowIconActive = { fg = c.yellow },
		LvimUiRowIconInactive = { fg = c.yellow },
		LvimUiRowItemIconActive = { fg = c.teal },
		LvimUiRowItemIconInactive = { fg = c.teal },
		LvimUiRowTextActive = { fg = c.yellow, bold = true },
		LvimUiRowTextInactive = { fg = c.fg },

		-- Select / multiselect items (clean list — yellow text, active row = yellow + bold)
		LvimUiItemIconActive = { fg = c.yellow },
		LvimUiItemIconInactive = { fg = c.yellow },
		LvimUiItemTextActive = { fg = c.yellow, bold = true },
		LvimUiItemTextInactive = { fg = c.yellow },

		-- Multiselect checkboxes
		LvimUiCheckboxSelected = { fg = c.yellow },
		LvimUiCheckboxEmpty = { fg = c.yellow },

		-- Footer hints. No full-width footer bar (the base has no bg); each badge is its own box:
		-- the key a blue 0.3 tint, the label a yellow 0.2 tint, on the plain panel background.
		LvimUiFooter = { fg = c.blue, bold = true },
		LvimUiFooterKey = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
		LvimUiFooterLabel = { fg = c.yellow, bg = mtint(c.yellow, 0.2) },

		-- Spacer / divider rows
		LvimUiSpacer = { fg = c.magenta },

		-- Disabled row: a value that exists but can't apply in the current context — dimmed +
		-- struck through, so it stays visible but reads as inert. The fg is the comment colour
		-- blended further toward the background: plain `c.comment` is nearly identical to the
		-- INACTIVE row text, so on a non-focused row the dim was invisible — this keeps it
		-- clearly greyer than any normal row, focused or not.
		LvimUiDisabled = { fg = mtint(c.comment, 0.45), strikethrough = true },

		-- Notify panel — matches the Messages groups (LvimUiMsg*) exactly: colours
		-- Error=red, Warn=orange, Info=teal, Debug=purple; tints blended toward c.bg, with
		-- the header/title at 0.2 (the Messages "icon" tint) and the body at 0.1 (its "text"
		-- tint). fg is the level's own accent throughout.
		LvimNotifyNormal = { bg = panel_bg, fg = c.fg },
		LvimNotifyTitle = { fg = c.blue, bold = true },
		LvimNotifyInfo = { fg = c.blue },
		LvimNotifyWarn = { fg = c.orange },
		LvimNotifyError = { fg = c.red },
		LvimNotifyDebug = { fg = c.purple },

		-- Entry title → 0.2 tint
		LvimNotifyTitleInfo = { fg = c.blue, bg = mtint(c.blue, 0.2), bold = true },
		LvimNotifyTitleWarn = { fg = c.orange, bg = mtint(c.orange, 0.2), bold = true },
		LvimNotifyTitleError = { fg = c.red, bg = mtint(c.red, 0.2), bold = true },
		LvimNotifyTitleDebug = { fg = c.purple, bg = mtint(c.purple, 0.2), bold = true },

		-- Header bar (icon + level name) → 0.2 tint
		LvimNotifyHeaderInfo = { fg = c.blue, bg = mtint(c.blue, 0.2), bold = true },
		LvimNotifyHeaderWarn = { fg = c.orange, bg = mtint(c.orange, 0.2), bold = true },
		LvimNotifyHeaderError = { fg = c.red, bg = mtint(c.red, 0.2), bold = true },
		LvimNotifyHeaderDebug = { fg = c.purple, bg = mtint(c.purple, 0.2), bold = true },

		-- Content body (every entry line) → 0.05 tint, fg = the level accent (like Messages text)
		LvimNotifyBodyInfo = { fg = c.blue, bg = mtint(c.blue, 0.05) },
		LvimNotifyBodyWarn = { fg = c.orange, bg = mtint(c.orange, 0.05) },
		LvimNotifyBodyError = { fg = c.red, bg = mtint(c.red, 0.05) },
		LvimNotifyBodyDebug = { fg = c.purple, bg = mtint(c.purple, 0.05) },

		-- Separator lines (soft level-tinted line over the 0.05 body bg)
		LvimNotifySepInfo = { bg = mtint(c.blue, 0.05), fg = mtint(c.blue, 0.5) },
		LvimNotifySepWarn = { bg = mtint(c.orange, 0.05), fg = mtint(c.orange, 0.5) },
		LvimNotifySepError = { bg = mtint(c.red, 0.05), fg = mtint(c.red, 0.5) },
		LvimNotifySepDebug = { bg = mtint(c.purple, 0.05), fg = mtint(c.purple, 0.5) },
	}
end
