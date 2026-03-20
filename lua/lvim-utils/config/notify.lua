-- lua/lvim-utils/config/notify.lua
-- Default configuration for the notify module.

return {
	-- Ring-buffer size for M.history()
	max_history = 100,
	-- Auto-dismiss delay in ms; 0 = sticky
	timeout = 5000,
	-- Panel width bounds
	min_width = 50,
	max_width = 100,
	-- Horizontal padding inside the panel
	padding = 1,
	-- Rows from the bottom of the editor
	bottom_margin = 1,
	-- Rows between stacked level panels
	panel_gap = 0,
	-- Floating window border (passed to nvim_open_win)
	border = "none",
	-- Floating window z-index
	zindex = 1000,
	-- Character repeated across the panel width as entry separator
	separator = "─",
	-- Replace global print() as well
	override_print = true,
	-- Intercept all Neovim messages via vim.ui_attach (ext_messages)
	ext_messages = true,
	-- Timeout (ms) for echo/info-level ext messages
	ext_echo_timeout = 3000,
	-- Per-kind behaviour: "toast" = panel + history, "history" = history only, "ignore" = drop
	ext_kinds = {
		emsg = "toast",
		echoerr = "toast",
		lua_error = "toast",
		rpc_error = "toast",
		shell_err = "toast",
		wmsg = "toast",
		echomsg = "toast",
		echo = "toast",
		bufwrite = "toast",
		undo = "toast",
		shell_out = "history",
		lua_print = "history",
		verbose = "history",
		[""] = "history",
		search_count = "ignore",
		search_cmd = "ignore",
		wildlist = "ignore",
		completion = "ignore",
	},
	-- Active printers on load: "toast", "history", or { name, fn } / fn
	printers = { "toast", "history" },
	-- Width of the progress panel (defaults to max_width when nil)
	progress_width = nil,
	-- Level icons
	icons = {
		trace = "󰌶",
		debug = "󰃤",
		error = "󰅙",
		warn = "󰀨",
		info = "",
		hint = "",
		progress = "󱦟",
	},
	-- Singular/plural level names shown in the header bar
	level_names = {
		trace = "Trace",
		debug = "Debug",
		info = "Info",
		warn = "Warn",
		error = "Error",
	},
}
