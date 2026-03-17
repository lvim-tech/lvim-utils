-- lua/lvim-utils/colors/init.lua
-- Public color palette for lvim-utils and external plugins.
--
-- Usage:
--   local c = require("lvim-utils.colors")
--   c.red        -- "#cb4f4f"
--   c.bg_light   -- "#2c3339"
--   c.git.add    -- "#5f7240"
--   c.blend(c.teal, c.bg, 0.3)
--
-- Override via setup():
--   require("lvim-utils").setup({ colors = { red = "#ff0000" } })

local M = {}

local hl = require("lvim-utils.highlight")

-- ── default palette ───────────────────────────────────────────────────────

local _p = {
	-- special
	none  = "NONE",
	black = "#000000",
	white = "#ffffff",

	-- backgrounds (light → dark)
	bg_light      = "#2c3339",
	bg_soft_light = "#272e33",
	bg            = "#23292d",
	bg_soft_dark  = "#1f2427",
	bg_dark       = "#1a1f21",
	bg_highlight  = "#455156",

	-- foregrounds (light → dark)
	fg_light     = "#646c62",
	fg_soft_light = "#5f675d",
	fg            = "#5a6158",
	fg_soft_dark  = "#555c53",
	fg_dark       = "#50574e",

	-- comment
	comment = "#565c53",

	-- terminal
	terminal_bg = "#7a8478",

	-- accent colors
	blue         = "#42728b",
	blue_dark    = "#3a6479",
	green        = "#75783a",
	green_dark   = "#656831",
	cyan         = "#527a57",
	cyan_dark    = "#486b4c",
	magenta      = "#bb755e",
	magenta_dark = "#b3664c",
	orange       = "#cc7942",
	orange_dark  = "#b86d3c",
	yellow       = "#af9e6b",
	yellow_dark  = "#a6935a",
	purple       = "#635d71",
	purple_dark  = "#575163",
	red          = "#cb4f4f",
	red_dark     = "#c53b3b",
	teal         = "#357b6d",
	teal_dark    = "#2d695d",

	-- git
	git = {
		add           = "#5f7240",
		change        = "#bf954a",
		delete        = "#ce5f57",
		change_delete = "#cc7942",
		untracked     = "#759c73",
	},

	-- derived (computed; can be overridden directly)
	fg_dim   = nil,
	fg_muted = nil,
	bg_input = nil,
}

local function _compute()
	_p.fg_dim   = _p.fg_dim   or _p.fg_dark
	_p.fg_muted = _p.fg_muted or _p.comment
	_p.bg_input = _p.bg_input or _p.bg_soft_dark
end

_compute()

-- ── color helpers (re-exported from highlight module) ─────────────────────

M.blend   = hl.blend
M.lighten = hl.lighten
M.darken  = hl.darken

-- ── setup ─────────────────────────────────────────────────────────────────

---Override palette colors. Derived colors (fg_dim, fg_muted, bg_input) are
---recomputed unless explicitly provided.
---@param overrides table<string, string>
function M.setup(overrides)
	if not overrides then return end
	_p.fg_dim   = nil
	_p.fg_muted = nil
	_p.bg_input = nil
	for k, v in pairs(overrides) do
		_p[k] = v
	end
	_compute()
end

-- ── palette access ────────────────────────────────────────────────────────

setmetatable(M, {
	__index = function(_, k) return _p[k] end,
})

return M
