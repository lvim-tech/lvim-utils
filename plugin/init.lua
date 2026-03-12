require("lvim-utils.cursor").setup({ ft = { "lvim-utils-ui" } })

require("lvim-utils").setup({
    ui = {

        border = {"", "", "", " ", " ", " ", " ", " "},
    },
	highlights = {
		LvimUiNormal = { bg = "#1e1e2e" },
		LvimUiBorder = { bg = "#1e1e2e" },
		LvimUiTitle = { fg = "#cba6f7", bold = true },
		LvimUiSubtitle = { fg = "#6c7086" },
		LvimUiInfo     = { fg = "#89dceb" },
		LvimUiCursorLine = { bg = "#2a2b3d", fg = "#cdd6f4" },
		LvimUiTabActive      = { bg = "#89b4fa", bold = true },
		LvimUiTabInactive    = { bg = "#45475a" },
		LvimUiButtonActive   = { bg = "#89b4fa", bold = true },
		LvimUiButtonInactive = { bg = "#45475a" },
		LvimUiSeparator = { fg = "#313244" },
		LvimUiFooter = { fg = "#0000ff", italic = true },
		LvimUiInput = { bg = "#313244", fg = "#cdd6f4" },
		LvimUiSpacer = { fg = "#585b70", bold = true },
	},
})

local p = require("lvim-utils.ui")

-- ─── demo commands ────────────────────────────────────────────────────────────

-- :LvimDemoQuit
vim.api.nvim_create_user_command("LvimDemoQuit", function()
  require("lvim-utils.quit").open()
end, {})

-- :LvimDemoInfo
vim.api.nvim_create_user_command("LvimDemoInfo", function()
	p.info({
		"# lvim-utils",
		"",
		"## Modules",
		"",
		"### cursor",
		"Hide the cursor for specific filetypes.",
		"",
		"### highlight",
		"Dynamic highlight group registration that survives colorscheme changes.",
		"",
		"### popups",
		"Floating UI components:",
		"",
		"- **select** — pick one item from a list",
		"- **multiselect** — pick multiple items",
		"- **input** — text input field",
		"- **tabs** — tabbed view with typed rows",
		"- **info** — read-only display *(this window)*",
		"",
		"## Usage",
		"",
		"```lua",
		'require("lvim-utils").setup({ ... })',
		"```",
		"",
		"> All modules are independently usable.",
		"",
		"## Popup modes",
		"",
		"| Mode         | Callback result              |",
		"| ------------ | ---------------------------- |",
		"| select       | `index` (integer)            |",
		"| multiselect  | `table<string, boolean>`     |",
		"| input        | `string`                     |",
		"| tabs (items) | `{ tab, index, item }`       |",
		"| tabs (rows)  | `table<name, value>`         |",
		"| info         | `buf, win`                   |",
	}, { title = "lvim-utils", markview = true })
end, {})

-- :LvimDemoSelect
vim.api.nvim_create_user_command("LvimDemoSelect", function()
	p.select({
		title    = "Choose colorscheme",
		subtitle = "Active on next restart",
		info     = "Requires a full Neovim restart to apply",
		items    = { "catppuccin", "tokyonight", "gruvbox", "nord", "rose-pine", "kanagawa" },
		callback = function(ok, idx)
			if ok then
				vim.notify("Selected: " .. idx)
			end
		end,
	})
end, {})

-- :LvimDemoMultiselect
vim.api.nvim_create_user_command("LvimDemoMultiselect", function()
	p.multiselect({
		title    = "Enable LSP servers",
		subtitle = "Will be installed automatically",
		info     = "Use <Space> to toggle, <CR> to confirm",
		items    = { "lua_ls", "tsserver", "pyright", "rust_analyzer", "gopls", "clangd" },
		callback = function(ok, sel)
			if ok then
				vim.notify(vim.inspect(sel))
			end
		end,
	})
end, {})

-- :LvimDemoInput
vim.api.nvim_create_user_command("LvimDemoInput", function()
	p.input({
		title       = "Project name",
		subtitle    = "Used for session and workspace",
		info        = "Alphanumeric characters and dashes only",
		placeholder = "my-project",
		callback = function(ok, val)
			if ok then
				vim.notify("Input: " .. val)
			end
		end,
	})
end, {})

-- :LvimDemoTabs  (simple tabs — items only)
vim.api.nvim_create_user_command("LvimDemoTabs", function()
	p.tabs({
		title    = "Package manager",
		subtitle = "lazy.nvim",
		info     = "Plugins are loaded from ~/.config/nvim/lua/plugins",
		tabs     = {
			{ label = "Installed", items = { "lazy.nvim", "mason.nvim", "nvim-treesitter", "telescope.nvim" } },
			{ label = "Updates", items = { "blink.cmp", "heirline.nvim" } },
			{ label = "Removed", items = { "nvim-cmp", "nvim-lsp-installer" } },
		},
		callback = function(ok, res)
			if ok then
				vim.notify(vim.inspect(res))
			end
		end,
	})
end, {})

-- :LvimDemoSettings  (tabs with typed rows)
vim.api.nvim_create_user_command("LvimDemoSettings", function()
	p.tabs({
		tabs = {
			{
				label = "Editor",
				rows = {
					{ type = "spacer", label = "Appearance" },
					{ type = "bool", name = "relative_numbers", label = "Relative line numbers", value = true },
					{ type = "bool", name = "cursorline", label = "Cursor line", value = true },
					{
						type = "select",
						name = "colorscheme",
						label = "Colorscheme",
						value = "catppuccin",
						options = { "catppuccin", "tokyonight", "gruvbox", "nord", "rose-pine" },
					},
					{ type = "spacer_line" },
					{ type = "spacer", label = "Behaviour" },
					{ type = "int", name = "scrolloff", label = "Scroll offset", value = 8 },
					{ type = "int", name = "timeoutlen", label = "Timeout (ms)", value = 300 },
					{ type = "bool", name = "autosave", label = "Auto save", value = false },
					{ type = "spacer_line" },
					{
						type = "action",
						name = "reset_editor",
						label = "Reset to defaults",
						run = function()
							vim.notify("Editor settings reset")
						end,
					},
				},
			},
			{
				label = "LSP",
				rows = {
					{ type = "spacer", label = "Diagnostics" },
					{ type = "bool", name = "inline_hints", label = "Inline hints", value = true },
					{ type = "bool", name = "virtual_text", label = "Virtual text", value = true },
					{
						type = "select",
						name = "severity",
						label = "Min severity",
						value = "WARN",
						options = { "HINT", "INFO", "WARN", "ERROR" },
					},
					{ type = "spacer_line" },
					{ type = "spacer", label = "Format" },
					{ type = "bool", name = "format_on_save", label = "Format on save", value = true },
					{ type = "float", name = "format_timeout", label = "Format timeout (s)", value = 2.0 },
					{
						type = "string",
						name = "format_exclude",
						label = "Exclude filetypes",
						value = "markdown,text",
					},
					{ type = "spacer_line" },
					{
						type = "action",
						name = "restart_lsp",
						label = "Restart LSP servers",
						run = function()
							vim.notify("LSP restarted")
						end,
					},
				},
			},
			{
				label = "Git",
				rows = {
					{ type = "spacer", label = "Signs" },
					{ type = "bool", name = "git_signs", label = "Show signs", value = true },
					{ type = "bool", name = "git_blame", label = "Inline blame", value = false },
					{
						type = "select",
						name = "git_diff_style",
						label = "Diff style",
						value = "split",
						options = { "split", "unified", "inline" },
					},
					{ type = "spacer_line" },
					{ type = "spacer", label = "Behaviour" },
					{ type = "int", name = "git_update_ms", label = "Update interval (ms)", value = 1000 },
					{ type = "bool", name = "git_word_diff", label = "Word diff", value = false },
					{ type = "spacer_line" },
					{
						type = "action",
						name = "git_refresh",
						label = "Refresh git status",
						run = function()
							vim.notify("Git status refreshed")
						end,
					},
				},
			},
		},
		on_change = function(row)
			vim.notify(string.format("[changed] %s = %s", row.name or "?", tostring(row.value)))
		end,
		callback = function(ok, snap)
			if ok then
				vim.notify("[settings closed]\n" .. vim.inspect(snap))
			end
		end,
	})
end, {})
