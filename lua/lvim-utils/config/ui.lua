return {
	border = { "", "", "", " ", " ", " ", " ", " " },
	position = "editor",
	width = 0.8,
	max_width = 0.8,
	height = 0.8,
	max_height = 0.8,
	max_items = 15,
	filetype = "lvim-utils-ui",
	close_keys = { "q", "<Esc>" },
	markview = false,

	-- tab_hl, button_hl, footer_hl, item_hl, checkbox_hl have no defaults.
	-- When absent the rendering code falls back to the named LvimUi* groups.
	-- Set any of them in setup({ ui = { tab_hl = { active = { ... } } } })
	-- only when you want an inline HlDef instead of a named group.

	icons = {
		bool_on = "󰄬",
		bool_off = "󰍴",
		select = "󰘮",
		number = "󰎠",
		string = "󰬴",
		action = "",
		spacer = "   ──────",
		multi_selected = "󰄬",
		multi_empty = "󰍴",
		current = "➤",
	},

	labels = {
		navigate = "navigate",
		confirm = "confirm",
		cancel = "cancel",
		close = "close",
		toggle = "toggle",
		cycle = "cycle",
		edit = "edit",
		execute = "execute",
		tabs = "tabs",
	},

	keys = {
		down = "j",
		up = "k",
		confirm = "<CR>",
		cancel = "<Esc>",
		close = "q",

		tabs = {
			next = "l",
			prev = "h",
		},

		select = {
			confirm = "<CR>",
			cancel = "<Esc>",
		},

		multiselect = {
			toggle = "<Space>",
			confirm = "<CR>",
			cancel = "<Esc>",
		},

		list = {
			next_option = "<Tab>",
			prev_option = "<BS>",
		},
	},
}
