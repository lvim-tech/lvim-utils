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

---@type table<integer, table<string, true>> per-namespace record of the group NAMES written on the last
--- (re)build. On the next rebuild any name in this set but ABSENT from the current global highlights is cleared
--- (`nvim_set_hl(ns, name, {})`) — otherwise a group that vanished on a theme switch would linger in the ns and
--- shadow the now-undefined global group for windows using that namespace.
local written = {}

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

--- Drop from namespace `ns` any group written on the previous (re)build that is absent from `fresh` (the set
--- of names written this build), then record `fresh` as the new set. Clearing a group in a namespace is
--- `nvim_set_hl(ns, name, {})` — it stops shadowing the (now-undefined) global group for windows on that ns.
---@param ns integer
---@param fresh table<string, true>
local function clear_stale(ns, fresh)
    local prev = written[ns]
    if prev then
        for name in pairs(prev) do
            if not fresh[name] then
                api.nvim_set_hl(ns, name, {})
            end
        end
    end
    written[ns] = fresh
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
    local fresh = {}
    for name, def in pairs(api.nvim_get_hl(0, {})) do
        fresh[name] = true
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
    clear_stale(ns --[[@as integer]], fresh)
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
    local fresh = {}
    for name, def in pairs(api.nvim_get_hl(0, {})) do
        fresh[name] = true
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
    clear_stale(ns --[[@as integer]], fresh)
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

---@type table<string|integer, { cfg: LvimDimBackdrop, dimmed: table<integer, integer> }>  id → live backdrop
local backdrops = {}
---@type integer? the SHARED backdrop dim / darken namespaces (separate from the focus-follow M.ns/M.darken_ns,
--- so the backdrop amount never clobbers lvim-colorscheme's dim_inactive amount)
local bd_dim_ns, bd_darken_ns
---@type boolean the one session-wide WinEnter is bound (idempotent)
local bd_focus_registered = false

--- (Re)build the backdrop namespace for `cfg` from the LIVE palette; returns the ns behind-windows go onto.
---@param cfg LvimDimBackdrop
---@return integer
local function bd_ns(cfg)
    if cfg.mode == "darken" then
        bd_darken_ns = bd_darken_ns or api.nvim_create_namespace("lvim_utils_backdrop_darken")
        return M.darken("#000000", cfg.amount or 0.5, bd_darken_ns)
    end
    bd_dim_ns = bd_dim_ns or api.nvim_create_namespace("lvim_utils_backdrop_dim")
    local bg = cfg.bg
    if not bg then
        local nb = api.nvim_get_hl(0, { name = "Normal" })
        bg = (nb and nb.bg) and string.format("#%06x", nb.bg) or "#000000"
    end
    return M.build(bg, cfg.amount or 0.5, bd_dim_ns)
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
---@param bd { cfg: LvimDimBackdrop, dimmed: table<integer, integer> }
---@param on boolean
local function bd_paint(bd, on)
    if on then
        M.suspend(true) -- release the focus-dim manager's windows BEFORE we grab them
        local ns = bd_ns(bd.cfg)
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
                    -- the global ns (0) in that case.
                    if prev == bd_dim_ns or prev == bd_darken_ns then
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
            for _, bd in pairs(backdrops) do
                bd_paint(bd, ok and bd.cfg.protect(cur) or false)
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
    local bd = backdrops[id] or { dimmed = {} }
    bd.cfg = cfg
    backdrops[id] = bd
    register_bd_focus()
    -- apply immediately, keyed to the CURRENT focus (muted only if a protected window is current)
    local cur = api.nvim_get_current_win()
    bd_paint(bd, api.nvim_win_is_valid(cur) and cfg.protect(cur) or false)
end

--- Tear down backdrop `id`: restore every window it muted to its original namespace and forget it.
---@param id string|integer
function M.clear_backdrop(id)
    local bd = backdrops[id]
    if not bd then
        return
    end
    bd_paint(bd, false)
    backdrops[id] = nil
end

--- Rebuild EVERY live backdrop's namespace from the CURRENT global highlights, so windows veiled behind an open
--- surface track a LIVE theme change (e.g. the colorscheme picker preview) instead of freezing on the palette
--- captured at open — the windows re-read the rebuilt namespace, so no re-apply is needed. No-op when none own
--- windows. (The per-consumer surface `refresh_backdrop` delegates here.)
function M.refresh_backdrop()
    for _, bd in pairs(backdrops) do
        if next(bd.dimmed) then
            bd_ns(bd.cfg) -- rebuild the shared ns in place; the dimmed windows re-read it
        end
    end
end

return M
