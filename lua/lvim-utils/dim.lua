-- lvim-utils.dim: shared foreground-dimming primitives. A single highlight NAMESPACE whose groups are the
-- global highlights with their FOREGROUND muted toward the editor background (backgrounds left untouched, so
-- it coexists with `transparent`). Applying that namespace to a window (|nvim_win_set_hl_ns|) dims the window's
-- TEXT with no covering overlay — so a graphics image composited by the terminal (kitty) underneath is NOT
-- hidden, unlike a `winblend` veil window.
--
-- Two consumers use this: lvim-colorscheme's focus-follow `dim_inactive`, and lvim-ui's surface backdrop
-- "dim" mode (dim the windows behind a float instead of covering them). They must NOT share the SAME namespace:
-- each builds it with its OWN amount, so a shared namespace means whoever rebuilt last silently overwrites the
-- other's amount (a backdrop at 0.6 would leave the focus dim stuck at 0.6 after it closes). Therefore
-- `build`/`darken` take an OPTIONAL caller-owned namespace: pass your own (created once per consumer) and your
-- amount is never clobbered by the other. The module keeps a DEFAULT namespace (`M.ns` / `M.darken_ns`) for the
-- focus consumer; the backdrop owns separate ones. WHICH windows, WHEN, and restore is each consumer's own.
--
---@module "lvim-utils.dim"

local api = vim.api

local M = {}

---@type integer? the DIM namespace (foreground muted toward bg); lazily created by build()
M.ns = nil
---@type integer? the DARKEN namespace (background muted toward a dark colour); lazily created by darken()
M.darken_ns = nil

-- NO stale-group clearing. A namespace is a PARTIAL overlay: any group NOT set in it falls back to the global
-- (ns 0) definition — that fallback is what makes a `winhighlight`-themed window (Normal:NormalSB,
-- CursorLine:LvimUiCursorLine …) still resolve its panel bg / cursorline while it wears a dim/darken ns. Writing
-- an EMPTY def (`nvim_set_hl(ns, name, {})`) to "unshadow" a vanished group does the OPPOSITE: an empty def is a
-- real (blank) override that BLOCKS the fallback, so the panel's bg / selection collapse to nothing (the bug the
-- lvim-ui menu used to work around with its own namespace). We therefore never write blank defs. A group that
-- truly vanishes on a theme switch is a non-issue in practice (the lvim palette redefines groups, never deletes
-- them); leaving a slightly-muted previous colour for a frame until the next rebuild is harmless, whereas an
-- empty override makes real panels disappear. If strict cleanup is ever needed, recreate the ns — never blank it.

---@type table<string, true> Lua patterns for highlight groups whose fg must NOT be muted — their foreground
--- carries DATA, not a colour (e.g. lvim-image's `LvimImage_<id>` encode the kitty image id in fg; muting it
--- makes the terminal read a different id and the image vanishes). Registered via `M.preserve`.
local preserved = {}

--- Register a Lua pattern of highlight-group NAMES to leave UNMUTED in the dim namespace (their fg copied
--- verbatim). Use for groups whose foreground is a data channel, not a visible colour.
---@param pattern string
function M.preserve(pattern)
    preserved[pattern] = true
end

---@type boolean whether a per-window dim MANAGER (lvim-colorscheme's dim_inactive/dark_active) should stand
--- down — set while an lvim-ui surface owns a namespace backdrop, so the two managers don't fight over the same
--- windows (which left the backdrop covering only SOME windows).
M.suspended = false
---@type (fun(suspended: boolean))[]
local suspend_cbs = {}

--- Register a callback fired when the dim managers are asked to suspend (true → release your windows + stop) or
--- resume (false → re-apply). lvim-colorscheme's focus-follow registers one.
---@param cb fun(suspended: boolean)
function M.on_suspend(cb)
    suspend_cbs[#suspend_cbs + 1] = cb
end

--- Suspend (true) or resume (false) the per-window dim managers — used by lvim-ui's surface backdrop so its
--- namespace darken/dim owns every window uniformly while a surface is open.
---@param on boolean
function M.suspend(on)
    M.suspended = on and true or false
    for _, cb in ipairs(suspend_cbs) do
        pcall(cb, M.suspended)
    end
end

--- Whether `name` matches any registered preserve pattern.
---@param name string
---@return boolean
local function is_preserved(name)
    for pat in pairs(preserved) do
        if name:find(pat) then
            return true
        end
    end
    return false
end

--- Numeric (0xRRGGBB) blend of `fg` toward `bg` by fraction `t` (0 = fg unchanged, 1 = fully bg).
---@param fg integer
---@param bg integer
---@param t number
---@return integer
function M.blend(fg, bg, t)
    local fr, fgc, fb = math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256
    local br, bgc, bb = math.floor(bg / 65536) % 256, math.floor(bg / 256) % 256, bg % 256
    local r = math.floor(fr * (1 - t) + br * t + 0.5)
    local g = math.floor(fgc * (1 - t) + bgc * t + 0.5)
    local b = math.floor(fb * (1 - t) + bb * t + 0.5)
    return r * 65536 + g * 256 + b
end

--- (Re)build a dim namespace from the CURRENT global highlights, muting each group's fg/sp toward `bg_hex`
--- by `amount`. Call after every theme change so the dimmed copies track the live palette. Returns the ns.
--- Pass `ns` to (re)build a CALLER-OWNED namespace (so two consumers with different amounts don't clobber each
--- other); omit it to use the shared default (`M.ns`).
---@param bg_hex string  editor background the foregrounds are blended toward (e.g. colors.bg)
---@param amount number   fraction blended toward bg (0..1); higher = more muted
---@param ns? integer     a caller-owned namespace to build into; nil = the module default `M.ns`
---@return integer ns
function M.build(bg_hex, amount, ns)
    if not ns then
        if not M.ns then
            M.ns = api.nvim_create_namespace("lvim_utils_dim")
        end
        ns = M.ns
    end
    local bg = tonumber((bg_hex or "#000000"):gsub("#", ""), 16) or 0
    for name, def in pairs(api.nvim_get_hl(0, {})) do
        if is_preserved(name) then
            -- Data-carrying fg (e.g. an image id) — copy verbatim so it renders identically under the dim ns.
            api.nvim_set_hl(ns, name, def)
        elseif def.link then
            -- Keep the link; the target is dimmed in this same namespace, so it resolves dim.
            api.nvim_set_hl(ns, name, { link = def.link })
        else
            -- `nvim_get_hl(0, {})` hands us a fresh, caller-owned table per group, so mutate `def` in place.
            if def.fg then
                def.fg = M.blend(def.fg, bg, amount)
            end
            if def.sp then
                def.sp = M.blend(def.sp, bg, amount)
            end
            -- bg/ctermbg left untouched so the window background (incl. NONE) is unchanged.
            api.nvim_set_hl(ns, name, def)
        end
    end
    return ns --[[@as integer]]
end

--- (Re)build the DARKEN namespace from the current global highlights, muting each group's fg AND bg (and sp)
--- toward `dark_hex` by `amount` — so EVERYTHING (text + background) goes darker, matching the old winblend
--- veil look, but through a namespace (no covering window) so a terminal-composited image under a darkened
--- window stays visible. Preserved (data-fg) groups are copied verbatim. Returns the ns.
---@param dark_hex string  colour everything is blended toward (e.g. "#000000")
---@param amount number    fraction blended toward `dark_hex` (0..1); higher = darker
---@param ns? integer      a caller-owned namespace to build into; nil = the module default `M.darken_ns`
---@return integer ns
function M.darken(dark_hex, amount, ns)
    if not ns then
        if not M.darken_ns then
            M.darken_ns = api.nvim_create_namespace("lvim_utils_darken")
        end
        ns = M.darken_ns
    end
    local dark = tonumber((dark_hex or "#000000"):gsub("#", ""), 16) or 0
    for name, def in pairs(api.nvim_get_hl(0, {})) do
        if is_preserved(name) then
            api.nvim_set_hl(ns, name, def)
        elseif def.link then
            api.nvim_set_hl(ns, name, { link = def.link })
        else
            if def.fg then
                def.fg = M.blend(def.fg, dark, amount)
            end
            if def.bg then
                def.bg = M.blend(def.bg, dark, amount)
            end
            if def.sp then
                def.sp = M.blend(def.sp, dark, amount)
            end
            api.nvim_set_hl(ns, name, def)
        end
    end
    return ns --[[@as integer]]
end

--- Switch `win` onto namespace `ns` (a dim/darken namespace) or back to namespace 0 / full colour when `ns` is
--- nil / 0. No-op on an invalid window.
---@param win integer
---@param ns? integer
function M.set(win, ns)
    if not api.nvim_win_is_valid(win) then
        return
    end
    pcall(api.nvim_win_set_hl_ns, win, ns or 0)
end

-- ─── focus-aware BACKDROP applier (the shared one — surface + terminal + any dock consumer) ──────────────
-- The backdrop mutes every window BEHIND a consumer's surface/window (dim = fg toward the editor bg; darken =
-- fg+bg toward black) THROUGH this module's namespaces — NO covering window, so a terminal-composited image
-- (kitty) underneath stays visible. It is FOCUS-AWARE: while a PROTECTED (consumer-owned) window is current the
-- editor is muted; the moment focus moves to a window OUTSIDE the consumer the mute LIFTS off it (so the editor
-- you moved into is crisp), and re-applies when a protected window is focused again. Multiple consumers may own
-- a backdrop at once (keyed by `id`); ONE session WinEnter drives them all. Extracted from lvim-ui.surface so
-- the terminal (and any non-surface dock consumer) gets the SAME backdrop via `config.dock.geometry.<layout>`.

---@class LvimDimBackdrop
---@field enabled? boolean  false → no backdrop (a call with this is a `clear_backdrop`).
---@field mode?    "dim"|"darken"  dim = mute fg toward `bg`; darken = mute fg+bg toward black. Default "dim".
---@field amount?  number   mute fraction 0..1 (default 0.5).
---@field bg?      string   (dim mode) the bg foregrounds blend toward (default the live Normal bg).
---@field protect  fun(win: integer): boolean  true → `win` belongs to the consumer and is NEVER muted.

---@class LvimDimBackdropEntry
---@field cfg LvimDimBackdrop
---@field dimmed table<integer, integer>  muted window → its pre-backdrop namespace (restored on clear)
---@field ns? integer                     the backdrop namespace these windows currently wear

---@type table<string|integer, LvimDimBackdropEntry>
local backdrops = {}
--- Backdrops whose teardown (`clear_backdrop`) was DEFERRED because a hold was active — their windows are NOT
--- restored to bright immediately (that flashes the editor mid-transition); they wait for the last hold release,
--- which restores only the windows NO live backdrop has since taken over (see `M.hold_backdrop`).
---@type table<string|integer, LvimDimBackdropEntry>
local pending_clears = {}
--- Backdrop namespaces keyed by the EFFECTIVE LOOK ("dim:<amount>[:<bg>]" / "darken:<amount>") so two live
--- backdrops with DIFFERENT amounts/modes (a terminal in `bottom` at 0.6 + a picker in `area` at 0.4) each own
--- a DISTINCT namespace and never clobber the other's depth. Separate from the focus-follow M.ns/M.darken_ns so
--- the backdrop amount never clobbers lvim-colorscheme's dim_inactive amount either. Each entry keeps a
--- `rebuild` closure (over its mode/amount/bg) so `refresh_backdrop` can repopulate the SAME handle in place
--- from the live palette on a theme change — the muted windows point at the handle and re-read it, no re-apply.
---@type table<string, { ns: integer, rebuild: fun(ns: integer) }>
local bd_ns_cache = {}
---@type table<integer, true> the SET of all backdrop namespaces (for the prev-capture guard in bd_paint)
local backdrop_ns_set = {}
---@type boolean the one session-wide WinEnter is bound (idempotent)
local bd_focus_registered = false
---@type integer generation guard so a DEFERRED veil lift fires only when it is still the latest focus event
--- (a rapid focus-out→focus-in during a transition supersedes the pending lift, so it never paints).
local bd_focus_gen = 0
---@type integer nesting depth of an active backdrop HOLD: while > 0 the focus-aware handler never LIFTS the
--- veil (dimming still applies). The deferred lift alone coalesces SYNCHRONOUS surface swaps, but an ASYNC
--- transition (a tab/workspace/project load restores its layout in a `vim.schedule`) focuses the editor in an
--- EARLIER tick than the panel reopen, so the pending lift fires before anything supersedes it. A hold spanning
--- the whole load — set before it starts, released once its panel is back — keeps the editor dimmed throughout.
local bd_lift_hold = 0
-- `M.hold_backdrop` is defined AFTER `bd_paint` (below) — its RECONCILE-on-release repaints via `bd_paint`, so
-- it must be in scope. Placed here in the file order for that reason, not next to `bd_lift_hold`.
---@type integer count of hold releases WAITING for the focus to SETTLE on a protected window. A picker teardown
--- requests an EVENT-DRIVEN release (not a fixed schedule): a plain `vim.schedule` release can land on the
--- TRANSIENT editor focus (Neovim's terminal focus-fall after a surface close) and reconcile to a LIFT — the
--- second flash. Instead the release waits for a protected WinEnter, debounced one tick past the LAST focus
--- change so the transient editor focus between two protected foci never settles early.
local release_pending = 0
---@type integer generation for the settle debounce (each WinEnter re-arms; only the latest tick's check acts).
local settle_gen = 0

--- The rebuild closure for a look: repopulates namespace `ns` from the CURRENT global highlights. For `dim`
--- with no explicit `bg`, the editor background is recomputed LIVE each call so a theme change is tracked.
---@param mode "dim"|"darken"
---@param amount number
---@param fixed_bg string?  an explicit dim bg (nil → recompute the live Normal bg on every rebuild)
---@return fun(ns: integer)
local function make_rebuild(mode, amount, fixed_bg)
    if mode == "darken" then
        return function(ns)
            M.darken("#000000", amount, ns)
        end
    end
    return function(ns)
        local bg = fixed_bg
        if not bg then
            local nb = api.nvim_get_hl(0, { name = "Normal" })
            bg = (nb and nb.bg) and string.format("#%06x", nb.bg) or "#000000"
        end
        M.build(bg, amount, ns)
    end
end

--- Resolve (creating on first use) the backdrop namespace for `cfg`'s effective look and (re)build it from the
--- LIVE palette; returns the ns behind-windows go onto. Called only on apply / refresh — NOT on every focus hop
--- (a focus hop reuses the stored `bd.ns`), so window navigation with a dock open no longer pays a full
--- all-groups rebuild per WinEnter.
---@param cfg LvimDimBackdrop
---@return integer
local function bd_ns(cfg)
    local mode = cfg.mode == "darken" and "darken" or "dim"
    local amount = cfg.amount or 0.5
    local key
    if mode == "darken" then
        key = "darken:" .. tostring(amount)
    else
        key = "dim:" .. tostring(amount) .. (cfg.bg and (":" .. cfg.bg) or "")
    end
    local entry = bd_ns_cache[key]
    if not entry then
        entry = { ns = api.nvim_create_namespace("lvim_utils_backdrop_" .. key) }
        bd_ns_cache[key] = entry
        backdrop_ns_set[entry.ns] = true
    end
    -- Keep the freshest closure (its `amount`/`bg` never change for a given key, but `fixed_bg` may go from an
    -- explicit value to nil across callers — the latest wins, both correct for this look).
    entry.rebuild = make_rebuild(mode, amount, cfg.bg)
    entry.rebuild(entry.ns)
    return entry.ns
end

--- Suspend the per-window focus-dim managers (lvim-colorscheme) IFF any live backdrop currently owns windows —
--- so the two managers don't fight (which left the backdrop covering only SOME windows). Recomputed after every
--- paint, so it is correct with several backdrops and across lifts.
local function sync_suspend()
    local any = false
    for _, bd in pairs(backdrops) do
        if next(bd.dimmed) then
            any = true
            break
        end
    end
    M.suspend(any)
end

--- Mute every window that is NOT protected by `bd.cfg.protect` (and not a SPECIAL buftype window — sidebars /
--- terminals / help paint their own bg, so muting their fg toward the editor bg would LIGHTEN them), or restore
--- them (`on = false`). Idempotent per window; only windows WE muted are restored to their ORIGINAL namespace.
---@param bd { cfg: LvimDimBackdrop, dimmed: table<integer, integer>, ns?: integer }
---@param on boolean
local function bd_paint(bd, on)
    if on then
        M.suspend(true) -- release the focus-dim manager's windows BEFORE we grab them
        -- Reuse the namespace built once at apply/refresh — do NOT rebuild it here (this runs on EVERY WinEnter
        -- into a protected window; rebuilding would re-loop the whole global group map on each focus hop).
        local ns = bd.ns or bd_ns(bd.cfg)
        bd.ns = ns
        for _, w in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_is_valid(w) then
                local buf = api.nvim_win_get_buf(w)
                local special = vim.bo[buf].buftype ~= ""
                if not bd.cfg.protect(w) and not special and not bd.dimmed[w] then
                    -- Remember the window's CURRENT namespace (it may be on its OWN, e.g. neo-tree) so close
                    -- restores it EXACTLY instead of clobbering it to 0. (0 is truthy in Lua, so the guard holds.)
                    local prev = 0
                    pcall(function()
                        prev = api.nvim_get_hl_ns({ winid = w })
                    end)
                    -- CRITICAL for OVERLAPPING backdrops (2+ live at once — e.g. a terminal in `bottom` + a picker
                    -- in `area`): the window may ALREADY be on a BACKDROP namespace from the other one. Its true
                    -- ORIGINAL is NOT that dim/darken ns — capturing it would make THIS backdrop's restore leave the
                    -- window stuck on the dim ns (the "backdrop not cleared with 2+ in the stack" bug). Fall back to
                    -- the global ns (0) in that case. Check the SET of ALL backdrop namespaces (there is one per
                    -- distinct look now), not just two fixed handles.
                    if backdrop_ns_set[prev] then
                        prev = 0
                    end
                    bd.dimmed[w] = (type(prev) == "number" and prev >= 0) and prev or 0
                    M.set(w, ns)
                end
            end
        end
    else
        for w, prev in pairs(bd.dimmed) do
            M.set(w, prev)
        end
        bd.dimmed = {}
        sync_suspend()
    end
end

--- Hold (true) / release (false) the veil LIFT: while any hold is active the focus-aware backdrop never lifts,
--- so the editor stays dimmed across an async transition that transiently focuses it (see `bd_lift_hold`). Nests
--- (a counter), so overlapping holds compose; a matching release is required for each hold.
---
--- On the LAST release (counter → 0) it RECONCILES: repaints every live backdrop against the CURRENT focus, so
--- the transition ends in the correct state regardless of what mid-transition paints or a superseded/dropped
--- deferred lift left behind — if focus genuinely landed on the editor (e.g. the panel failed to open) the veil
--- LIFTS; if a protected surface (the reopened panel/picker) holds focus it stays DIMMED. Without this a plain
--- release could strand the editor wrongly dimmed, or leave the veil up over a focused panel.
--- Process the DEFERRED teardowns stashed while a hold was active. For each pending backdrop, restore a window
--- to its ORIGINAL namespace ONLY when NO live backdrop has taken it over in the meantime — so a window the
--- reopened panel re-dimmed stays dim (its new owner will restore it on its own close), while a window nobody
--- re-claimed (the panel never opened) is correctly un-dimmed. Never flashes bright: the still-dimmed windows
--- are left exactly where the new backdrop put them.
local function process_pending_clears()
    if not next(pending_clears) then
        return
    end
    --- Is `w` currently muted by some LIVE backdrop (already removed pending ones from `backdrops`)?
    ---@param w integer
    ---@return boolean
    local function owned_by_live(w)
        for _, bd in pairs(backdrops) do
            if bd.dimmed[w] then
                return true
            end
        end
        return false
    end
    for id, bd in pairs(pending_clears) do
        for w, orig in pairs(bd.dimmed) do
            if api.nvim_win_is_valid(w) and not owned_by_live(w) then
                M.set(w, orig) -- nobody re-claimed it → truly restore to its pre-backdrop namespace
            end
        end
        bd.dimmed = {}
        pending_clears[id] = nil
    end
    sync_suspend()
end

---@param on boolean
function M.hold_backdrop(on)
    bd_lift_hold = math.max(0, bd_lift_hold + (on and 1 or -1))
    if not on and bd_lift_hold == 0 then
        -- FIRST flush the deferred teardowns (restore only windows no live backdrop re-claimed), THEN reconcile
        -- the live backdrops to the settled focus. Order matters: a pending clear must not run AFTER the reconcile
        -- re-dimmed a window, or it would strip the veil the reopened panel just applied.
        process_pending_clears()
        local cur = api.nvim_get_current_win()
        local okc = api.nvim_win_is_valid(cur)
        for _, bd in pairs(backdrops) do
            bd_paint(bd, okc and bd.cfg.protect(cur) or false)
        end
    end
end

--- True while a surface TRANSITION is in progress (a hold is active) — focus may be passing transiently through
--- the editor between two protected surfaces. Focus-reactive chrome (the winbar breadcrumb) reads this so it
--- does not render a window ACTIVE during the swap, when the editor is momentarily current mid-teardown.
---@return boolean
function M.transition_active()
    return bd_lift_hold > 0
end

--- Is the CURRENT window protected by any LIVE backdrop (i.e. focus is on a consumer surface, not the editor)?
---@return boolean
local function current_is_protected()
    local cur = api.nvim_get_current_win()
    if not api.nvim_win_is_valid(cur) then
        return false
    end
    for _, bd in pairs(backdrops) do
        if bd.cfg.protect(cur) then
            return true
        end
    end
    return false
end

--- Fire every waiting settled-release (each is one `hold_backdrop(false)` — decrement + process clears + reconcile).
local function drain_releases()
    while release_pending > 0 do
        release_pending = release_pending - 1
        M.hold_backdrop(false)
    end
end

--- Debounce a settle check to ONE tick past the LAST focus change: re-armed on every WinEnter while a release is
--- pending, so a transient editor focus (the terminal focus-fall) between two protected foci supersedes an
--- earlier check and never settles early. When the latest tick sees focus on a protected window, the release
--- fires (and reconciles to DIM); otherwise it keeps waiting (the fallback timer covers a never-settling focus).
local function arm_settle()
    settle_gen = settle_gen + 1
    local mygen = settle_gen
    vim.schedule(function()
        if release_pending == 0 or mygen ~= settle_gen then
            return
        end
        if current_is_protected() then
            drain_releases()
        end
    end)
end

--- Release a hold once the transition has SETTLED — the picker teardown calls this instead of a blind
--- `vim.schedule(hold_backdrop(false))`. It waits for focus to rest on a protected window (the reopened panel),
--- so Neovim's transient terminal focus-fall can never trigger a lift-reconcile (the second flash). A fallback
--- timer releases anyway if no protected window is ever focused (the consumer's panel failed to open), so the
--- editor is never left permanently dimmed — but a protected WinEnter is the PRIMARY signal, the timer a backstop.
function M.release_backdrop_when_settled()
    release_pending = release_pending + 1
    arm_settle()
    vim.defer_fn(function()
        if release_pending > 0 then
            drain_releases()
        end
    end, 60)
end

--- The one session-wide WinEnter that keeps every live backdrop in step with focus: for each, mute-behind while
--- a PROTECTED window is current, lift while a non-protected one is (so the editor you moved into is crisp).
local function register_bd_focus()
    if bd_focus_registered then
        return
    end
    bd_focus_registered = true
    api.nvim_create_autocmd("WinEnter", {
        group = api.nvim_create_augroup("LvimUtilsBackdropFocus", { clear = true }),
        callback = function()
            local cur = api.nvim_get_current_win()
            local ok = api.nvim_win_is_valid(cur)
            -- A settled-release is waiting → re-arm its debounce on THIS focus change, so the release fires one
            -- tick past the LAST WinEnter (once focus rests on a protected window), never on a transient editor
            -- focus-fall between two protected foci.
            if release_pending > 0 then
                arm_settle()
            end
            -- DIM is IMMEDIATE (mute behind the moment focus enters a surface — no bright flash of the windows
            -- behind a just-opened float). The LIFT is DEFERRED one tick. Every panel/tab/workspace load, every
            -- picker→panel handoff, passes TRANSIENTLY through the editor between two protected windows (the old
            -- surface tears down, focus lands on the editor for an instant, the new surface opens and refocuses);
            -- lifting the veil at that instant flashes the editor bright for one frame — the flicker. Deferring
            -- the lift and RE-READING focus on the next tick coalesces it: if a protected window is current again
            -- by then, the veil never lifts. A genuine move to the editor still lifts, one imperceptible tick late.
            bd_focus_gen = bd_focus_gen + 1
            local deferred = false
            for _, bd in pairs(backdrops) do
                if ok and bd.cfg.protect(cur) then
                    bd_paint(bd, true) -- entering this surface → dim its behind NOW (idempotent if already dim)
                elseif bd_lift_hold == 0 then
                    deferred = true -- this backdrop would LIFT → defer it (see below); a HOLD suppresses it
                end
            end
            if deferred then
                local mygen = bd_focus_gen
                vim.schedule(function()
                    if mygen ~= bd_focus_gen or bd_lift_hold > 0 then
                        return -- superseded by a newer focus event, or a hold started meanwhile — drop the lift
                    end
                    local c = api.nvim_get_current_win()
                    local okc = api.nvim_win_is_valid(c)
                    for _, bd in pairs(backdrops) do
                        bd_paint(bd, okc and bd.cfg.protect(c) or false)
                    end
                end)
            end
        end,
    })
end

--- Apply (or update) the focus-aware backdrop `id` behind a consumer. `cfg.protect(win)` marks the consumer's
--- OWN windows (never muted); everything else behind is muted per `cfg.mode`/`amount`. Focus-aware from here on
--- (a session WinEnter lifts/reapplies). `cfg.enabled == false` ⇒ this is a `clear_backdrop(id)`.
---@param id string|integer  a stable key per consumer instance (so several can coexist)
---@param cfg LvimDimBackdrop
function M.apply_backdrop(id, cfg)
    if cfg == nil or cfg.enabled == false or type(cfg.protect) ~= "function" then
        M.clear_backdrop(id)
        return
    end
    local existing = backdrops[id]
    local bd = existing or { dimmed = {} }
    bd.cfg = cfg
    backdrops[id] = bd
    register_bd_focus()
    -- Build the namespace ONCE per application from the live palette; every subsequent focus hop reuses it.
    bd.ns = bd_ns(cfg)
    -- Initial paint. A FRESH backdrop (a surface just opened) starts DIMMED, not focus-keyed: the surface is
    -- the active thing and focus lands on it a beat later. Keying to current focus started the veil LIFTED and
    -- relied on the surface's WinEnter to dim it — coalesced normally, but if that focus event lands AFTER the
    -- frame flushes (a swap race), the flushed frame showed the editor bright = a one-frame flash. Also dim while
    -- a HOLD is active (a load/swap in progress). An UPDATE to an existing backdrop stays focus-aware.
    local cur = api.nvim_get_current_win()
    local muted = (not existing) or bd_lift_hold > 0 or (api.nvim_win_is_valid(cur) and cfg.protect(cur) or false)
    bd_paint(bd, muted)
end

--- Tear down backdrop `id`: restore every window it muted to its original namespace and forget it.
--- While a HOLD is active the restore is DEFERRED (stashed in `pending_clears`) instead of run now: closing a
--- surface mid-transition would strip the veil and flash the editor bright before the reopened panel re-dims it.
--- The deferred restore runs at the last hold release (`hold_backdrop`), and only for windows no live backdrop
--- has taken over — so a re-dimmed window keeps its new veil and one nobody re-claimed is un-dimmed correctly.
---@param id string|integer
function M.clear_backdrop(id)
    local bd = backdrops[id]
    if not bd then
        return
    end
    backdrops[id] = nil -- remove from the LIVE set either way (so `owned_by_live` never counts a closing backdrop)
    if bd_lift_hold > 0 then
        pending_clears[id] = bd -- defer the actual namespace restore to the hold release
        return
    end
    bd_paint(bd, false)
end

--- Rebuild EVERY backdrop namespace from the CURRENT global highlights, so windows veiled behind an open surface
--- track a LIVE theme change (e.g. the colorscheme picker preview) instead of freezing on the palette captured
--- at open — the windows re-read the rebuilt namespace (same handle), so no re-apply is needed. Rebuilds each
--- distinct-look namespace ONCE (not once per backdrop sharing it), and rebuilds even a LIFTED backdrop's ns
--- (no `dimmed` gate) so a theme switch while focus is OUTSIDE the consumer is still tracked. (The per-consumer
--- surface `refresh_backdrop` delegates here.)
function M.refresh_backdrop()
    for _, entry in pairs(bd_ns_cache) do
        entry.rebuild(entry.ns)
    end
end

return M
