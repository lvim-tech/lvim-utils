return {
	border = "rounded", -- "rounded"|"single"|"double"|"none"
	max_items = 15,
	max_height = 0.8, -- fraction of screen height
	width = "auto", -- info window: "auto" | fraction 0-1 | integer
	height = "auto", -- info window: "auto" | fraction 0-1 | integer
	filetype = "lvim-utils-ui",
	close_keys = { "q", "<Esc>" },
	markview = false, -- render info content as markdown via markview.nvim

	icons = {
		bool_on = "󰱒",
		bool_off = "󰄱",
		select = "󰒓",
		number = "󰬷",
		string = "󰴓",
		action = "󱐋",
		spacer = "─",
		multi_selected = "●",
		multi_empty = "○",
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
			toggle_alt = "x",
			confirm = "<CR>",
			cancel = "<Esc>",
		},

		list = {
			next_option = "<Tab>",
			prev_option = "<BS>",
		},
	},
}
