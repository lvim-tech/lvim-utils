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
        M.ns = M.ns or api.nvim_create_namespace("lvim_utils_dim")
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
    return ns
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
        M.darken_ns = M.darken_ns or api.nvim_create_namespace("lvim_utils_darken")
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
    return ns
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

return M
