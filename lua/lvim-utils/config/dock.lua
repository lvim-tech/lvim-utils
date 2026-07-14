-- lvim-utils.config.dock: live config for the dock-stack manager (lvim-utils.dock). The manager
-- coordinates the three docking layouts (area / bottom / float) so that at most ONE consumer is
-- visible per layout, each layout keeps its own MRU stack of consumers, and a key cycles the
-- visible one. setup() merges user opts into this table in place; readers do
-- `require("lvim-utils.config").dock`.
--
---@module "lvim-utils.config.dock"

---@class LvimUtilsDockKeys
---@field cycle_next string  Cycle to the NEXT consumer in the current layout's stack (default "<Leader>n").
---@field cycle_prev string  Cycle to the PREVIOUS one (default "<Leader>p").
---@field close      string  KILL the visible consumer (real teardown) + remove it from the stack, then
---                          reveal the next per MRU / collapse the dock (default "<Leader>x").
---@field menu       string  Open a MENU (lvim-ui.select) of every live dock consumer across the three
---                          stacks; selecting one shows it in its layout (default "<Leader>m").

---@class LvimUtilsDockBackdrop
---@field enabled boolean   false → no backdrop for that layout.
---@field mode    "darken"|"dim"  which look is LIVE — "darken" (fg+bg toward black) or "dim" (fg only, lighter).
---@field dim     { amount: number }  the "dim" mute fraction 0..1 (used when mode == "dim").
---@field darken  { amount: number }  the "darken" mute fraction 0..1 (used when mode == "darken").

---@class LvimUtilsDockLayoutGeometry
---@field height      number   Fraction 0.1..1.0 of the screen height (area/bottom are also clamped to the room).
---@field height_auto boolean  true → `height` is a MAXIMUM (content-fit UP TO it); false → EXACT/fixed height.
---@field width?      number   Fraction 0.1..1.0 of the screen width — FLOAT ONLY (area/bottom are full-width and
---                            carry NO width key at all).
---@field width_auto? boolean  true → `width` is a MAXIMUM (content-fit up to it); false → EXACT/fixed. FLOAT ONLY.
---@field backdrop    LvimUtilsDockBackdrop  The behind-the-surface mute for this layout.
---@field keep_focus  boolean  After opening a file from an area/bottom dock that STAYS, keep focus IN the dock
---                            (true) or move to the opened file (false). Irrelevant to `float`.
---@field auto_hide   boolean  Close the surface when a file is opened FROM it (float = one-shot modal → true).

---@class LvimUtilsDockConfig
---@field enable         boolean               Bind the global cycle keymaps on `dock.setup()`.
---@field keys           LvimUtilsDockKeys     The cycle keys (global maps + the buffer-local leader owner).
---@field default_layout "area"|"bottom"|"float"  Layout `cycle()` targets when no dock is focused.
---@field capture_leader boolean               Install the buffer-local leader owner in a docked window, so ONLY
---                                            the cycle keys work under `<Leader>` there (all else is swallowed).
---@field geometry       table<"area"|"bottom"|"float", LvimUtilsDockLayoutGeometry>  The SINGLE authority for
---                      per-layout geometry (size + backdrop + keep_focus + auto_hide). EVERY docked / floated
---                      consumer (pickers, the terminal, the qf browser, control-center, lvim-ui modals) reads
---                      it through `dock.slot(layout)` — no plugin keeps its own size any more. `dock.slot`
---                      resolves the fractions to a rect (+ the area zone provider), applying the auto semantics.

---@type LvimUtilsDockConfig
return {
    enable = true,
    keys = {
        cycle_next = "<Leader>n",
        cycle_prev = "<Leader>p",
        close = "<Leader>x",
        menu = "<Leader>m",
    },
    default_layout = "area",
    capture_leader = true,

    -- The SINGLE source of truth for the geometry of every docked / floated surface in the whole lvim-tech UI
    -- (pickers, the terminal, the quickfix browser, control-center, standalone lvim-ui modals). No plugin holds
    -- its own size — each resolves its slot via `dock.slot(layout)`. Control-center's "Utils" panel edits THIS.
    --   height / width — fraction 0.1..1.0 of the screen; area/bottom are full-width (width ignored).
    --   height_auto / width_auto — true → the value is a MAXIMUM (content-fit up to it); false → EXACT/fixed.
    --   height_peek — the height cap of the `dynamic` PREVIEW: a peek FLOAT above the list (the third rotation
    --     position, after right / left). DOCKED layouts only (area / bottom): the peek lives in the editor's own
    --     space ABOVE the dock, which a centred float does not have — so `float` carries no such key. Same units
    --     as `height` (≤1 = a fraction of the screen, >1 = absolute rows); the chassis re-derives it from the
    --     CURRENT window height on every rotation / resize.
    --   backdrop — the behind-the-surface mute (via the shared lvim-utils.dim namespace — no covering window).
    --   keep_focus / auto_hide — focus / close behaviour after opening a file from the dock.
    -- Numbers taken from the user's LIVE control-center base (settings persisted under `ui_size_*` /
    -- `ui_backdrop_*`), so the new centralized defaults reproduce exactly what the user already sees.
    geometry = {
        float = {
            height = 0.7,
            width = 0.9,
            height_auto = true,
            width_auto = false,
            backdrop = { enabled = true, mode = "dim", dim = { amount = 0.4 }, darken = { amount = 0.3 } },
            keep_focus = false,
            auto_hide = true,
        },
        -- area / bottom are ALWAYS full-width — they carry NO `width` / `width_auto` at all (there are no such
        -- keys, not even = 1.0); `dock.slot` returns the full columns for them. Only `float` has a width.
        area = {
            height = 0.5,
            height_peek = 0.7,
            height_auto = true,
            backdrop = { enabled = true, mode = "dim", dim = { amount = 0.4 }, darken = { amount = 0.3 } },
            keep_focus = true,
            auto_hide = false,
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
}
