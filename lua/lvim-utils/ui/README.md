# lvim-utils UI

Floating popup system for Neovim. Five modes sharing a common window infrastructure.

---

## File structure

```
ui/
├── init.lua        — public API + default hl group registration
├── util.lua        — shared utilities (dw, center, resolve_hl, merge_bg, …)
├── rows.lua        — row/item type system and navigation helpers
├── popup.lua       — orchestrator: state, layout, window, render(), close()
├── header.lua      — header section build + highlights
├── content.lua     — content section build + highlights
├── footer.lua      — footer hints build + highlights
├── info.lua        — read-only info window (separate from popup)
└── mode/
    ├── select.lua       — select actions + keymaps
    ├── multiselect.lua  — multiselect actions + keymaps
    ├── input.lua        — input keymaps
    └── tabs.lua         — tabs actions + keymaps
```

---

## Modes

| Mode          | Callback signature                          |
| ------------- | ------------------------------------------- |
| `select`      | `callback(confirmed, index)`                |
| `multiselect` | `callback(confirmed, table<item, boolean>)` |
| `input`       | `callback(confirmed, string)`               |
| `tabs`        | `callback(confirmed, result)`               |
| `info`        | `callback(buf, win)` — optional             |

`tabs` result depends on tab content:

- Tab with `items` → `{ tab, index, item }`
- Tab with `rows` → `table<name, value>` (snapshot of all row values)

---

## Initialization

```lua
local p = require("lvim-utils.ui")

p.select({ ... })
p.multiselect({ ... })
p.input({ ... })
p.tabs({ ... })
p.info({ ... }, { ... })
```

---

## Common options (UiOpts)

```lua
{
  -- Header fields: plain string or { text = "", hl = HlDef }
  title    = "My title",
  subtitle = { text = "Subtitle", hl = { fg = "#89b4fa" } },
  info     = "Hint text",

  -- Window
  border   = "rounded",        -- "rounded"|"single"|"double"|"none"
  position = "editor",         -- "editor"|"win"|"cursor"
  max_items = 15,

  callback = function(confirmed, result) end,
}
```

### HeaderField

`title`, `subtitle`, and `info` accept either a plain string or a table:

```lua
title = "Plain string"
title = { text = "With custom hl", hl = { fg = "#cba6f7", bold = true } }
title = { text = "Named group", hl = "MyHlGroup" }
```

The `hl` field is a `HlDef` — see the HL system section below.

---

## Mode-specific options

### select

```lua
p.select({
	title = "Choose",
	items = {
		"plain string",
		-- flat hl: applies to the whole item line
		{
			label = "Flat hl",
			icon = "",
			hl = {
				active = { fg = "#cba6f7", bold = true },
				inactive = { fg = "#585b70" },
			},
		},
		-- split hl: icon and text colored independently
		{
			label = "Split hl",
			icon = "",
			hl = {
				active = { icon = { fg = "#89b4fa" }, text = { fg = "#cba6f7", bold = true } },
				inactive = { icon = { fg = "#45475a" }, text = { fg = "#585b70" } },
			},
		},
		-- icon only: text gets no extmark, icon uses per-item override (not the default group)
		{
			label = "Icon only",
			icon = "",
			hl = {
				active = { icon = { fg = "#a6e3a1" } },
				inactive = { icon = { fg = "#45475a" } },
			},
		},
	},
	current_item = some_item, -- pre-highlight a specific item
	callback = function(ok, index) end,
})
```

If no `hl` is set on an item, the icon still receives the default
`LvimUiItemIconActive` / `LvimUiItemIconInactive` groups.

### multiselect

```lua
p.multiselect({
	title = "Choose multiple",
	items = {
		-- flat hl: applies to whole line
		{
			label          = "Option A",
			icon           = "",
			checked_icon   = "󰱒",
			unchecked_icon = "󰄱",
			hl = {
				active   = { fg = "#a6e3a1", bold = true },
				inactive = { fg = "#585b70" },
			},
		},
		-- split hl: checkbox, icon and text colored independently
		{
			label          = "Option B",
			icon           = "",
			checked_icon   = "󰱒",
			unchecked_icon = "󰄱",
			hl = {
				active   = { checkbox = { fg = "#a6e3a1" }, icon = { fg = "#89b4fa" }, text = { fg = "#cdd6f4", bold = true } },
				inactive = { checkbox = { fg = "#45475a" }, icon = { fg = "#45475a" }, text = { fg = "#585b70" } },
			},
		},
	},
	initial_selected = { [item_ref] = true }, -- pre-checked items
	callback = function(ok, selected) end,    -- selected: table<item, boolean>
})
```

If no `hl` is set, all three parts use the config defaults:
`checkbox_hl.selected/empty`, `item_hl.active/inactive.icon`, `item_hl.active/inactive.text`.

### input

```lua
p.input({
	title = "Project name",
	placeholder = "my-project",
	callback = function(ok, value) end,
})
```

### tabs

Each tab can have either `items` (simple list, like select) or `rows` (typed settings rows):

```lua
p.tabs({
	tabs = {
		{
			label = "Editor",
			icon = "",
			tab_hl = { -- per-tab: only bg is used (see HL layers)
				active = { bg = "#cba6f7" },
				inactive = { bg = "#313244" },
			},
			rows = { ... }, -- typed rows (see Row types below)
		},
		{
			label = "Plugins",
			items = { "lazy.nvim", "mason.nvim" }, -- simple list
		},
	},
	tab_selector = "Editor", -- open on specific tab (string label or integer)
	initial_row = "scrolloff", -- focus specific row (string name or integer index)
	horizontal_actions = true, -- render action rows as a bottom bar instead of inline
	on_change = function(row) end,
	callback = function(ok, snapshot) end,
})
```

#### Row types

| type                   | value type | interaction           |
| ---------------------- | ---------- | --------------------- |
| `"bool"` / `"boolean"` | boolean    | `<CR>` toggles        |
| `"select"`             | string     | `<Tab>`/`<BS>` cycles |
| `"int"` / `"integer"`  | integer    | `<CR>` opens input    |
| `"float"` / `"number"` | float      | `<CR>` opens input    |
| `"string"` / `"text"`  | string     | `<CR>` opens input    |
| `"action"`             | —          | `<CR>` runs `run()`   |
| `"spacer"`             | —          | not selectable        |
| `"spacer_line"`        | —          | not selectable        |

```lua
{ type = "bool",   name = "autosave",   label = "Auto save",   value = false }
{ type = "select", name = "theme",      label = "Theme",       value = "catppuccin",
  options = { "catppuccin", "tokyonight", "gruvbox" } }
{ type = "int",    name = "scrolloff",  label = "Scroll offset", value = 8 }
{ type = "string", name = "excludes",   label = "Exclude",     value = "markdown,text" }
{ type = "action", name = "reset",      label = "Reset defaults",
  run = function(value, close) vim.notify("reset") end }
{ type = "spacer", label = "Section header" }
{ type = "spacer_line" }
```

Every row accepts an optional `hl` field:

```lua
hl = {
	active = HlDef, -- applied when row is focused
	inactive = HlDef, -- applied otherwise
}
```

---

## Highlight system

Three layers, evaluated in order. Each layer can override the previous.

```
Layer 1 — named groups (defaults)
  Registered in init.lua via hl.register({ LvimUiTitle = { link = "Title" }, … })
  Always present. Used as fallback.

Layer 2 — setup overrides
  Passed to require("lvim-utils").setup({ highlights = { … }, ui = { tab_hl = … } })
  Overrides the defaults globally.

Layer 3 — per-item / per-tab bg override
  Passed inline when defining items, rows, or tabs.
  Only the `bg` field is taken. fg/bold come from layer 2.
```

### HlDef

Any hl value in the system is a `HlDef`:

```lua
---@alias HlDef string | { bg?, fg?, bold?, italic?, sp?, underline?, … }

-- Named group (resolved at render time)
hl = "MyGroup"

-- Inline table (registered dynamically as LvimUiInline_N)
hl = { fg = "#cba6f7", bold = true }
```

### Named HL groups

All groups and their defaults:

| Group                  | Default link     | Used for                                |
| ---------------------- | ---------------- | --------------------------------------- |
| `LvimUiNormal`         | `NormalFloat`    | Popup background                        |
| `LvimUiBorder`         | `FloatBorder`    | Popup border                            |
| `LvimUiTitle`          | `Title`          | Title line                              |
| `LvimUiSubtitle`       | `Comment`        | Subtitle line                           |
| `LvimUiInfo`           | `DiagnosticInfo` | Info line                               |
| `LvimUiCursorLine`     | `CursorLine`     | Active item / row highlight             |
| `LvimUiTabActive`      | `TabLineSel`     | Active tab button                       |
| `LvimUiTabInactive`    | `TabLine`        | Inactive tab button                     |
| `LvimUiButtonActive`   | `TabLineSel`     | Active action button (horizontal bar)   |
| `LvimUiButtonInactive` | `TabLine`        | Inactive action button                  |
| `LvimUiSeparator`      | `WinSeparator`   | Horizontal separator lines              |
| `LvimUiFooter`         | `Comment`        | Footer hint line (base)                 |
| `LvimUiFooterKey`      | `Keyword`        | Key part of footer hints (`j/k`)        |
| `LvimUiFooterLabel`    | `Comment`        | Label part of footer hints (`navigate`) |
| `LvimUiInput`          | `CurSearch`      | Input placeholder line                  |
| `LvimUiSpacer`         | `Comment`        | Spacer rows in tabs                     |

### Overriding HL groups

**Via `setup()` highlights table** (global, persists across colorscheme changes):

```lua
require("lvim-utils").setup({
	highlights = {
		LvimUiTitle = { fg = "#cba6f7", bold = true },
		LvimUiFooterKey = { fg = "#89b4fa", bold = true },
		LvimUiFooterLabel = { fg = "#585b70", italic = true },
		LvimUiCursorLine = { bg = "#2a2b3d", fg = "#cdd6f4" },
	},
})
```

**Via `tab_hl` / `button_hl` / `footer_hl`** in setup (flat HlDef, layer 2):

```lua
require("lvim-utils").setup({
	ui = {
		tab_hl = {
			active = { bg = "#89b4fa", fg = "#1e1e2e", bold = true },
			inactive = { bg = "#45475a", fg = "#7f849c" },
		},
		button_hl = {
			active = { bg = "#89b4fa", fg = "#1e1e2e", bold = true },
			inactive = { bg = "#45475a", fg = "#7f849c" },
		},
		footer_hl = {
			key = { fg = "#89b4fa", bold = true },
			label = { fg = "#585b70", italic = true },
		},
	},
})
```

**Per-tab bg override** (layer 3 — only `bg` is used):

```lua
{
  label  = "Editor",
  tab_hl = {
    active   = { bg = "#cba6f7" },   -- only bg taken; fg/bold from layer 2
    inactive = { bg = "#313244" },
  },
}
```

**Per-item / per-row hl** (inline, both active and inactive):

```lua
{ label = "Option", hl = {
  active   = { fg = "#a6e3a1", bold = true },
  inactive = { fg = "#585b70" },
}}
```

**Per-header-field hl** (title, subtitle, info):

```lua
title = { text = "My Title", hl = { fg = "#f38ba8", bold = true } }
subtitle = { text = "Hint", hl = "MyGroup" }
```

---

## Config reference

Full config with defaults:

```lua
require("lvim-utils").setup({
	ui = {
		border = "rounded", -- "rounded"|"single"|"double"|"none"
		position = "editor", -- "editor"|"win"|"cursor"
		max_items = 15,
		max_height = 0.8, -- fraction of screen height

		-- info window only
		width = "auto", -- "auto" | 0-1 fraction | integer
		height = "auto",
		markview = false, -- render info content via markview.nvim

		tab_hl = {
			active = "LvimUiTabActive",
			inactive = "LvimUiTabInactive",
		},
		button_hl = {
			active = "LvimUiButtonActive",
			inactive = "LvimUiButtonInactive",
		},
		footer_hl = {
			key = "LvimUiFooterKey",
			label = "LvimUiFooterLabel",
		},

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
	},
})
```

---

## Navigation hints (footer)

The footer updates dynamically based on mode and current row type:

| Context                      | Hint                                                    |
| ---------------------------- | ------------------------------------------------------- |
| select                       | `j/k navigate   <CR> confirm   <Esc> cancel`            |
| multiselect                  | `<Space> toggle   <CR> confirm   <Esc> cancel`          |
| input                        | `<CR> confirm   <Esc> cancel`                           |
| tabs / items                 | `h/l tabs   j/k navigate   <CR> confirm   <Esc> cancel` |
| tabs / bool row              | `j/k navigate   <CR> toggle   <Esc> close`              |
| tabs / select row            | `j/k navigate   <Tab>/<BS> cycle   <Esc> close`         |
| tabs / int · float · string  | `j/k navigate   <CR> edit   <Esc> close`                |
| tabs / action row            | `j/k navigate   <CR> execute   <Esc> close`             |
| tabs / horizontal action bar | `h/l navigate   <CR> execute   <Esc> close`             |

