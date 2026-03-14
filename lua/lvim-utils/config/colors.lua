-- lua/lvim-utils/config/colors.lua
-- Default hex colors for all LvimUi* highlight groups.

local highlight = require("lvim-utils.highlight")

-- ── palette ────────────────────────────────────────────────────────────────────
local none = "NONE"
local white = "#ffffff"

local bg_base = "#21262b"
local bg_dark = "#2c3339"
local bg_light = "#374047"

local fg = "#5a6158"

local red = "#cb4f4f"
local orange = "#cc7942"
local yellow = "#af9e6b"
local green = "#75783a"
local teal = "#357b6d"
local cyan = "#527a57"
local blue = "#42728b"
-- local magenta = "#bb755e"
local purple = "#635d71"

local blueBlend = highlight.blend(blue, bg_dark, 0.15)
local redBlend = highlight.blend(red, bg_dark, 0.15)

-- ── group definitions ─────────────────────────────────────────────────────────



return {
	-- Window chrome
	LvimUiNormal = { bg = bg_base, fg = fg },
	LvimUiBorder = { bg = bg_base, fg = blue },
	LvimUiSeparator = { fg = purple },

	-- Title block
	LvimUiTitle = { bg = blueBlend, fg = blue, bold = true },
	LvimUiSubtitle = { fg = orange },
	LvimUiInfo = { fg = yellow },

	-- Tab bar
	LvimUiTabActive = { bg = redBlend, fg = white },
	LvimUiTabInactive = { bg = none, fg = red },
	LvimUiTabIconActive = { fg = yellow },
	LvimUiTabIconInactive = { fg = yellow },
	LvimUiTabTextActive = { fg = red },
	LvimUiTabTextInactive = { fg = red },

	-- Action bar buttons
	LvimUiButtonActive = { bg = bg_light, fg = fg },
	LvimUiButtonInactive = { bg = bg_base, fg = "#50574e" },
	LvimUiButtonIconActive = { fg = orange },
	LvimUiButtonIconInactive = { fg = "#50574e" },
	LvimUiButtonTextActive = { fg = fg, bold = true },
	LvimUiButtonTextInactive = { fg = "#50574e" },

	-- Cursor line
	LvimUiCursorLine = { bg = bg_dark },

	-- Tabs rows icon / text
	LvimUiRowIconActive    = { fg = yellow },
	LvimUiRowIconInactive  = { fg = yellow },
	LvimUiRowTextActive    = { fg = yellow, bold = true },
	LvimUiRowTextInactive  = { fg = fg },

	-- Select / multiselect items
	LvimUiItemIconActive = { fg = teal },
	LvimUiItemIconInactive = { fg = "#50574e" },
	LvimUiItemTextActive = { fg = fg },
	LvimUiItemTextInactive = { fg = "#565c53" },

	-- Multiselect checkboxes
	LvimUiCheckboxSelected = { fg = green },
	LvimUiCheckboxEmpty = { fg = "#50574e" },

	-- Input field
	LvimUiInput = { bg = "#272e33", fg = fg },

	-- Footer hint bar
	LvimUiFooter = { fg = blue, bold = true },
	LvimUiFooterKey = { fg = blue },
	LvimUiFooterLabel = { fg = yellow },

	-- Spacer / divider rows
	LvimUiSpacer = { fg = cyan },
}
