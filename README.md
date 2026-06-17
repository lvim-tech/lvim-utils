# lvim-utils

A collection of independent Neovim utility modules — floating UI components, cursor management, highlight registration, a quit dialog, a notification system, and a universal "open under cursor" extension.

---

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-utils/blob/main/LICENSE)

## Installation

### LVIM IDE

Ships with LVIM IDE (a core dependency). Override its options in your user module
(`lua/modules/user/init.lua`):

```lua
modules["lvim-tech/lvim-utils"] = {
    config = function()
        require("lvim-utils").setup({ ... })
    end,
}
```

### lazy.nvim

```lua
return {
    "lvim-tech/lvim-utils",
    config = function()
        require("lvim-utils").setup({ ... })
    end,
}
```

### Native (vim.pack / packadd)

```lua
-- In your init.lua, after the plugin is on the runtimepath:
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
})

require("lvim-utils").setup({ ... })
```

### packer.nvim

```lua
use({
    "lvim-tech/lvim-utils",
    config = function()
        require("lvim-utils").setup({ ... })
    end,
})
```

Each module is independently usable — `setup()` is optional.

**`setup()` options**

| Key          | Description                                                |
| ------------ | ---------------------------------------------------------- |
| `colors`     | Override palette colors (see [colors](#colors))            |
| `highlights` | Register highlight group overrides (always applied)        |
| `ui`         | UI popup config (see [ui config](#ui-config))              |
| `cursor`     | Cursor module config                                       |
| `gx`         | gx module config (see [gx](#gx))                           |
| `notify`     | Notify module config (see [notify config](#notify-config)) |

---

## Modules

### `colors`

Public color palette shared by all lvim-utils modules. Automatically syncs from `lvim-colorscheme` when available. Standalone, a bundled muted **dark** and **light** palette is used and swapped automatically on `&background` change; `setup({ colors = {...} })` overrides are sticky across background flips and theme syncs.

```lua
local c = require("lvim-utils.colors")

local red = c.red -- "#cb4f4f"
local bg_light = c.bg_light -- "#2c3339"
local add = c.git.add -- "#5f7240"
local mixed = c.blend(c.teal, c.bg, 0.3)
```

**Override palette via `setup()`:**

```lua
require("lvim-utils").setup({
    colors = {
        red = "#ff5555",
        blue = "#569cd6",
    },
})
```

**API**

| Function                 | Description                                                         |
| ------------------------ | ------------------------------------------------------------------- |
| `setup(overrides)`       | Override palette colors; derived colors recomputed automatically    |
| `sync_from_lcs()`        | Pull palette from `lvim-colorscheme` and fire `on_change` listeners |
| `on_change(fn)`          | Register a callback fired whenever the palette changes              |
| `blend(fg, bg, alpha)`   | Blend two hex colors (alpha 1.0 = fully fg)                         |
| `lighten(color, amount)` | Blend toward white                                                  |
| `darken(color, amount)`  | Blend toward black                                                  |

---

### `cursor`

Hides the hardware cursor based on the current/visible buffers' filetypes. Uses a dedicated highlight group (`LvimUtilsHiddenCursor`) with `blend=100` and a 1-cell vertical bar shape — works in both GUI and TUI with `termguicolors`. This is the ONE cursor system; the `ui` frame engine delegates all its cursor hiding here.

Two filetype lists:

- **`ft`** (transient popups) — the cursor is hidden whenever such a buffer is visible in **any** window, so it stays hidden while a modal popup owns the screen even if focus flickers elsewhere.
- **`panel_ft`** (persistent side panels) — the cursor is hidden **only while that panel is the current window**, so it stays visible in the code beside an always-open panel.

```lua
require("lvim-utils.cursor").setup({
    ft = { "lvim-ui-frame", "neo-tree", "NvimTree" }, -- hidden whenever visible
    panel_ft = { "lvim-lsp-outline" }, -- hidden only while current
})
```

**API**

| Function                          | Description                                                  |
| --------------------------------- | ----------------------------------------------------------- |
| `setup(opts)`                     | Register `ft` / `panel_ft` filetypes and install autocmds   |
| `mark_input_buffer(bufnr, value)` | Keep the cursor VISIBLE in a buffer (e.g. a text-input field) even if its filetype is registered |
| `update()`                        | Force-refresh cursor state                                  |

---

### `highlight`

Dynamic highlight group registration that survives colorscheme changes, plus color manipulation helpers.

**Self-theming with `bind` (recommended)**

`bind` is the canonical way for a plugin to theme its own UI from the shared
[`colors`](#colors) palette while staying overwritable. Pass a factory that reads the
palette and returns its groups; `bind` applies them with `default = true` (so the active
colorscheme or the user can override them) and re-applies automatically whenever the
palette syncs from lvim-colorscheme or on any `ColorScheme`. When the palette actually
changes the groups are force-updated, so live theme previews recolor correctly.

The factory receives the live palette as its argument. `bind` returns a dispose function
that unbinds the factory (for isolated `ui.new()` instances or plugins that tear down).

```lua
local hl = require("lvim-utils.highlight")

local dispose = hl.bind(function(c)
    return {
        MyPluginNormal = { bg = c.bg_dark, fg = c.fg },
        MyPluginTitle = { fg = c.blue, bold = true },
    }
end)

-- later, to stop theming these groups:
-- dispose()
```

**Fixed groups with `register`**

For groups that are not palette-derived (or to hard-apply user overrides):

```lua
-- Register defaults (skips groups already set by the colorscheme)
hl.register({
    MyGroupNormal = { bg = "#1e1e2e" },
    MyGroupTitle = { fg = "#cba6f7", bold = true },
})

-- Register as overrides (always applied, even over colorscheme)
hl.register({ MyGroup = { fg = "#ff0000" } }, true)

-- Install the ColorScheme autocmd (call once during plugin init)
hl.setup()
```

**Color helpers**

```lua
hl.blend("#cba6f7", "#1e1e2e", 0.3) -- blend two hex colors (alpha 0–1)
hl.lighten("#cba6f7", 0.2) -- blend toward white
hl.darken("#cba6f7", 0.2) -- blend toward black
```

**Group utilities**

```lua
hl.define("MyGroup", { fg = "#ff0000", bold = true }) -- set (always)
hl.define_if_missing("MyGroup", { fg = "#ff0000" }) -- set only if not defined
hl.clear("MyGroup") -- reset to empty
hl.get("MyGroup") -- → attribute table or nil
hl.link("MyGroup", "Normal") -- link to another group
hl.group_exists("MyGroup") -- → boolean
```

**API**

| Function                        | Description                                     |
| ------------------------------- | ----------------------------------------------- |
| `bind(fn)`                      | Self-theme: apply a palette factory (`default`), re-applied on palette/`ColorScheme` change |
| `register(groups, force?)`      | Register and immediately apply fixed highlight groups |
| `setup()`                       | Install the `ColorScheme` autocmd               |
| `blend(fg, bg, alpha)`          | Blend two hex colors                            |
| `lighten(color, amount)`        | Blend toward white                              |
| `darken(color, amount)`         | Blend toward black                              |
| `define(name, opts)`            | Set a group (always applied)                    |
| `define_if_missing(name, opts)` | Set a group only if not already defined         |
| `clear(name)`                   | Reset a group to empty                          |
| `get(name)`                     | Get group attributes                            |
| `link(name, link_to)`           | Link one group to another                       |
| `group_exists(name)`            | Check if a group is defined                     |

---

### `ui`

Floating popup components. All popups share a unified visual style driven by highlight groups and config.

The only module that supports independent instances — see [`ui.new()`](#uinew--isolated-instances).

#### `select`

Pick one item from a list. Pass `current_item` to mark the currently active value with a `➤` indicator regardless of cursor position.

```lua
require("lvim-utils.ui").select({
    title = "Choose colorscheme",
    subtitle = "Active on next restart",
    info = "Requires a full Neovim restart",
    items = { "catppuccin", "tokyonight", "gruvbox" },
    current_item = "tokyonight",
    callback = function(ok, index)
        if ok then
            print("Selected index:", index)
        end
    end,
})
```

Items can be plain strings or `SelectItem` tables:

```lua
items = {
    { label = "catppuccin", icon = "󰄛" },
    {
        label = "tokyonight",
        icon = "󰖔",
        hl = {
            active = { fg = "#7aa2f7", bold = true },
            inactive = { fg = "#565f89" },
        },
    },
}
```

#### `multiselect`

Pick multiple items. `<Space>` toggles, `<CR>` confirms.

```lua
require("lvim-utils.ui").multiselect({
    title = "Enable LSP servers",
    items = { "lua_ls", "tsserver", "pyright" },
    initial_selected = { lua_ls = true },
    callback = function(ok, selected)
        -- selected = table<string, boolean>
        if ok then
            vim.print(selected)
        end
    end,
})
```

#### `input`

Free-text input field.

```lua
require("lvim-utils.ui").input({
    title = "Project name",
    placeholder = "my-project",
    callback = function(ok, value)
        if ok then
            print(value)
        end
    end,
})
```

#### `confirm`

Yes/no dialog (a two-item select). The default choice is focused on open; cancelling (`<Esc>`) resolves to `false`.

```lua
require("lvim-utils.ui").confirm({
    prompt = " Delete file?",
    yes = "Delete", -- optional labels
    no = "Cancel",
    default_no = true, -- focus "No" on open
    callback = function(yes)
        if yes then
            -- ...
        end
    end,
})
```

#### `tabs`

Tabbed view. Supports two content modes:

**Simple items** — pick one item per tab:

```lua
require("lvim-utils.ui").tabs({
    title = "Package manager",
    tabs = {
        { label = "Installed", items = { "lazy.nvim", "mason.nvim" } },
        { label = "Updates", items = { "blink.cmp" } },
    },
    callback = function(ok, res)
        -- res = { tab, index, item }
    end,
})
```

**Typed rows** — settings-style UI with bool toggles, selects, number inputs, and actions:

```lua
require("lvim-utils.ui").tabs({
    title = "Settings",
    tabs = {
        {
            label = "Editor",
            rows = {
                { type = "spacer", label = "Appearance" },
                { type = "bool", name = "cursorline", label = "Cursor line", value = true },
                { type = "bool", name = "cursorline", label = "With icon", value = true, icon = "󰇷" },
                {
                    type = "select",
                    name = "colorscheme",
                    label = "Colorscheme",
                    value = "catppuccin",
                    options = { "catppuccin", "tokyonight", "gruvbox" },
                },
                { type = "int", name = "scrolloff", label = "Scroll offset", value = 8 },
                { type = "float", name = "timeout", label = "Timeout (s)", value = 2.0 },
                { type = "string", name = "exclude_ft", label = "Exclude ft", value = "markdown" },
                { type = "spacer_line" },
                { type = "action", label = "Reset to defaults", run = function() end },
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

**Row fields**

| Field     | Type       | Description                                             |
| --------- | ---------- | ------------------------------------------------------- |
| `type`    | `RowType`  | Row type (see table below)                              |
| `name`    | `string?`  | Key in the callback snapshot                            |
| `label`   | `string?`  | Display text                                            |
| `icon`    | `string?`  | Optional secondary icon shown between type icon & label |
| `value`   | `any`      | Current value                                           |
| `default` | `any`      | Fallback value when `value` is nil                      |
| `options` | `string[]` | Choices for `select` type                               |
| `run`     | `function` | Callback on change/execute                              |
| `hl`      | `table?`   | `{ active?: HlDef, inactive?: HlDef }` per-row override |

**Row types**

| Type               | Input method            | Value     |
| ------------------ | ----------------------- | --------- |
| `bool` / `boolean` | `<CR>` toggles          | `boolean` |
| `select`           | `<Tab>` / `<BS>` cycles | `string`  |
| `int` / `integer`  | `<CR>` opens input      | `integer` |
| `float` / `number` | `<CR>` opens input      | `number`  |
| `string` / `text`  | `<CR>` opens input      | `string`  |
| `action`           | `<CR>` executes         | —         |
| `spacer`           | non-interactive label   | —         |
| `spacer_line`      | horizontal divider      | —         |

Set `horizontal_actions = true` to render all `action` rows as a button bar at the bottom.

#### `info`

Read-only scrollable info window (a single-panel `frame`). Content is a string or a list of lines, with optional per-span highlighting.

```lua
local buf, win = require("lvim-utils.ui").info({ "Title", "", "Some content." }, { title = "About" })
```

| Option              | Description                                                                                            |
| ------------------- | ----------------------------------------------------------------------------------------------------- |
| `title`             | Border-title text (`false` → no title)                                                                |
| `width` / `height`  | FIXED size (a fraction ≤ 1 of the screen, or an absolute count); omit either for auto-fit             |
| `highlights`        | `{ line, col_start, col_end, group }` (or positional `{ row, c0, c1, hl }`); `col_end = -1` = line end |
| `footer_items`      | Extra footer action buttons `{ { key, name, run } }`, shown before the standard `q close`              |
| `hide_cursor`       | Hide the hardware cursor (read-only viewer; the active row still reads via cursorline)                 |
| `footer`            | `false` → no footer bar                                                                                |
| `on_open(buf, win)` | Called after the window opens (set window-local options, extra keymaps, folds…)                       |
| `border` / `close_keys` / `keymaps` | Frame overrides                                                                        |

#### `close_info`

Programmatically close an info window returned by `ui.info()`.

```lua
local buf, win = require("lvim-utils.ui").info(lines, opts)
-- later:
require("lvim-utils.ui").close_info(win)
```

#### Popup positioning

All popup functions accept a `position` option (overrides the global default):

| Value      | Behaviour                                           |
| ---------- | --------------------------------------------------- |
| `"editor"` | Centered in the full Neovim editor area (default)   |
| `"win"`    | Centered within the current window                  |
| `"cursor"` | Below the cursor when space allows, otherwise above |

```lua
require("lvim-utils.ui").select({
    title = "Pick one",
    items = { "a", "b", "c" },
    position = "cursor",
    callback = function(ok, idx) end,
})
```

#### `ui.new()` — isolated instances

Create an independent UI instance with its own config overrides. All other modules (`notify`, `highlight`, `cursor`, `colors`, `gx`) are global-only.

Useful when multiple plugins share lvim-utils but need different colors, icons, or keymaps.

```lua
local my_ui = require("lvim-utils.ui").new({
    highlights = {
        LvimUiNormal = { bg = "#1a1a2e", fg = "#eee" },
        LvimUiTitle = { fg = "#e94560", bold = true },
        LvimUiBorder = { fg = "#e94560" },
    },
    icons = {
        bool_on = "✓",
        bool_off = "✗",
    },
})

my_ui.select({ title = "Pick", items = { "a", "b" }, callback = function(ok, idx) end })
my_ui.multiselect({ ... })
my_ui.input({ ... })
my_ui.tabs({ ... })
my_ui.info(lines, opts)
```

Instance `highlights` override the global `LvimUi*` groups **only for popups opened through that instance**. Inline table definitions (e.g. `{ fg = "#ff0000" }`) are registered in the highlight registry and survive colorscheme changes.

#### UI config

| Key          | Default                  | Description                                 |
| ------------ | ------------------------ | ------------------------------------------- |
| `border`     | `{ "", "", "", " ", … }` | Border style (string or 8-element array)    |
| `position`   | `"editor"`               | Default popup position                      |
| `width`      | `0.8`                    | Popup width as fraction of editor           |
| `max_width`  | `0.8`                    | Max width cap                               |
| `height`     | `0.8`                    | Popup height as fraction                    |
| `max_height` | `0.8`                    | Max height cap                              |
| `max_items`  | `15`                     | Max visible items before scrolling          |
| `markview`   | `false`                  | Enable markview.nvim rendering in info mode |
| `icons`      | see below                | Icon overrides                              |
| `labels`     | see below                | Footer label overrides                      |
| `keys`       | see below                | Keymap overrides                            |

**Default icons**

| Key              | Default  | Used for                        |
| ---------------- | -------- | ------------------------------- |
| `bool_on`        | `󰄬`      | Bool row — true                 |
| `bool_off`       | `󰍴`      | Bool row — false                |
| `select`         | `󰘮`      | Select row                      |
| `number`         | `󰎠`      | Int / float row                 |
| `string`         | `󰬴`      | String row                      |
| `action`         | ``       | Action row                      |
| `spacer`         | `──────` | Spacer row prefix               |
| `multi_selected` | `󰄬`      | Checked multiselect item        |
| `multi_empty`    | `󰍴`      | Unchecked multiselect item      |
| `current`        | `➤`      | Current item indicator (select) |

**Callback signatures**

| Mode           | `callback(ok, result)`               |
| -------------- | ------------------------------------ |
| `select`       | `result` = `integer` (1-based index) |
| `multiselect`  | `result` = `table<string, boolean>`  |
| `input`        | `result` = `string`                  |
| `tabs` (items) | `result` = `{ tab, index, item }`    |
| `tabs` (rows)  | `result` = `table<name, value>`      |
| `info`         | returns `buf, win` directly          |

**`M.peek(opts)` — two-pane location navigator**

A collapsible list of source locations grouped by file (header = file icon + name + directory +
count) on one side and a LIVE preview of the focused location on the other. An expanded group's
rows are plain source text behind a `▏` guide (no line numbers); the preview shows its real
buffer WITH line numbers, so syntax/treesitter highlighting comes for free. The look is
glance-flat — only the centred title is tinted. Two presentations via `opts.mode`: `"split"`
(embedded splits at the bottom) or `"float"` (detached floating container with an optional
dimmed backdrop).

Expansion is set by `ui.peek.expand`: `"auto"` keeps only the focused group open and lets it
follow the cursor; `"manual"` toggles groups open/closed by click or `<CR>` on their header.

```lua
require("lvim-utils.ui").peek({
    title = "References",
    mode = "split", -- or "float"
    items = {
        -- 1-based lnum/col; end_lnum/end_col optional (highlight the match range).
        -- icon/icon_hl (optional) render a glyph before the row text (e.g. a severity sign);
        -- severity (optional) is a free caller tag usable by filter-bar predicates.
        { filename = "/abs/path.lua", lnum = 12, col = 7, end_col = 18, text = "local foo = 1" },
        { filename = "/abs/other.lua", lnum = 3, col = 1, text = "require('x')" },
    },
    -- optional; default jumps in the origin window
    on_jump = function(item, cmd) end, -- cmd = "edit" | "split" | "vsplit" | "tabedit"
})
```

Items are grouped by `filename` (first-seen order). Each group header is a fold icon + the file
name (green) + its directory (yellow) + a bracketed `[count]` painted in the **active filter's
colour**. A filter with no matches shows a `No <Filter> <kind>` message (in that filter's colour)
instead of a blank list, and the preview pane clears. Returns `false` when `items` is empty.
List keys (configurable via `ui.peek.keys`): `j`/`k` move, `<Tab>`/`<S-Tab>` jump between file
groups, `<CR>` open a location (or fold a header in manual mode), `s`/`v`/`t` open in
split/vsplit/tab, `<C-l>`/`<C-h>` move focus between the panes, `f` cycle the filter bar's primary
group, `q` close. The focused pane's keys are also advertised on the container's bottom-border
footer. The mouse works too: single-click selects (or folds a header, or toggles a filter button),
double-click opens, and **dragging horizontally resizes the split** (the boundary follows the
pointer). The left/right ratio is set by `list_width` (a fraction of the region — `0.4` = 40% list
/ 60% preview — or an absolute column count when `> 1`); `list_position` chooses which side the
list sits on. The panel is an outer container (8-element `border`, centred `title`) holding the two
bordered inner panes. Appearance is configured under `ui.peek` (`mode`, `expand`, `list_position`,
`list_width`, `preview_height`, `preview_number`, `float`, `border`, `list_border`,
`preview_border`, `title`, `footer`, `group_icon_open`, `group_icon_closed`, `guide_icon`).

**Filter bar (`opts.bar`)** — an optional row of toggle buttons centred on the whole panel under
the title, rendered installer-style with a bracketed hotkey letter per button
(`[A]ll 5  [E]rror 2  [W]arn 1 …`). Each *group* of buttons tracks one active button; the effective
filter is the AND of every group's active-button `predicate(item)`. A button's bracketed letter (its
`key`, else the label's first letter) jumps straight to it; clicking it, or `f` to cycle the
`primary` group, also works — all re-filter the list **live** without reopening, and each button
shows its live count. This is what the lvim-lsp diagnostics navigator uses for its scope
(Workspace/Buffer) + severity (All/Error/Warn/…) filters.

```lua
require("lvim-utils.ui").peek({
    title = "Diagnostics",
    mode = "float",
    items = items, -- each carries icon/icon_hl/severity
    bar = {
        groups = {
            {
                id = "severity",
                active = "all",
                primary = true, -- the `f` key cycles this group
                buttons = {
                    {
                        id = "all",
                        label = "All",
                        predicate = function()
                            return true
                        end,
                    },
                    {
                        id = "error",
                        label = "Error",
                        predicate = function(it)
                            return it.severity == 1
                        end,
                        hl = "MyFilterError",
                        hl_active = "MyFilterErrorActive",
                    },
                },
            },
        },
    },
})
```

---

### `notify`

Notification hub: intercepts `vim.notify` and `print`, routes messages through pluggable printers, and ships two built-in printers:

- **toast** — one floating panel per severity level, stacked at the bottom-right corner
- **history** — ring-buffer; browsable with `M.history()`

Works out-of-the-box after `require()` — no `setup()` call needed.

```lua
-- Standard usage (intercepted automatically)
vim.notify("Hello!", vim.log.levels.INFO)
vim.notify("Oops", vim.log.levels.ERROR, { title = "My Plugin", timeout = 0 })
print("debug message") -- routed as DEBUG level

-- Browse history
require("lvim-utils.notify").history()

-- Get raw history table
local entries = require("lvim-utils.notify").get_history()
-- entries[i] = { msg, level, opts, time }
```

The history window shows only active progress channels (channels with content). Channels with no active content are not displayed.

#### Progress channels

Independent floating panels for long-running operations (LSP, builds, etc.). A panel is shown only while its content is non-empty; it closes automatically when cleared.

```lua
local notify = require("lvim-utils.notify")

-- Register a named channel
notify.progress_register("lsp", {
    name = "LSP",
    icon = "󰄭",
    header_hl = "LvimNotifyHeaderInfo",
})

-- Update content (auto-registers if not yet registered)
notify.progress_update("lsp", {
    "  Indexing workspace…",
    "  42 / 300 files",
})

-- Clear content and close the panel
notify.progress_clear("lsp")

-- Clear all progress channels at once
notify.progress_clear_all()
```

#### Custom panels

Push messages to a named panel with custom appearance, independent of the standard severity levels.

```lua
local notify = require("lvim-utils.notify")

notify.register_panel("build", {
    name = "Build",
    icon = "󰗼",
    hl = "LvimNotifyInfo",
    header_hl = "LvimNotifyHeaderInfo",
})

notify.push("build", "Compiling…", { timeout = 0 })
notify.push("build", "Done.", { timeout = 3000 })
```

#### Custom printers

```lua
local notify = require("lvim-utils.notify")

notify.add_printer("my_printer", function(msg, level, opts)
    io.stderr:write("[" .. tostring(level) .. "] " .. msg .. "\n")
end)

notify.remove_printer("my_printer")
notify.has_printer("my_printer") -- → boolean
```

**API**

| Function                             | Description                                               |
| ------------------------------------ | --------------------------------------------------------- |
| `setup(opts)`                        | Configure the notify module                               |
| `notify(msg, level, opts)`           | Dispatch a notification through all printers              |
| `get_history()`                      | Return a deep copy of the history ring-buffer             |
| `clear()`                            | Clear the history ring-buffer                             |
| `history()`                          | Open the history browser popup                            |
| `add_printer(name, fn)`              | Register a custom printer function                        |
| `remove_printer(name)`               | Unregister a printer by name                              |
| `has_printer(name)`                  | Check if a printer is registered                          |
| `push(key, msg, opts)`               | Push directly to a panel by key or `vim.log.levels` value |
| `register_panel(key, opts)`          | Register a custom panel with its own appearance           |
| `progress_register(id, opts)`        | Register a named progress channel                         |
| `progress_update(id, lines, marks?)` | Update content for a progress channel                     |
| `progress_clear(id)`                 | Clear content and close a progress channel's panel        |
| `progress_clear_all()`               | Clear all progress channels                               |

#### Notify config

| Key                | Default                  | Description                                               |
| ------------------ | ------------------------ | --------------------------------------------------------- |
| `timeout`          | `5000`                   | Auto-dismiss delay in ms; `0` = sticky                    |
| `dedup`            | `true`                   | Collapse identical consecutive toasts into one `×N` badge |
| `min_width`        | `50`                     | Minimum panel width in columns                            |
| `max_width`        | `100`                    | Maximum panel width in columns                            |
| `padding`          | `1`                      | Horizontal padding inside the panel                       |
| `bottom_margin`    | `1`                      | Rows from the bottom of the editor                        |
| `panel_gap`        | `0`                      | Rows between stacked level panels                         |
| `border`           | `"none"`                 | Border style passed to `nvim_open_win`                    |
| `zindex`           | `1000`                   | Floating window z-index                                   |
| `separator`        | `"─"`                    | Character repeated as entry separator                     |
| `max_history`      | `100`                    | Ring-buffer size                                          |
| `override_print`   | `false`                  | Replace global `print()` (always routed as DEBUG)         |
| `ext_messages`     | `true`                   | Intercept all Neovim messages via `vim.ui_attach`         |
| `ext_echo_timeout` | `3000`                   | Timeout for echo/info-level ext messages                  |
| `ext_kinds`        | see below                | Per-kind behaviour: `"toast"`, `"history"`, or `"ignore"` |
| `printers`         | `{ "toast", "history" }` | Active printers on load                                   |
| `icons`            | see below                | Level icons                                               |
| `level_names`      | see below                | Singular/plural level names in the header bar             |

**Default `ext_kinds` behaviour**

| Kind                                                     | Default     |
| -------------------------------------------------------- | ----------- |
| `emsg`, `echoerr`, `lua_error`, `rpc_error`, `shell_err` | `"toast"`   |
| `wmsg`, `echomsg`, `echo`, `bufwrite`, `undo`            | `"toast"`   |
| `shell_out`, `lua_print`, `verbose`, `""`                | `"history"` |
| `search_count`, `search_cmd`, `wildlist`, `completion`   | `"ignore"`  |

---

### `quit`

Quit dialog that lists all unsaved normal buffers as toggleable rows. The user chooses which files to save, then picks an action from a horizontal button bar.

```lua
require("lvim-utils.quit").open()
```

- Quits immediately with `:qa` when there are no unsaved buffers.
- Unnamed buffers trigger a `vim.ui.input` prompt for a save path.

**Actions**

| Button               | Behaviour                                   |
| -------------------- | ------------------------------------------- |
| Save Selected & Quit | Writes checked buffers, then `:qa` / `:qa!` |
| Quit without Saving  | `:qa!`                                      |
| Cancel               | Closes the dialog                           |

---

### `gx`

Universal "open under cursor" that replaces Neovim's built-in `gx`. Resolves URLs, local file paths (with optional `:line:col` suffix), bare domain/repo references (`github.com/foo/bar`), and paths inside file-manager buffers via registered adapters. Falls back to a proximity scan of nearby lines.

```lua
require("lvim-utils.gx").setup()
require("lvim-utils.gx").map_default() -- binds gx → :GxOpen
```

Or via the main setup:

```lua
require("lvim-utils").setup({
    gx = {
        force_system_open_local = true,
        dir_open_strategy = "system",
    },
})
```

**Built-in adapters**

| Adapter      | Filetype                  |
| ------------ | ------------------------- |
| `neo_tree`   | `neo-tree`                |
| `nvim_tree`  | `NvimTree`                |
| `oil`        | `oil`                     |
| `mini_files` | `minifiles` / `MiniFiles` |
| `netrw`      | `netrw`                   |

**Custom adapter**

```lua
require("lvim-utils.gx").register_adapter({
    name = "my_fm",
    detect = function(ctx)
        return ctx.filetype == "my-filemanager"
    end,
    get = function(ctx)
        return { path = "/some/resolved/path", type = "file" }
    end,
})
```

**Commands**

| Command            | Description                                     |
| ------------------ | ----------------------------------------------- |
| `:GxOpen [target]` | Open target under cursor (or explicit argument) |
| `:GxOpenDiag`      | Print context, adapter, and first 10 candidates |

**Config options**

| Key                       | Default        | Description                                     |
| ------------------------- | -------------- | ----------------------------------------------- |
| `highlight_match`         | `true`         | Briefly flash the matched token                 |
| `highlight_duration_ms`   | `300`          | Flash duration in ms                            |
| `system_open_cmd`         | `nil`          | Override opener (`xdg-open` / `open` / `start`) |
| `force_system_open_local` | `true`         | Use system opener for local files               |
| `allow_bare_domains`      | `true`         | Open `domain.tld/path` as HTTPS URL             |
| `icon_guard`              | `true`         | Skip Nerd Font glyph tokens                     |
| `dir_open_strategy`       | `"system"`     | `"system"` or `"edit"` for directories          |
| `search_forward_if_none`  | `true`         | Scan lines below cursor as fallback             |
| `search_backward_if_none` | `true`         | Scan lines above cursor as fallback             |
| `search_max_lines`        | `60`           | Max lines to scan in each direction             |
| `pattern`                 | `[%w%._~/#…]+` | Lua pattern for token extraction                |
| `adapters`                | all `true`     | Enable/disable built-in adapters by name        |

### `utils`

Shared helpers used across the lvim-tech plugins.

```lua
-- Deep-merge `opts` into `target` in place: nested maps merge recursively, while
-- lists and scalars are replaced wholesale (an override list IS the list — not an
-- index-merge). Returns `target`.
require("lvim-utils.utils").merge(target, opts)
```

Each plugin's `setup()` uses it to merge user options into its live config table, so
every `require("<plugin>.config")` reader sees the effective values.

---

## Highlight Groups

All groups are self-themed from the [`colors`](#colors) palette via [`highlight.bind`](#highlight)
and reapplied on every palette / colorscheme change. They are applied with `default = true`,
so a colorscheme that defines them (or the user) wins — the palette only fills in what is not
already themed. Override any group explicitly via `setup({ highlights = { ... } })`.

Every coloured chrome cell follows one tint style: `fg = accent` over `bg = blend(accent, bg_dark, t)`
— a **strong** tint (`0.2`) for prominent cells (title/name boxes, active tabs/buttons, key badges)
and a **light** tint (`0.1`) for secondary ones (subtitles, inactive, header stripes, labels,
separators). Adjust both via `setup({ ui = { tint = { strong = 0.2, light = 0.1 } } })`.

### UI popup groups

| Group                       | Used for                                    |
| --------------------------- | ------------------------------------------- |
| `LvimUiNormal`              | Popup background                            |
| `LvimUiBorder`              | Popup border                                |
| `LvimUiSeparator`           | Header / footer separator lines             |
| `LvimUiTitle`               | Popup title                                 |
| `LvimUiSubtitle`            | Popup subtitle                              |
| `LvimUiInfo`                | Info line below subtitle                    |
| `LvimUiCursorLine`          | Selected row background                     |
| `LvimUiInput`               | Input field row                             |
| `LvimUiSpacer`              | Spacer / section label rows                 |
| `LvimUiFooter`              | Footer key-hints line                       |
| `LvimUiFooterKey`           | Key indicator in footer                     |
| `LvimUiFooterLabel`         | Label text in footer                        |
| `LvimUiTabActive`           | Active tab label background                 |
| `LvimUiTabInactive`         | Inactive tab label                          |
| `LvimUiTabIconActive`       | Icon inside active tab                      |
| `LvimUiTabIconInactive`     | Icon inside inactive tab                    |
| `LvimUiTabTextActive`       | Text inside active tab                      |
| `LvimUiTabTextInactive`     | Text inside inactive tab                    |
| `LvimUiButtonActive`        | Active action button background             |
| `LvimUiButtonInactive`      | Inactive action button background           |
| `LvimUiButtonIconActive`    | Icon inside active button                   |
| `LvimUiButtonIconInactive`  | Icon inside inactive button                 |
| `LvimUiButtonTextActive`    | Text inside active button                   |
| `LvimUiButtonTextInactive`  | Text inside inactive button                 |
| `LvimUiRowIconActive`       | Type icon in active tabs row                |
| `LvimUiRowIconInactive`     | Type icon in inactive tabs row              |
| `LvimUiRowItemIconActive`   | Secondary `row.icon` in active tabs row     |
| `LvimUiRowItemIconInactive` | Secondary `row.icon` in inactive tabs row   |
| `LvimUiRowTextActive`       | Label text in active tabs row               |
| `LvimUiRowTextInactive`     | Label text in inactive tabs row             |
| `LvimUiItemIconActive`      | Icon for active select / multiselect item   |
| `LvimUiItemIconInactive`    | Icon for inactive select / multiselect item |
| `LvimUiItemTextActive`      | Text for active select / multiselect item   |
| `LvimUiItemTextInactive`    | Text for inactive select / multiselect item |
| `LvimUiCheckboxSelected`    | Checked multiselect checkbox symbol         |
| `LvimUiCheckboxEmpty`       | Unchecked multiselect checkbox symbol       |
| `LvimUiPeekNormal`          | Peek pane background                        |
| `LvimUiPeekBorder`          | Peek pane border                            |
| `LvimUiPeekTitle`           | Brand title on the container border         |
| `LvimUiPeekKind`            | List winbar kind (e.g. "References")        |
| `LvimUiPeekKindBar`         | List winbar bar + count                     |
| `LvimUiPeekFile`            | Preview winbar file name                    |
| `LvimUiPeekFileBar`         | Preview winbar bar + path                   |
| `LvimUiPeekGroup`           | Per-file group header                       |
| `LvimUiPeekGroupIcon`       | Fold chevron in the group header            |
| `LvimUiPeekDir`             | Directory path in the group header          |
| `LvimUiPeekCount`           | Count in the group header                   |
| `LvimUiPeekText`            | Location row text                           |
| `LvimUiPeekGuide`           | Vertical guide (`▏`) before expanded rows   |
| `LvimUiPeekCursorLine`      | Focused list row background                 |
| `LvimUiPeekMatch`           | Matched range (both list and preview)       |
| `LvimUiPeekFooterKey`       | Key badge on the bottom-border footer       |
| `LvimUiPeekFooterLabel`     | Label on the bottom-border footer           |
| `LvimUiPeekFilterActive`    | Active filter-bar button                    |
| `LvimUiPeekFilterInactive`  | Inactive filter-bar button                  |

### Notify groups

| Group                   | Used for                         |
| ----------------------- | -------------------------------- |
| `LvimNotifyNormal`      | Notify panel background          |
| `LvimNotifyTitle`       | Notify panel title text          |
| `LvimNotifyInfo`        | Info-level content               |
| `LvimNotifyWarn`        | Warn-level content               |
| `LvimNotifyError`       | Error-level content              |
| `LvimNotifyDebug`       | Debug-level content              |
| `LvimNotifyTitleInfo`   | Info-level entry title           |
| `LvimNotifyTitleWarn`   | Warn-level entry title           |
| `LvimNotifyTitleError`  | Error-level entry title          |
| `LvimNotifyTitleDebug`  | Debug-level entry title          |
| `LvimNotifyHeaderInfo`  | Info-level panel header bar      |
| `LvimNotifyHeaderWarn`  | Warn-level panel header bar      |
| `LvimNotifyHeaderError` | Error-level panel header bar     |
| `LvimNotifyHeaderDebug` | Debug-level panel header bar     |
| `LvimNotifySepInfo`     | Info-level entry separator line  |
| `LvimNotifySepWarn`     | Warn-level entry separator line  |
| `LvimNotifySepError`    | Error-level entry separator line |
| `LvimNotifySepDebug`    | Debug-level entry separator line |

### Other

| Group                   | Used for                           |
| ----------------------- | ---------------------------------- |
| `LvimUtilsHiddenCursor` | Transparent cursor (cursor module) |

---

## Default Keymaps (UI popups)

| Key              | Action                                 |
| ---------------- | -------------------------------------- |
| `j` / `k`        | Navigate rows / items                  |
| `<CR>`           | Confirm / toggle / execute             |
| `<Esc>` / `q`    | Cancel / close                         |
| `l` / `h`        | Next / prev tab (or action button)     |
| `<Tab>` / `<BS>` | Cycle select option forward / backward |
| `<Space>`        | Toggle item (multiselect)              |

All keys are configurable via `ui.keys` in `setup()`.

---

## Health

```vim
:checkhealth lvim-utils
```

Reports Neovim version, `termguicolors`, whether `lvim-colorscheme` is driving the palette (vs the bundled one), whether the UI groups are themed, and ext_cmdline conflicts when the self-rendered cmdline is enabled.
