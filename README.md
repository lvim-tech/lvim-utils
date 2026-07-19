# lvim-utils

The **base plugin** of the lvim-tech set — the shared foundation every other plugin builds on. It owns
the live colour palette, the central highlight-group factory (read **by name** by every other plugin), the
canonical cursor-hiding mechanism, the ecosystem-wide mouse-selection lock, the foreground-dim primitives,
the dock-stack manager, and the unified persistence store.

Modules:

- **`utils`** — shared helpers (`merge`, `match_indices`).
- **`colors`** — the live palette (bundled dark/light, synced from `lvim-colorscheme` when present).
- **`highlight`** — the group registrar (`define` / `register` / `bind` — self-theming on `ColorScheme`).
- **`config`** — the central highlight-group factory + the cursor / dock / section / ui live config.
- **`cursor`** — hide the hardware cursor by registered filetype (the ONE cursor system).
- **`mouse`** — the panel mouse-selection lock (a click on a rendered panel must never start Visual).
- **`dim`** — foreground-dim / darken namespaces + the focus-aware surface backdrop.
- **`dock`** — the dock-stack manager (area / bottom / float coordination + `:LvimDock`).
- **`store`** — one persistence model, three backends (file / json / sqlite) + mirror / watch.
- **`icons`** — a provider facade (prefers `lvim-icons`, auto-falls back to any installed icon provider).
- **`health`** — `:checkhealth lvim-utils`.

> The former `ui` / `notify` / `msgarea` / `picker` / `dashboard` / `cmdline` / `chrome` / `fuzzy` / `gx`
> modules moved to their **own plugins** in the monorepo split — see [Split-out modules](#split-out-modules).

---

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-utils/blob/main/LICENSE)

## Installation

Requires Neovim >= 0.12.

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
})
require("lvim-utils").setup({})
```

`setup()` is optional and configures **only the base**: it merges the palette + the base config in place (via
[`utils.merge`](#utils)), self-themes the group map from the fully-configured palette, and registers the
cursor / dock / mouse layers. Every module is usable directly — `require("lvim-utils.colors")`,
`require("lvim-utils.store")`, etc. Readers of `require("lvim-utils.config").<key>` always see the effective
(post-merge) values.

## `setup()` options

| Key          | Description                                                                                  |
| ------------ | -------------------------------------------------------------------------------------------- |
| `colors`     | Override palette colours (see [colors](#colors)). Sticky across background flips + theme sync |
| `highlights` | Register highlight-group overrides, applied hard (force)                                      |
| `cursor`     | Cursor-hiding config — `ft` / `panel_ft` / `hide_on_cmdline` (see [cursor](#cursor))          |
| `dock`       | The dock-stack manager config (see [dock](#dock))                                             |
| `section`    | Collapsible section-header tinting, global for every lvim-tech fold                           |
| `ui`         | The shared chrome theme spec — every tint strength + accent the UI paints with                |

### Full default config

Every option at its default value, mirroring `lua/lvim-utils/config/{cursor,dock,ui}.lua` + `section`:

```lua
require("lvim-utils").setup({
    -- Palette overrides (any key from `colors`); sticky over background flips + lvim-colorscheme syncs.
    colors = {},
    -- Highlight-group overrides applied with force (win over the self-themed defaults).
    highlights = {},

    -- Cursor hiding (lvim-utils.cursor). Plugins usually SELF-register their panels via cursor.register();
    -- keep these lists for shared/generic filetypes only.
    cursor = {
        ft = {}, -- transient popups: hide whenever such a buffer is visible in ANY window
        panel_ft = {}, -- persistent side panels: hide only while the panel is the CURRENT window
        hide_on_cmdline = false, -- hide the hardware cursor while the command-line is active
    },

    -- Collapsible section-header tinting, global for every lvim-tech fold header.
    section = {
        tint = 0.1, -- rest band blend toward the accent (0..1)
        tint_hover = 0.2, -- hover band blend toward the accent (0..1)
    },

    -- The dock-stack manager (area / bottom / float coordination). ONE consumer visible per layout;
    -- a key cycles the visible one. `geometry` is the single authority for every docked/floated surface size.
    dock = {
        enable = true, -- bind the global cycle keymaps on dock.setup()
        keys = {
            cycle_next = "<Leader>n", -- cycle to the NEXT consumer in the current layout's stack
            cycle_prev = "<Leader>p", -- cycle to the PREVIOUS one
            close = "<Leader>x", -- KILL the visible consumer + reveal the next per MRU
            menu = "<Leader>m", -- open a menu of every live dock consumer across the three stacks
        },
        default_layout = "area", -- layout cycle() targets when no dock is focused
        capture_leader = true, -- install the buffer-local <Leader> owner in a docked window
        geometry = {
            float = {
                height = 0.7,
                width = 0.9,
                height_auto = true, -- height is a MAXIMUM (content-fit up to it)
                width_auto = false, -- width is EXACT
                backdrop = { enabled = true, mode = "dim", dim = { amount = 0.4 }, darken = { amount = 0.3 } },
                keep_focus = false, -- move focus to the opened file
                auto_hide = true, -- one-shot modal: close on open
            },
            area = {
                height = 0.5,
                height_peek = 0.7, -- height cap of the `dynamic` preview peek float above the list
                height_auto = true,
                backdrop = { enabled = true, mode = "dim", dim = { amount = 0.4 }, darken = { amount = 0.3 } },
                keep_focus = true, -- keep focus IN the dock after opening a file
                auto_hide = false, -- the dock STAYS open
            },
            bottom = {
                height = 0.5,
                height_peek = 0.7,
                height_auto = true,
                backdrop = { enabled = true, mode = "dim", dim = { amount = 0.4 }, darken = { amount = 0.3 } },
                keep_focus = true,
                auto_hide = false,
            },
        },
    },

    -- The shared chrome theme spec: every tint strength + every accent the UI paints with, named by ROLE.
    -- TINT = how far an accent is blended toward the panel bg (0 = plain bg, 1 = the pure accent).
    -- ACCENT = a palette KEY (tracks the live theme) or a literal "#rrggbb".
    ui = {
        tint = {
            cursorline = 0.04, -- the active list row's wash (the faintest tint)
            body = 0.05, -- a secondary / inactive / body cell
            row_odd = 0.05, -- odd list-stripe row
            row_even = 0.08, -- even list-stripe row
            row_sel = 0.15, -- selected list row
            bar_fill = 0.08, -- the strip under a bar's buttons
            separator = 0.12, -- a bar-group separator box
            input = 0.05, -- the typed-text field of an input popup
            help_desc = 0.05, -- the description box of a cheatsheet row
            help_key = 0.1, -- its key box (and the active row's description)
            hover = 0.15, -- a mouse hover
            match = 0.25, -- a fuzzy-match span
            strong = 0.2, -- a prominent / active cell
            label = 0.2, -- a badge's label box
            badge = 0.3, -- a key badge / icon box / counter
            selection = 0.35, -- the keyboard selection over a focused bar button
            bright = 0.4, -- an active text box (a tab's text, a file name)
            icon = 0.5, -- an icon box / a hovered badge
            deep = 0.6, -- a chevron / footer-separator box
            dim = 0.45, -- a disabled value's fg blend toward bg
            row_dim = 0.5, -- a disabled row's fg blend
            path_dim = 0.8, -- a file row's leading directory
            filter_off = 0.6, -- an inactive filter button's fg
        },
        accent = {
            title = "blue",
            subtitle = "yellow",
            border = "blue",
            separator = "red",
            cursorline = "blue",
            spacer = "magenta",
            input = { bg = "blue", text = "fg" },
            help = { odd = "blue", even = "yellow" },
            tab = { box = "red", icon = "blue", text = "yellow" },
            button = "orange",
            row = "yellow",
            row_icon = "teal",
            item = "yellow",
            path = "blue",
            footer = { key = "blue", label = "yellow", sep = "red", chevron = "yellow" },
            bar_fill = "yellow",
            bar_sep = "blue",
            picker = {
                prompt = "blue",
                input = "blue",
                cursor = "blue",
                marker = "red",
                separator = "red",
                preview_dir = "yellow",
            },
            peek = {
                title = "blue",
                icon = "blue",
                kind = "green",
                file = "yellow",
                match = "blue",
                filter = "yellow",
                count = "green",
            },
            notify = { info = "blue", warn = "orange", error = "red", debug = "purple" },
            msgarea = {
                title = "blue",
                row_odd = "yellow",
                row_even = "yellow",
                match = "red",
                kind = "cyan",
                marker = "red",
            },
            dashboard = {
                header = "green_dark",
                footer = "red_dark",
                icon = "red_dark",
                key = "orange",
                desc = "cyan",
                title = "green_dark",
                file = "red_dark",
                dir = "comment",
                special = "purple",
            },
        },
        -- The docked panel's full-width TITLE bar.
        title = { accent = "blue", tint = 0.2 },
    },
})
```

---

## Modules

### `colors`

The public colour palette. Bundled muted **dark** and **light** palettes are used standalone (swapped
automatically on `&background` change); when `lvim-colorscheme` is present the palette **syncs from the active
theme** (and follows its `transparent` state). `setup({ colors = {...} })` overrides are **sticky** — re-applied
on top of every base swap and theme sync.

```lua
local c = require("lvim-utils.colors")

local red = c.red -- "#cb4f4f"
local bg_light = c.bg_light -- "#2c3339"
local add = c.git.add
local mixed = c.blend(c.teal, c.bg, 0.3)
```

| Function                 | Description                                                                 |
| ------------------------ | --------------------------------------------------------------------------- |
| `setup(overrides)`       | Override palette colours; re-applies over an already-synced theme, notifies |
| `sync_from_lcs()`        | Pull the palette from `lvim-colorscheme` and fire `on_change` listeners     |
| `on_change(fn)`          | Register a callback fired whenever the palette changes; returns unsubscribe |
| `blend(fg, bg, alpha)`   | Blend two hex colours (alpha 1.0 = fully fg)                                 |
| `lighten(color, amount)` | Blend toward white                                                          |
| `darken(color, amount)`  | Blend toward black                                                          |

### `highlight`

The group registrar. Defines / links highlight groups, and **binds** a factory that rebuilds the whole group
map from the live palette and re-applies it on every `ColorScheme` / `User LvimColorscheme` — so every group
self-themes. Also carries the blend helpers and the fold-header accent / band helpers.

| Function                    | Description                                                              |
| --------------------------- | ------------------------------------------------------------------------ |
| `blend(fg, bg, alpha)`      | Blend two hex colours                                                    |
| `lighten` / `darken`        | Blend toward white / black                                              |
| `define(name, opts)`        | Define a highlight group                                                |
| `define_if_missing(...)`    | Define only if the group does not already exist                        |
| `link(name, link_to)`       | Link a group to another                                                 |
| `get(name)` / `group_exists`| Read a group / test its existence                                      |
| `clear(name)`               | Clear a group                                                          |
| `register(groups, force)`   | Register a table of groups (force = apply hard, not `default`)         |
| `bind(fn)`                  | Bind a factory `fn(colors) -> groups`, re-run on palette change         |
| `setup()`                   | Install the `ColorScheme` autocmd                                       |
| `section_accent(accent)`    | The tinted band for a collapsible fold header (uses `config.section`)  |
| `band_line(parts, sep)`     | Build a full-width tinted band line                                    |

### `cursor`

Hides the hardware cursor whenever a buffer with a **registered filetype** owns the screen, via a dedicated
`LvimUtilsHiddenCursor` group (`blend=100`, 1-cell bar) — imperceptible in GUI and TUI with `termguicolors`.
This is the ONE cursor system; every lvim-tech popup / panel delegates here. Two lists:

- **`ft`** — transient popups: the cursor is hidden whenever such a buffer is visible in **any** window.
- **`panel_ft`** — persistent side panels: hidden **only** while the panel is the **current** window.

**Self-registration is preferred.** A plugin that owns a panel registers its own filetype from its own
`setup()`:

```lua
require("lvim-utils.cursor").register({ panel_ft = { "my-panel" } })
```

`register` also feeds the **live `config.cursor` registry**, so the [mouse](#mouse) selection-lock sees the
panel automatically — even one that never goes through a surface chassis.

| Function                          | Description                                                          |
| --------------------------------- | ------------------------------------------------------------------- |
| `setup(opts)`                     | Register filetypes and install the autocmds                         |
| `register({ ft, panel_ft })`      | Add filetypes at runtime (extends the registry; no autocmd rebuild) |
| `update()`                        | Force-refresh cursor state                                          |
| `mark_input_buffer(buf, v)`       | Keep the cursor visible in `buf` even if its ft is registered       |
| `mark_hide_buffer(buf, v)`        | Hide while `buf` is current, by handle (for shared-ft floats)       |
| `mark_cursor_buffer(buf, frag)`   | Give `buf` a custom `guicursor` fragment while current              |
| `set_cmdline_hide(v)`             | Hide the cursor while the command-line is active                    |

### `mouse`

The ecosystem-wide **mouse-selection lock** for UI panels. A panel is a rendered surface, not text — a mouse
click there must never start Visual (a fast click emits `<2-/3-/4-LeftMouse>`, which natively select word /
line / block and replace the row's cursorline bar with a Visual patch over the label). The lock is **global**
(a buffer-local map only fires when the panel is already current — the wrong case): global `expr` maps decide
by the window **under the pointer**. It reads the same registry the [cursor](#cursor) module uses.

| Function                          | Description                                                             |
| --------------------------------- | ---------------------------------------------------------------------- |
| `setup()`                         | Install the global lock (called from `lvim-utils.setup`)               |
| `lock(buf, opts)`                 | Mark `buf` a locked panel; `opts.scroll` also nops the wheel           |
| `register_click(buf, fn)`         | Register a panel's row-click handler `fn(line, col0, pos, count)`      |
| `should_swallow()`                | True when the current mouse event is over a locked panel — call FIRST from any global mouse map |
| `defer_activation(fn)`            | Defer a window-switching activation until the button is released       |
| `flush_activation()`              | Run (and clear) a deferred activation                                  |

### `dim`

Foreground-dim primitives: a highlight **namespace** whose groups are the global highlights with their
**foreground** muted toward the editor background (backgrounds untouched, so it coexists with `transparent`
and never hides a terminal-composited image underneath). Two flavours — `build` (dim fg) and `darken`
(fg + bg toward a dark colour) — plus the focus-aware **surface backdrop** that mutes every window behind an
open surface and lifts as focus moves out.

| Function                          | Description                                                             |
| --------------------------------- | ---------------------------------------------------------------------- |
| `build(bg_hex, amount, ns?)`      | (Re)build a dim namespace (fg toward bg); returns the ns               |
| `darken(dark_hex, amount, ns?)`   | (Re)build a darken namespace (fg + bg toward dark)                     |
| `set(win, ns?)`                   | Switch `win` onto namespace `ns` (or back to 0)                        |
| `preserve(pattern)`               | Leave groups matching `pattern` unmuted (fg carries data, not colour)  |
| `blend(fg, bg, t)`                | Numeric (0xRRGGBB) blend                                               |
| `apply_backdrop(id, cfg)`         | Apply a focus-aware backdrop behind a consumer's surface              |
| `clear_backdrop(id)`              | Tear a backdrop down, restoring every window                          |
| `refresh_backdrop()`              | Rebuild every backdrop namespace from the live palette (theme change) |
| `suspend(on)` / `on_suspend(cb)`  | Suspend/resume the per-window dim managers (backdrop coordination)     |

### `dock`

The **dock-stack manager**: coordinates the three docking layouts (`area` / `bottom` / `float`) so at most one
consumer is visible per layout, each layout keeps its own MRU stack, and a key cycles the visible one. Every
docked / floated surface reads its **geometry** (size + backdrop + focus behaviour) through `dock.slot(layout)`
— no plugin keeps its own size. See the [full default config](#full-default-config) for `geometry`.

| Function                          | Description                                                            |
| --------------------------------- | --------------------------------------------------------------------- |
| `setup(opts)`                     | Bind the global cycle keymaps per the live config                     |
| `register(consumer)`              | Register a dock consumer (its open/show/close/… callbacks)            |
| `open` / `show` / `hide` / `close`| Drive a consumer's visibility in its layout                          |
| `close_current(layout)`           | Kill the visible consumer of a layout                                |
| `cycle(layout, dir)`              | Cycle the visible consumer in a layout                               |
| `menu(layout)`                    | Open an `lvim-ui.select` of every live consumer                      |
| `reveal(layout)` / `descend()`    | Reveal a layout's stack / descend into a consumer                    |
| `visible` / `stack` / `entries`   | Query the current visible key / a layout's stack / all entries      |
| `slot(layout, opts)`              | Resolve a layout's geometry to a rect (the single size authority)    |
| `set_slot_provider` / `set_handoff` | Register the area-zone provider / the file-open handoff            |

The `:LvimDock` command exposes the same operations from the command line.

### `store`

One persistence model, **three backends**, plus mirroring + cross-instance sync — a **declarative live table**:
declare fields, then read / assign them directly; assignment auto-persists (and auto-mirrors). A `nil`
assignment **clears** the field on every backend.

- **`file`** — a flat `key=value` text file (string values, readable early / externally). Atomic writes.
- **`json`** — one JSON document (typed / nested Lua data, git-friendly). Atomic writes.
- **`sqlite`** — real relational tables + CRUD + versioned migrations (needs `kkharji/sqlite.lua`).

```lua
local s = require("lvim-utils.store").new({
    backend = "sqlite",
    name = "control-center",
    fields = { colorscheme = "lvim_dark", opacity = 0.9 },
    mirror = { colorscheme = vim.fn.stdpath("config") .. "/.theme" }, -- plain file for early read
    watch = true,
    on_change = function(all) end, -- another instance changed the file
})

s.colorscheme = "lvim_light" -- persists to sqlite + writes the .theme mirror
print(s.colorscheme) -- reads from the live cache
s.opacity = nil -- CLEARS the field (falls back to the declared default on reload)
```

Dependency-free **early reads** open no store:

```lua
require("lvim-utils.store").read_file(path) -- a mirror's raw value
require("lvim-utils.store").read_json(path, key) -- a value out of a json store
```

| Function                          | Description                                                            |
| --------------------------------- | --------------------------------------------------------------------- |
| `new(opts)`                       | Open a store as a declarative live table                              |
| `read_file(path)`                 | The raw first-line value of a plain file (early, dependency-free)     |
| `read_json(path, key?)`           | Decode a json store file (whole doc or one key)                       |
| `available()`                     | Whether the sqlite backend is available                              |
| `health(health, mandatory?)`      | Report the sqlite backend in a plugin's `:checkhealth`               |

On the handle: `s:save()`, `s:reload()`, `s:all()`, `s:close()`, `s:is_open()`, `s:path()`, and (sqlite)
`s:find/insert/update/remove/count/exec/transaction`.

### `icons`

A provider **facade** — resolves an icon through `lvim-icons` (preferred) or any other installed icon provider
(auto-detected), falling back to a single built-in glyph when none is installed.

| Function                          | Description                                                            |
| --------------------------------- | --------------------------------------------------------------------- |
| `get(name, opts)`                 | Resolve one icon `{ glyph, hl, color, width, name }`                  |
| `get_icons(opts)`                 | A `key → { icon, color, hl, name }` map over the provider's table    |
| `active(requested?)`              | The concrete provider name that would be used                        |
| `bind(provider, color_mode?)`     | Bind a provider (+ colour mode) once; returns `{ get, get_icons }`   |

### `utils`

| Function                          | Description                                                            |
| --------------------------------- | --------------------------------------------------------------------- |
| `merge(target, opts)`             | Deep-merge in place — maps recurse, **lists + scalars replace**       |
| `match_indices(needle, haystack)` | Case-insensitive subsequence match → 0-based char indices, or nil     |

### `health`

`:checkhealth lvim-utils` verifies truecolor, the Neovim version, palette sync from `lvim-colorscheme`, the
self-themed group map, the active icon provider, and the store backend.

---

## Split-out modules

The monorepo split moved the following into their **own plugins**; configure them via
`require("<plugin>").setup()` (or all at once through `require("lvim-nvim").setup({ ["lvim-<plugin>"] = {…} })`):

| Was `lvim-utils.<x>` | Now                       |
| -------------------- | ------------------------- |
| `ui`                 | `lvim-ui`                 |
| `notify`             | `lvim-notify`             |
| `msgarea` / `cmdline`| `lvim-msgarea`            |
| `picker` / `fuzzy`   | `lvim-picker`             |
| `dashboard`          | `lvim-dashboard`          |
| `chrome`             | `lvim-statusline` et al.  |
| `gx`                 | `lvim-gx`                 |

---

## Highlights

`lvim-utils.config` builds the **central highlight-group map** (the `LvimUi*` / `LvimNotify*` / `LvimUiMsgArea*`
/ `LvimUiDashboard*` / `LvimUiChrome*` families) from the live palette and publishes it as `config.colors`. It
stays in the base because **every split plugin references those groups by name** (they don't redefine them) —
one theming source of truth. `setup()` binds the factory via `highlight.bind`, so the whole map self-themes on
every palette / `ColorScheme` change; the accents and tints are the `ui` config above.

## License

BSD-3-Clause — see [LICENSE](./LICENSE).
