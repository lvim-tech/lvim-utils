-- ─── palette ──────────────────────────────────────────────────────────────────
local bg = "#23292d"
local bg_dark = "#1a1f21"
local bg_hl = "#2e363a"
local fg_dim = "#646c62"
local comment = "#565c53"
local blue = "#42728b"
local green = "#75783a"
local cyan = "#527a57"
local magenta = "#bb755e"
local orange = "#cc7942"
local yellow = "#af9e6b"
local teal = "#357b6d"
local red = "#cb4f4f"

-- ──────────────────────────────────────────────────────────────────────────────

-- require("lvim-utils.cursor").setup({ ft = { "lvim-utils-ui" } })

require("lvim-utils").setup()

local p = require("lvim-utils.ui")

-- ─── demo commands ────────────────────────────────────────────────────────────

-- :LvimDemoQuit
-- vim.api.nvim_create_user_command("LvimDemoQuit", function()
-- 	require("lvim-utils.quit").open()
-- end, {})
--
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
	}, { title = "LVIM UTILS", markview = true })
end, {})
--
-- -- :LvimDemoSelect
-- vim.api.nvim_create_user_command("LvimDemoSelect", function()
-- 	p.select({
-- 		title = "Choose colorscheme",
-- 		subtitle = "Active on next restart",
-- 		info = "Requires a full Neovim restart to apply",
-- 		items = {
-- 			{ label = "catppuccin", icon = "󰄛", hl = { active = { fg = magenta, bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "tokyonight", icon = "󰖔", hl = { active = { fg = blue,    bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "gruvbox",    icon = "󰆧", hl = { active = { fg = yellow,  bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "nord",       icon = "󱅾", hl = { active = { fg = cyan,    bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "rose-pine",  icon = "󱕸", hl = { active = { fg = red,     bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "kanagawa",   icon = "󰸗", hl = { active = { fg = teal,    bold = true }, inactive = { fg = fg_dim } } },
-- 		},
-- 		callback = function(ok, idx)
-- 			if ok then vim.notify("Selected: " .. idx) end
-- 		end,
-- 	})
-- end, {})
--
-- -- :LvimDemoMultiselect
-- vim.api.nvim_create_user_command("LvimDemoMultiselect", function()
-- 	p.multiselect({
-- 		title = "Enable LSP servers",
-- 		subtitle = "Will be installed automatically",
-- 		info = "Use <Space> to toggle, <CR> to confirm",
-- 		items = {
-- 			{ label = "lua_ls",        icon = "󰢱", hl = { active = { fg = magenta, bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "tsserver",      icon = "󰛦", hl = { active = { fg = blue,    bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "pyright",       icon = "󰌠", hl = { active = { fg = yellow,  bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "rust_analyzer", icon = "󱘗", hl = { active = { fg = orange,  bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "gopls",         icon = "󰟓", hl = { active = { fg = cyan,    bold = true }, inactive = { fg = fg_dim } } },
-- 			{ label = "clangd",        icon = "󰙱", hl = { active = { fg = green,   bold = true }, inactive = { fg = fg_dim } } },
-- 		},
-- 		callback = function(ok, sel)
-- 			if ok then vim.notify(vim.inspect(sel)) end
-- 		end,
-- 	})
-- end, {})
--
-- -- :LvimDemoInput
-- vim.api.nvim_create_user_command("LvimDemoInput", function()
-- 	p.input({
-- 		title = "Project name",
-- 		subtitle = "Used for session and workspace",
-- 		info = "Alphanumeric characters and dashes only",
-- 		placeholder = "my-project",
-- 		callback = function(ok, val)
-- 			if ok then vim.notify("Input: " .. val) end
-- 		end,
-- 	})
-- end, {})
--
-- -- :LvimDemoTabs  (simple tabs — items only)
-- vim.api.nvim_create_user_command("LvimDemoTabs", function()
-- 	p.tabs({
-- 		tabs = {
-- 			{
-- 				label = "Installed",
-- 				items = {
-- 					{ label = "lazy.nvim",        icon = "󰒲" },
-- 					{ label = "mason.nvim",        icon = "" },
-- 					{ label = "nvim-treesitter",   icon = "" },
-- 					{ label = "telescope.nvim",    icon = "" },
-- 				},
-- 			},
-- 			{
-- 				label = "Updates",
-- 				items = {
-- 					{ label = "blink.cmp",         icon = "󰘦" },
-- 					{ label = "heirline.nvim",     icon = "" },
-- 				},
-- 			},
-- 			{
-- 				label = "Removed",
-- 				items = {
-- 					{ label = "nvim-cmp",          icon = "󰅗" },
-- 					{ label = "nvim-lsp-installer",icon = "󰅗" },
-- 				},
-- 			},
-- 		},
-- 		callback = function(ok, res)
-- 			if ok then vim.notify(vim.inspect(res)) end
-- 		end,
-- 	})
-- end, {})
--
-- -- :LvimDemoSettings  (tabs with typed rows)
-- -- Editor tab uses a per-tab bg override (only bg is taken from per-tab tab_hl).
-- vim.api.nvim_create_user_command("LvimDemoSettings", function()
-- 	p.tabs({
-- 		tabs = {
-- 			{
-- 				label  = "Editor",
-- 				icon   = "",
-- 				-- Per-tab override: only bg field matters.  fg/bold come from global tab_hl.
-- 				tab_hl = {
-- 					active   = { bg = magenta },
-- 					inactive = { bg = bg_hl },
-- 				},
-- 				rows = {
-- 					{ type = "spacer", label = "Appearance" },
-- 					{ type = "bool",   name = "relative_numbers", label = "Relative line numbers", value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "bool",   name = "cursorline",       label = "Cursor line",            value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "select", name = "colorscheme", label = "Colorscheme", value = "catppuccin",
-- 						options = { "catppuccin", "tokyonight", "gruvbox", "nord", "rose-pine" },
-- 						hl = { active = { fg = blue,    bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "spacer", label = "Behaviour" },
-- 					{ type = "int",    name = "scrolloff",  label = "Scroll offset",  value = 8,
-- 						hl = { active = { fg = orange,  bold = true }, inactive = { fg = comment } } },
-- 					{ type = "int",    name = "timeoutlen", label = "Timeout (ms)",   value = 300,
-- 						hl = { active = { fg = orange,  bold = true }, inactive = { fg = comment } } },
-- 					{ type = "bool",   name = "autosave",   label = "Auto save",      value = false,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "action", name = "reset_editor", label = "Reset to defaults",
-- 						run = function() vim.notify("Editor settings reset") end,
-- 						hl = { active = { fg = red,     bold = true }, inactive = { fg = comment } } },
-- 				},
-- 			},
-- 			{
-- 				label = "LSP",
-- 				icon  = "󰒋",
-- 				rows = {
-- 					{ type = "spacer", label = "Diagnostics" },
-- 					{ type = "bool",   name = "inline_hints", label = "Inline hints",  value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "bool",   name = "virtual_text", label = "Virtual text",  value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "select", name = "severity",     label = "Min severity",  value = "WARN",
-- 						options = { "HINT", "INFO", "WARN", "ERROR" },
-- 						hl = { active = { fg = blue,    bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "spacer", label = "Format" },
-- 					{ type = "bool",  name = "format_on_save",   label = "Format on save",     value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "float", name = "format_timeout",   label = "Format timeout (s)", value = 2.0,
-- 						hl = { active = { fg = orange,  bold = true }, inactive = { fg = comment } } },
-- 					{ type = "string",name = "format_exclude",   label = "Exclude filetypes",  value = "markdown,text",
-- 						hl = { active = { fg = yellow,  bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "action",name = "restart_lsp", label = "Restart LSP servers",
-- 						run = function() vim.notify("LSP restarted") end,
-- 						hl = { active = { fg = red,     bold = true }, inactive = { fg = comment } } },
-- 				},
-- 			},
-- 			{
-- 				label = "Git",
-- 				icon  = "󰊢",
-- 				rows = {
-- 					{ type = "spacer", label = "Signs" },
-- 					{ type = "bool",   name = "git_signs",  label = "Show signs",    value = true,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "bool",   name = "git_blame",  label = "Inline blame",  value = false,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "select", name = "git_diff_style", label = "Diff style", value = "split",
-- 						options = { "split", "unified", "inline" },
-- 						hl = { active = { fg = blue,    bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "spacer", label = "Behaviour" },
-- 					{ type = "int",    name = "git_update_ms",  label = "Update interval (ms)", value = 1000,
-- 						hl = { active = { fg = orange,  bold = true }, inactive = { fg = comment } } },
-- 					{ type = "bool",   name = "git_word_diff",  label = "Word diff",             value = false,
-- 						hl = { active = { fg = green,   bold = true }, inactive = { fg = comment } } },
-- 					{ type = "spacer_line" },
-- 					{ type = "action", name = "git_refresh", label = "Refresh git status",
-- 						run = function() vim.notify("Git status refreshed") end,
-- 						hl = { active = { fg = red,     bold = true }, inactive = { fg = comment } } },
-- 				},
-- 			},
-- 		},
-- 		on_change = function(row)
-- 			vim.notify(string.format("[changed] %s = %s", row.name or "?", tostring(row.value)))
-- 		end,
-- 		callback = function(ok, snap)
-- 			if ok then vim.notify("[settings closed]\n" .. vim.inspect(snap)) end
-- 		end,
-- 	})
-- end, {})
