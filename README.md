# lvim-utils

A collection of independent Neovim utility modules — floating UI components, cursor management, highlight registration, a quit dialog, and a universal "open under cursor" extension.

---

## Installation

```lua
-- lazy.nvim
{
  "biserstoilov/lvim-utils",
  config = function()
    require("lvim-utils").setup({
      highlights = {
        LvimUiNormal  = { bg = "#1e1e2e" },
        LvimUiBorder  = { bg = "#1e1e2e" },
        LvimUiTitle   = { fg = "#cba6f7", bold = true },
      },
      ui = {
        border = "rounded",
      },
    })
  end,
}
```

Each module is independently usable — `setup()` is optional.

---

## Modules

### `cursor`

Hides the cursor whenever a buffer with a registered filetype is visible in any window. Uses a dedicated highlight group (`LvimUtilsHiddenCursor`) with `blend=100` and a 1-cell vertical bar shape — works in both GUI and TUI with `termguicolors`.

```lua
require("lvim-utils.cursor").setup({
  ft = { "lvim-utils-ui", "neo-tree", "NvimTree" },
})
```

**API**

| Function | Description |
|---|---|
| `setup(opts)` | Register filetypes and install autocmds |
| `mark_input_buffer(bufnr, value)` | Exempt a buffer from hiding (e.g. text-input popups) |
| `update()` | Force-refresh cursor state |

---

### `highlight`

Dynamic highlight group registration that survives colorscheme changes. Groups registered here are automatically re-applied on every `ColorScheme` event.

```lua
local hl = require("lvim-utils.highlight")

-- Register defaults (skips groups already set by the colorscheme)
hl.register({
  MyGroupNormal = { bg = "#1e1e2e" },
  MyGroupTitle  = { fg = "#cba6f7", bold = true },
})

-- Register as user overrides (always applied, even over colorscheme)
hl.register({ MyGroup = { fg = "#ff0000" } }, true)

-- Install the ColorScheme autocmd (call once during plugin init)
hl.setup()
```

**API**

| Function | Description |
|---|---|
| `register(groups, force?)` | Register and immediately apply highlight groups |
| `setup()` | Install the `ColorScheme` autocmd |

---

### `ui`

Floating popup components. All popups are centered on screen and share a unified visual style driven by highlight groups and config.

#### `select`

Pick one item from a list.

```lua
require("lvim-utils.ui").select({
  title    = "Choose colorscheme",
  subtitle = "Active on next restart",
  info     = "Requires a full Neovim restart",
  items    = { "catppuccin", "tokyonight", "gruvbox" },
  callback = function(ok, index)
    if ok then
      print("Selected index:", index)
    end
  end,
})
```

#### `multiselect`

Pick multiple items. `<Space>` toggles, `<CR>` confirms.

```lua
require("lvim-utils.ui").multiselect({
  title    = "Enable LSP servers",
  items    = { "lua_ls", "tsserver", "pyright" },
  callback = function(ok, selected)
    -- selected = table<string, boolean>
    if ok then vim.print(selected) end
  end,
})
```

#### `input`

Free-text input field.

```lua
require("lvim-utils.ui").input({
  title       = "Project name",
  placeholder = "my-project",
  callback = function(ok, value)
    if ok then print(value) end
  end,
})
```

#### `tabs`

Tabbed view. Supports two content modes:

**Simple items** — pick one item per tab:

```lua
require("lvim-utils.ui").tabs({
  title = "Package manager",
  tabs  = {
    { label = "Installed", items = { "lazy.nvim", "mason.nvim" } },
    { label = "Updates",   items = { "blink.cmp" } },
  },
  callback = function(ok, res)
    -- res = { tab, index, item }
  end,
})
```

**Typed rows** — settings-style UI with bool toggles, selects, number inputs, and actions:

```lua
require("lvim-utils.ui").tabs({
  tabs = {
    {
      label = "Editor",
      rows  = {
        { type = "spacer",  label = "Appearance" },
        { type = "bool",    name = "cursorline",   label = "Cursor line",       value = true },
        { type = "select",  name = "colorscheme",  label = "Colorscheme",       value = "catppuccin",
          options = { "catppuccin", "tokyonight", "gruvbox" } },
        { type = "int",     name = "scrolloff",    label = "Scroll offset",     value = 8 },
        { type = "float",   name = "timeout",      label = "Timeout (s)",       value = 2.0 },
        { type = "string",  name = "exclude_ft",   label = "Exclude filetypes", value = "markdown" },
        { type = "spacer_line" },
        { type = "action",  label = "Reset to defaults", run = function() end },
      },
    },
  },
  on_change = function(row)
    print(row.name, "=", row.value)
  end,
  callback = function(ok, snapshot)
    -- snapshot = table<name, value> for all named rows
  end,
})
```

**Row types**

| Type | Input method | Value |
|---|---|---|
| `bool` / `boolean` | `<CR>` toggles | `boolean` |
| `select` | `<Tab>` / `<BS>` cycles | `string` |
| `int` / `integer` | `<CR>` opens input | `integer` |
| `float` / `number` | `<CR>` opens input | `number` |
| `string` / `text` | `<CR>` opens input | `string` |
| `action` | `<CR>` executes | — |
| `spacer` | non-interactive label | — |
| `spacer_line` | horizontal divider | — |

Set `horizontal_actions = true` to render all `action` rows as a button bar at the bottom.

#### `info`

Read-only scrollable info window. Optionally renders content as Markdown via [markview.nvim](https://github.com/OXY2DEV/markview.nvim).

```lua
local buf, win = require("lvim-utils.ui").info(
  { "# Title", "", "Some **markdown** content." },
  { title = "About", markview = true }
)
```

**Callback signatures**

| Mode | `callback(ok, result)` |
|---|---|
| `select` | `result` = `integer` (1-based index) |
| `multiselect` | `result` = `table<string, boolean>` |
| `input` | `result` = `string` |
| `tabs` (items) | `result` = `{ tab, index, item }` |
| `tabs` (rows) | `result` = `table<name, value>` |
| `info` | returns `buf, win` directly |

---

### `quit`

Quit dialog that lists all unsaved normal buffers as toggleable rows. The user chooses which files to save, then picks an action from a horizontal button bar.

```lua
require("lvim-utils.quit").open()
```

- Quits immediately with `:qa` when there are no unsaved buffers.
- Unnamed buffers trigger a `vim.ui.input` prompt for a save path.

**Actions**

| Button | Behaviour |
|---|---|
| Save Selected & Quit | Writes checked buffers, then `:qa` / `:qa!` |
| Quit without Saving | `:qa!` |
| Cancel | Closes the dialog |

---

### `gx`

Universal "open under cursor" that replaces Neovim's built-in `gx`. Resolves URLs, local file paths (with optional `:line:col` suffix), bare domain/repo references (`github.com/foo/bar`), and paths inside file-manager buffers via registered adapters. Falls back to a proximity scan of nearby lines.

```lua
require("lvim-utils.gx").setup()
require("lvim-utils.gx").map_default()  -- binds gx → :GxOpen
```

Or via the main setup:

```lua
require("lvim-utils").setup({
  gx = {
    force_system_open_local = true,
    dir_open_strategy       = "system",
  },
})
```

**Built-in adapters**

| Adapter | Filetype |
|---|---|
| `neo_tree` | `neo-tree` |
| `nvim_tree` | `NvimTree` |
| `oil` | `oil` |
| `mini_files` | `minifiles` / `MiniFiles` |
| `netrw` | `netrw` |

**Custom adapter**

```lua
require("lvim-utils.gx").register_adapter({
  name   = "my_fm",
  detect = function(ctx) return ctx.filetype == "my-filemanager" end,
  get    = function(ctx)
    return { path = "/some/resolved/path", type = "file" }
  end,
})
```

**Commands**

| Command | Description |
|---|---|
| `:GxOpen [target]` | Open target under cursor (or explicit argument) |
| `:GxOpenDiag` | Print context, adapter, and first 10 candidates |

**Config options**

| Key | Default | Description |
|---|---|---|
| `highlight_match` | `true` | Briefly flash the matched token |
| `highlight_duration_ms` | `300` | Flash duration in ms |
| `system_open_cmd` | `nil` | Override opener (`xdg-open` / `open` / `start`) |
| `force_system_open_local` | `true` | Use system opener for local files |
| `allow_bare_domains` | `true` | Open `domain.tld/path` as HTTPS URL |
| `icon_guard` | `true` | Skip Nerd Font glyph tokens |
| `dir_open_strategy` | `"system"` | `"system"` or `"edit"` for directories |
| `search_forward_if_none` | `true` | Scan lines below cursor as fallback |
| `search_backward_if_none` | `true` | Scan lines above cursor as fallback |
| `search_max_lines` | `60` | Max lines to scan in each direction |
| `pattern` | `[%w%._~/#…]+` | Lua pattern for token extraction |
| `adapters` | all `true` | Enable/disable built-in adapters by name |

---

## Highlight Groups

All groups have sensible fallback links and can be overridden in `setup()`.

| Group | Default link | Used for |
|---|---|---|
| `LvimUiNormal` | `NormalFloat` | Popup background |
| `LvimUiBorder` | `FloatBorder` | Popup border |
| `LvimUiTitle` | `Title` | Popup title |
| `LvimUiSubtitle` | `Comment` | Popup subtitle |
| `LvimUiInfo` | `DiagnosticInfo` | Info line |
| `LvimUiCursorLine` | `CursorLine` | Selected row |
| `LvimUiTabActive` | `TabLineSel` | Active tab label |
| `LvimUiTabInactive` | `TabLine` | Inactive tab label |
| `LvimUiButtonActive` | `TabLineSel` | Active action button |
| `LvimUiButtonInactive` | `TabLine` | Inactive action button |
| `LvimUiSeparator` | `WinSeparator` | Header / footer separator lines |
| `LvimUiFooter` | `Comment` | Footer key-hints line |
| `LvimUiInput` | `CurSearch` | Input field row |
| `LvimUiSpacer` | `Comment` | Spacer / section label rows |
| `LvimUtilsHiddenCursor` | — | Transparent cursor (cursor module) |

---

## Default Keymaps (UI popups)

| Key | Action |
|---|---|
| `j` / `k` | Navigate rows |
| `<CR>` | Confirm / toggle / execute |
| `<Esc>` | Cancel / close |
| `q` | Close (tabs mode) |
| `l` / `h` | Next / prev tab (or action button) |
| `<Tab>` / `<BS>` | Cycle select option forward / backward |
| `<Space>` / `x` | Toggle item (multiselect) |

All keys are configurable via `ui.keys` in `setup()`.
