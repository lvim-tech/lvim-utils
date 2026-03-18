-- lua/lvim-utils/config/highlight.lua
-- Highlight group definitions for lvim-utils UI components.
-- Returns a factory function so callers can re-evaluate with the current palette.

return function()
	local c = require("lvim-utils.colors")
	local hl = require("lvim-utils.highlight")

	local blueBlend = hl.blend(c.blue, c.bg, 0.15)
	local redBlend = hl.blend(c.red, c.bg, 0.15)

	return {
		-- Window chrome
		LvimUiNormal = { bg = c.bg_dark, fg = c.fg },
		LvimUiBorder = { bg = c.bg_dark, fg = c.blue },
		LvimUiSeparator = { fg = c.cyan },

		-- Title block
		LvimUiTitle = { bg = blueBlend, fg = c.blue, bold = true },
		LvimUiSubtitle = { fg = c.orange },
		LvimUiInfo = { fg = c.yellow },

		-- Tab bar
		LvimUiTabActive = { bg = redBlend, fg = c.white },
		LvimUiTabInactive = { bg = c.none, fg = c.red },
		LvimUiTabIconActive = { fg = c.yellow },
		LvimUiTabIconInactive = { fg = c.yellow },
		LvimUiTabTextActive = { fg = c.red },
		LvimUiTabTextInactive = { fg = c.red },

		-- Action bar buttons
		LvimUiButtonActive = { bg = c.bg_light, fg = c.fg },
		LvimUiButtonInactive = { bg = c.bg_soft_dark, fg = c.fg_dim },
		LvimUiButtonIconActive = { fg = c.orange },
		LvimUiButtonIconInactive = { fg = c.fg_dim },
		LvimUiButtonTextActive = { fg = c.fg, bold = true },
		LvimUiButtonTextInactive = { fg = c.fg_dim },

		-- Cursor line
		LvimUiCursorLine = { bg = c.bg },

		-- Tabs rows icon / text
		LvimUiRowIconActive = { fg = c.yellow },
		LvimUiRowIconInactive = { fg = c.yellow },
		LvimUiRowTextActive = { fg = c.yellow, bold = true },
		LvimUiRowTextInactive = { fg = c.fg },

		-- Select / multiselect items
		LvimUiItemIconActive = { fg = c.teal },
		LvimUiItemIconInactive = { fg = c.fg_dim },
		LvimUiItemTextActive = { fg = c.fg },
		LvimUiItemTextInactive = { fg = c.fg_muted },

		-- Multiselect checkboxes
		LvimUiCheckboxSelected = { fg = c.green },
		LvimUiCheckboxEmpty = { fg = c.fg_dim },

		-- Input field
		LvimUiInput = { bg = c.bg_input, fg = c.fg },

		-- Footer hint bar
		LvimUiFooter = { fg = c.blue, bold = true },
		LvimUiFooterKey = { fg = c.blue },
		LvimUiFooterLabel = { fg = c.yellow },

		-- Spacer / divider rows
		LvimUiSpacer = { fg = c.magenta },

		-- Notify toast panel
		LvimNotifyNormal = { bg = c.bg_dark, fg = c.fg },
		LvimNotifyTitle = { fg = c.white, bold = true },
		LvimNotifyInfo = { fg = c.teal },
		LvimNotifyWarn = { fg = c.orange },
		LvimNotifyError = { fg = c.red },
		LvimNotifyDebug = { fg = c.purple },

		-- Notify entry title (per level)
		LvimNotifyTitleInfo = { fg = c.teal, bold = true },
		LvimNotifyTitleWarn = { fg = c.orange, bold = true },
		LvimNotifyTitleError = { fg = c.red, bold = true },
		LvimNotifyTitleDebug = { fg = c.purple, bold = true },

		-- Notify header bars (top stripe, full-line bg)
		LvimNotifyHeaderInfo = { bg = hl.blend(c.teal, c.bg, 0.5), fg = c.white, bold = true },
		LvimNotifyHeaderWarn = { bg = hl.blend(c.orange, c.bg, 0.5), fg = c.white, bold = true },
		LvimNotifyHeaderError = { bg = hl.blend(c.red, c.bg, 0.5), fg = c.white, bold = true },
		LvimNotifyHeaderDebug = { bg = hl.blend(c.purple, c.bg, 0.5), fg = c.white, bold = true },

		-- Notify separator lines (per level)
		LvimNotifySepInfo = { bg = c.bg_dark, fg = hl.blend(c.teal, c.bg, 0.5) },
		LvimNotifySepWarn = { bg = c.bg_dark, fg = hl.blend(c.orange, c.bg, 0.5) },
		LvimNotifySepError = { bg = c.bg_dark, fg = hl.blend(c.red, c.bg, 0.5) },
		LvimNotifySepDebug = { bg = c.bg_dark, fg = hl.blend(c.purple, c.bg, 0.5) },
	}
end
