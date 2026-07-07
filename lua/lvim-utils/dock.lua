-- lvim-utils.dock: the shared DOCK-STACK manager coordinating the three docking layouts
-- (area / bottom / float) across every consumer that occupies one of them (lvim-term, the
-- lvim-picker / lvim-ui.surface pickers & panels, lvim-qf-loc's browser, lvim-control-center's
-- panels — anything that docks).
--
-- Invariants it enforces:
--   • EXACTLY ONE consumer VISIBLE per layout at a time — never 2. Opening a second consumer in a
--     layout HIDES the first (keeping its state) and shows the new one; it does NOT close the first.
--   • Each layout keeps its OWN independent STACK of consumer INSTANCES, with MEMORY (a hidden
--     consumer is parked, not destroyed — its buffers/state survive so it restores exactly).
--   • A configurable key (`<Leader>n` / `<Leader>p`) cycles the visible consumer forward / back
--     through the CURRENT layout's stack (LIFO/MRU order).
--
-- It is MECHANISM-AGNOSTIC: it never knows about cmdheight, msgarea reserves, or floats. It only
-- tracks who is registered / visible / stacked and calls the consumer's own `show()` / `hide()`.
-- So it lives in the BASE plugin (lvim-utils depends on nothing UI-layer) and never `require`s
-- lvim-ui / lvim-msgarea — the consumer supplies the closures that use those. The manager sits
-- ABOVE the docking mechanisms (host_window / surface), deciding WHO owns each dock right now.
--
-- A stack entry is an opened INSTANCE in a LAYOUT, not a plugin: two live pickers (files + grep) are
-- two entries; a singleton like lvim-term is one entry per layout it is open in. Every entry is keyed
-- by (id, layout), so the SAME consumer opened in float AND bottom is TWO entries (one per stack) — a
-- consumer can live in all three stacks at once — while re-opening the same (id, layout) re-shows the
-- one entry (never a duplicate in that stack). `layout` never PINS an id to a stack; it selects which
-- stack an open joins.
--
---@module "lvim-utils.dock"

local api = vim.api
local config = require("lvim-utils.config")

local M = {}

--- A dock consumer INSTANCE, for ONE layout. `id` is the stable IDENTITY: the ENTRY KEY is (id, layout),
--- so two opens with the SAME (id, layout) are the same entry (the second RE-SHOWS it, MRU — never a
--- duplicate in that stack), while the SAME id with a DIFFERENT `layout` is a SEPARATE entry in that other
--- stack (a consumer can be open in all three at once). A consumer computes `id` from its command +
--- meaningful args (e.g. "lvim-term", "lvim-picker:files", "lvim-picker:grep") — NOT layout-encoded; the
--- manager composes the (id, layout) key and RETURNS it from `M.open`. Because one consumer can be open in
--- several layouts at once, a consumer keeps its window/state PER LAYOUT (build a distinct handle per
--- opened layout via a `get_consumer(layout)`), setting `layout` to the layout THIS open targets. `show`/
--- `hide` are the seam the manager drives; `hide` MUST preserve state (park — never destroy) so `show`
--- can restore it; a consumer that cannot restore reports `is_alive()` false after hide and is pruned.
---@class LvimDockConsumer
---@field id       string                       The STABLE identity (e.g. "lvim-term", "lvim-picker:grep"); NOT layout-encoded.
---@field name     string                       Human label (the `<Leader>m` menu shows it with the layout).
---@field layout   "area"|"bottom"|"float"       Which layout THIS open targets (the entry's stack). Not a pin — a different value is a separate entry.
---@field show     fun(ctx: LvimDockCtx)         Make it VISIBLE (create / restore its window) at `ctx.rect` in `ctx.layout`.
---@field hide     fun()                         Make it INVISIBLE but KEEP its state (park — do not destroy).
---@field is_alive fun(): boolean               Still has restorable state? false ⇒ dropped from the stack.
---@field close?    fun()                        Full teardown on `M.close` (else `hide` is used).
---@field focus?    fun()                        Focus its window (else the manager uses the current window).
---@field buffers?  fun(): integer[]             Buffers to install the leader owner on (else the current buffer).
---@field is_current? fun(): boolean             Does it own the CURRENT window? (used to resolve `cycle`'s layout)
---@field icon?     string                       A Nerd Font glyph for the `<Leader>m` dock menu row (optional).
---@field slot?     table                        A per-consumer ANCHORED geometry override passed to `M.slot`
---                 (`{ height?, width?, height_auto?, width_auto?, backdrop? }`) — WINS over the global
---                 `config.dock.geometry` for THIS consumer's `ctx.rect`. Absent ⇒ the shared geometry.

--- Context passed to a consumer's `show`, so it can distinguish a fresh open from a cycle / restore, AND the
--- canonical SLOT geometry it must fill (the single source of truth — the consumer keeps no size of its own).
---@class LvimDockCtx
---@field layout      "area"|"bottom"|"float"
---@field reason      "open"|"cycle"|"restore"
---@field previous_id string?  The entry KEY that was visible before (hidden to make room), if any.
---@field rect        LvimDockSlot  The resolved slot (`dock.slot(layout)`): row/col/width/height + the auto
---                   flags + backdrop / keep_focus / auto_hide. The consumer sizes its window to THIS.

---@type string[]  the three coordinated layouts
local LAYOUTS = { "area", "bottom", "float" }

-- ── entry keys: ONE entry per (id, layout) ──────────────────────────────────────
-- A consumer's `id` is its stable IDENTITY; the SAME id opened in a DIFFERENT layout is a DISTINCT
-- entry with its OWN stack — so a consumer can live in all three stacks at once. Every entry is keyed
-- by a composite ENTRY KEY `id .. RS .. layout`. `layout` NEVER pins an id to one stack: it selects
-- which layout's stack THIS open joins (and is the consumer's default open mode). Re-opening the same
-- (id, layout) RE-SHOWS it (dedup — never a 2nd entry in that stack); opening (id, other-layout) is a
-- separate entry. `M.open` RETURNS the ekey and the lifecycle APIs take it back (the consumer stores
-- it), so their arity is unchanged.
local RS = "\30"
--- Compose the entry key for (id, layout).
---@param id string
---@param layout string
---@return string
local function ekey(id, layout)
    return id .. RS .. layout
end
--- The layout half of an entry key.
---@param key string
---@return string
local function key_layout(key)
    return key:match(RS .. "(.+)$")
end

---@type table<string, string[]>  layout → ordered entry KEYS (END = top / most-recently-shown; MRU)
local stacks = { area = {}, bottom = {}, float = {} }
---@type table<string, string?>  layout → the entry KEY currently VISIBLE there (nil = the dock is collapsed)
local visible = { area = nil, bottom = nil, float = nil }
---@type table<string, LvimDockConsumer>  entry KEY → the registered handle
local by_key = {}
---@type table<string, integer[]>  entry KEY → the buffers its leader owner is installed on (removed on hide)
local leader_bufs = {}
---@type string?  the layout of the last show, a fallback for `cycle` when no dock is focused
local last_layout = nil
---@type boolean  the global cycle keymaps are bound (setup is idempotent)
local keys_bound = false
---@type (fun(run: fun()))?  the registered SWAP coalescer (the host zone's reflow handoff). A consumer SWAP
--- (`do_hide(cur)` then `do_show(new)` — or a re-show that tears its own surface down then rebuilds) does a
--- RELEASE followed by a RESERVE in the host zone. Run OUTSIDE a handoff the zone reflows TWICE — it
--- collapses on the release, then grows again on the reserve — which the editor paints as a visible flicker
--- and a transient two-surface STACK (the old rect briefly coexists with the new). The zone owner (lvim-msgarea,
--- via `lvim-ui.surface.zone_handoff`) injects a coalescer here so the whole swap paints as ONE reflow. nil ⇒
--- no coordinator registered (bottom / float need none — they aren't zone-hosted) → the swap runs directly.
--- The edge stays INVERTED: the base dock never `require`s lvim-ui / msgarea; the owner hands in the closure.
local swap_handoff = nil
---@type table<string, fun(req: { height: integer, height_auto: boolean }): { row: integer, col: integer, width: integer, height: integer }?>
--- layout → an OPTIONAL slot provider that returns the REAL reserved rect for that layout (registered by the
--- host that owns the geometry — e.g. lvim-msgarea for `area`, which owns the zone width + reserved rows). The
--- base dock never requires a UI plugin; `slot()` calls the provider when present, else computes the rect from
--- `config.dock.geometry` itself. See `M.set_slot_provider`.
local slot_providers = {}

-- ─── small list helpers ─────────────────────────────────────────────────────────

--- The 1-based index of `id` in `list`, or nil.
---@param list string[]
---@param id string
---@return integer?
local function index_of(list, id)
    for i, v in ipairs(list) do
        if v == id then
            return i
        end
    end
    return nil
end

--- Remove `id` from `list` (first occurrence).
---@param list string[]
---@param id string
local function remove_id(list, id)
    local i = index_of(list, id)
    if i then
        table.remove(list, i)
    end
end

--- Move `id` to the TOP (end) of `list` — a push for a new id, an MRU-bump for an existing one.
---@param list string[]
---@param id string
local function push_top(list, id)
    remove_id(list, id)
    list[#list + 1] = id
end

--- Whether the entry `key` still holds restorable state (default true when it declares no `is_alive`).
---@param key string
---@return boolean
local function alive(key)
    local c = by_key[key]
    if not c then
        return false
    end
    return c.is_alive == nil or c.is_alive() == true
end

-- ─── leader ownership (buffer-local) ────────────────────────────────────────────
-- While focus is inside a docked window, ONLY the cycle keys work under <Leader>; every other
-- <Leader>… sequence is swallowed. The clean seam is a BUFFER-LOCAL <Leader> map (Neovim resolves
-- buffer-local before global, so it shadows the whole global leader tree only in that buffer) whose
-- handler reads the ONE suffix key with getcharstr: n/p cycle, all else is a no-op. Global leader
-- maps are never touched and resume the instant focus leaves the buffer.

--- The suffix a `<Leader>x` (or `<LocalLeader>x`) key binds — the part AFTER the leader, e.g. "n".
---@param key string?
---@return string
local function leader_suffix(key)
    if type(key) ~= "string" then
        return ""
    end
    return (key:gsub("^<[Ll]eader>", ""):gsub("^<[Ll]ocalleader>", ""))
end

--- Dispatch the character typed after <Leader> in a docked window: the configured next / prev suffix
--- cycles, the close suffix KILLS the visible consumer; anything else is SWALLOWED (a genuine no-op —
--- never falls through to a global leader map). Split out from the map so it is unit-testable without
--- the blocking getcharstr.
---@param ch string  the single suffix character (from getcharstr)
function M._dispatch_leader(ch)
    local keys = (config.dock or {}).keys or {}
    if ch == leader_suffix(keys.cycle_next) then
        M.cycle(nil, 1)
    elseif ch == leader_suffix(keys.cycle_prev) then
        M.cycle(nil, -1)
    elseif ch == leader_suffix(keys.close) then
        M.close_current()
    elseif ch == leader_suffix(keys.menu) then
        M.menu()
    end
    -- else: swallow — do nothing, do not feedkeys, do not fall through.
end

--- Install the buffer-local leader owner on `buf` (idempotent via a buffer-var guard).
---@param buf integer
local function install_leader_buf(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    if vim.b[buf].lvim_dock_leader then
        return
    end
    vim.b[buf].lvim_dock_leader = true
    -- Opt out of lvim-keys-helper for this buffer BEFORE our <Leader> owner is set, so the helper's
    -- keymap watcher already sees the flag on its recompute and never installs a buffer-local <Leader>
    -- <nowait> trigger that would shadow the owner below and pop the hint panel instead of cycling.
    vim.b[buf].lvim_keys_helper_disable = true
    -- Normal-mode <Leader> owner: in a terminal this applies in NORMAL mode (terminal-insert lets the
    -- shell own the bytes, as it should); in a picker/panel buffer it applies directly.
    pcall(vim.keymap.set, "n", "<leader>", function()
        local ok, ch = pcall(vim.fn.getcharstr)
        if ok then
            M._dispatch_leader(ch)
        end
    end, { buffer = buf, nowait = true, silent = true, desc = "lvim-dock: leader owner (n/p cycle, else swallow)" })
end

--- Install the leader owner on all of entry `key`'s buffers (the current window's buffer when it
--- declares none). No-op when `capture_leader` is off.
---@param key string
local function install_leader(key)
    if (config.dock or {}).capture_leader == false then
        return
    end
    local c = by_key[key]
    if not c then
        return
    end
    local bufs = (c.buffers and c.buffers()) or { api.nvim_get_current_buf() }
    local recorded = {}
    for _, b in ipairs(bufs) do
        install_leader_buf(b)
        recorded[#recorded + 1] = b
    end
    leader_bufs[key] = recorded
end

--- Remove the leader owner from every buffer it was installed on for entry `key`.
---@param key string
local function remove_leader(key)
    for _, b in ipairs(leader_bufs[key] or {}) do
        if b and api.nvim_buf_is_valid(b) then
            pcall(vim.keymap.del, "n", "<leader>", { buffer = b })
            vim.b[b].lvim_dock_leader = nil
            -- Release the keys-helper opt-out so it resumes normal behavior on this buffer.
            vim.b[b].lvim_keys_helper_disable = nil
        end
    end
    leader_bufs[key] = nil
end

-- ─── show / hide primitives ─────────────────────────────────────────────────────

--- Run a consumer SWAP (a release then a reserve) through the registered zone coalescer so a HOSTED layout's
--- swap paints as ONE reflow — but ONLY when it actually needs it: (1) a coalescer is registered, (2) the swap
--- is REAL (a consumer is already visible → a release precedes the reserve; a lone first open reserves once and
--- needs no coalescing), and (3) the layout is HOSTED — its geometry owned by an external zone, signalled by a
--- registered slot provider (only `area` is). bottom / float are self-contained floats (no provider): their
--- surfaces just open / close with no zone reflow, so their swap runs DIRECTLY, untouched by the zone. This
--- keeps the coalescing precisely where the two-reflow flicker happens and leaves every other path unchanged.
---@param layout string
---@param has_current boolean  a consumer is already visible in `layout` (so the swap is release-then-reserve)
---@param fn fun()
local function run_swap(layout, has_current, fn)
    if swap_handoff and has_current and slot_providers[layout] then
        swap_handoff(fn)
    else
        fn()
    end
end

--- Park consumer `id`: remove its leader owner, then call its `hide` (which keeps state alive). The
--- manager's HIDE never destroys — that is the memory guarantee. A well-behaved consumer suppresses
--- its OWN self-close notification (`M.closed`) while the manager parks it, so this cannot re-enter.
---@param key string
local function do_hide(key)
    local c = by_key[key]
    if not c then
        return
    end
    remove_leader(key)
    pcall(c.hide)
end

--- Show entry `key`: call its `show(ctx)`, focus it, install the leader owner, remember the layout. The
--- entry's layout is the KEY's layout (not `c.layout`) — the same consumer handle may be registered under
--- several keys (one per layout it is open in), so the KEY, not the handle, carries which layout to fill.
---@param key string
---@param reason "open"|"cycle"|"restore"
---@param previous_key string?
local function do_show(key, reason, previous_key)
    local c = by_key[key]
    if not c then
        return
    end
    local L = key_layout(key)
    -- PUSH the canonical slot geometry with the show, so the consumer sizes its window to the ONE authority
    -- (config.dock.geometry via `M.slot`) instead of computing its own — that is what makes every consumer in a
    -- layout land in the identical rect. A consumer's own `c.slot` is an ANCHORED override (wins over global).
    pcall(c.show, { layout = L, reason = reason, previous_id = previous_key, rect = M.slot(L, c.slot) })
    if c.focus then
        pcall(c.focus)
    end
    install_leader(key)
    last_layout = L
end

--- Forget entry `key` entirely: drop its handle. (Its stack removal / leader teardown are done by the
--- caller.)
---@param key string
local function forget(key)
    by_key[key] = nil
end

--- Show the TOP (most-recently-shown, MRU) live entry of `layout`, pruning dead ones; collapse
--- the dock (nothing visible) when the stack empties. Used after a visible consumer closes.
---@param layout string
local function show_top(layout)
    local st = stacks[layout]
    while #st > 0 do
        local key = st[#st]
        if alive(key) then
            visible[layout] = key
            do_show(key, "restore", nil)
            return
        end
        table.remove(st)
        forget(key)
    end
    visible[layout] = nil
end

-- ─── public API ─────────────────────────────────────────────────────────────────

--- Register (or replace) a consumer handle WITHOUT showing it, under its (id, layout) entry key. `M.open`
--- registers implicitly, so a direct call is only needed to pre-register.
---@param consumer LvimDockConsumer
function M.register(consumer)
    if consumer and consumer.id and consumer.layout then
        by_key[ekey(consumer.id, consumer.layout)] = consumer
    end
end

--- Open a consumer — SHOW-OR-CREATE by its (id, `consumer.layout`) ENTRY KEY:
---   • if a LIVE entry with this (id, layout) already exists → RE-SHOW it (MRU-bump, make it visible,
---     focus) — NOT a duplicate in that stack;
---   • else → create the entry in `consumer.layout`'s stack and push it to the top.
--- `layout` NEVER pins the id: the SAME id opened with a DIFFERENT `consumer.layout` is a SEPARATE
--- entry in that other layout's stack (a consumer can live in all three stacks at once). Either way it
--- enforces one-visible-per-layout (any OTHER visible consumer there is hidden — it stays on the stack,
--- state preserved). RETURNS the entry KEY — the consumer stores it and passes it back to the lifecycle
--- APIs (`M.parked`/`closed`/`dropped`/`hide`/`close`/`refresh_leader`/`show`) for THIS entry.
---@param consumer LvimDockConsumer
---@return string key
function M.open(consumer)
    local L = consumer.layout
    local key = ekey(consumer.id, L)
    by_key[key] = consumer
    local cur = visible[L]
    -- COALESCE the swap (see `run_swap`): whenever a consumer is already visible here we do a RELEASE (hide the
    -- previous, or — for a re-show of the SAME key — the consumer's `show` tears its own surface down) immediately
    -- followed by a RESERVE (`do_show`), so a zone-hosted layout must paint both as one reflow (else it collapses
    -- then grows — a visible flicker + transient stack). `run_swap` engages the coalescer only for that case.
    run_swap(L, cur ~= nil, function()
        if cur and cur ~= key then
            do_hide(cur) -- one-visible-per-layout: the previous stays on the stack (memory)
        end
        push_top(stacks[L], key)
        visible[L] = key
        do_show(key, "open", cur ~= key and cur or nil)
    end)
    return key
end

--- Hide the entry `key` but KEEP it on its stack (parked, restorable). The dock collapses if it
--- was the visible one; nothing else is shown (unlike `close`).
---@param key string
function M.hide(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    if visible[L] == key then
        visible[L] = nil
    end
    do_hide(key)
end

--- KILL the consumer `id` THROUGH the manager (a real close — the `<Leader>x` action): run its
--- `close` (full teardown — kill the process / delete the buffer / free the surface; else a parking
--- `hide`), remove it from the stack, and — if it was visible — reveal the most-recently-hidden
--- consumer on that layout (LIFO), or collapse the dock when the stack empties.
---@param key string
function M.close(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    local was_visible = visible[L] == key
    if was_visible then
        visible[L] = nil
    end
    remove_leader(key)
    local c = by_key[key]
    if c.close then
        pcall(c.close)
    else
        pcall(c.hide)
    end
    remove_id(stacks[L], key)
    forget(key)
    if was_visible then
        show_top(L)
    end
end

--- KILL the consumer currently visible in `layout` (the `<Leader>x` target) — `M.close` of the
--- visible id. No-op when the dock is collapsed. `layout` defaults to the focused / last / default.
---@param layout ("area"|"bottom"|"float")?
function M.close_current(layout)
    layout = layout or M.current_layout()
    local key = visible[layout]
    if key then
        M.close(key)
    end
end

--- Bring an EXISTING entry `key` visible in ITS layout and focus it — MRU-bump it, hide whatever else
--- was visible there (kept on the stack). The `<Leader>m` menu selects through here (a "jump to any
--- dock"). No-op for an unknown / dead key.
---@param key string
function M.show(key)
    if not (by_key[key] and alive(key)) then
        return
    end
    local L = key_layout(key)
    local cur = visible[L]
    -- COALESCE the swap (release the currently-visible consumer, reserve this one) into ONE zone reflow.
    run_swap(L, cur ~= nil, function()
        if cur and cur ~= key then
            do_hide(cur)
        end
        push_top(stacks[L], key)
        visible[L] = key
        do_show(key, "restore", cur ~= key and cur or nil)
    end)
end

--- The live dock entries across ALL three stacks, top-of-stack first per layout — for the menu /
--- introspection. Each `{ key, id, name, layout, icon?, visible }` (`key` = the entry key to pass to
--- `M.show`; `id` = the consumer's base identity, the SAME across the layouts it lives in).
---@return { key: string, id: string, name: string, layout: string, icon: string?, visible: boolean }[]
function M.entries()
    local out = {}
    for _, layout in ipairs(LAYOUTS) do
        local st = stacks[layout]
        for i = #st, 1, -1 do
            local key = st[i]
            local c = by_key[key]
            if c and alive(key) then
                out[#out + 1] = {
                    key = key,
                    id = c.id,
                    name = c.name or c.id,
                    layout = layout,
                    icon = c.icon,
                    visible = visible[layout] == key,
                }
            end
        end
    end
    return out
end

--- Open the dock MENU (the `<Leader>m` action, and `:LvimDock <layout> menu`): a CANONICAL `lvim-ui.select`
--- listing live consumers; choosing one shows it in its layout (`M.show`). With `layout` given, only that
--- layout's consumers (the `:LvimDock <layout> menu` scope); without, ALL three stacks. The menu is a transient
--- float that is NOT a dock (it never enters a stack). Degrades to a notify when lvim-ui is absent — NEVER a
--- hand-rolled float / vim.ui.select (the canonical-UI rule).
---@param layout ("area"|"bottom"|"float")?  restrict to this layout's consumers (nil = all)
function M.menu(layout)
    local entries = M.entries()
    if layout then
        entries = vim.tbl_filter(function(e)
            return e.layout == layout
        end, entries)
    end
    if #entries == 0 then
        return
    end
    local ok, ui = pcall(require, "lvim-ui")
    if not (ok and type(ui) == "table" and ui.select) then
        pcall(vim.notify, "lvim-dock: lvim-ui unavailable — the dock menu needs it", vim.log.levels.WARN)
        return
    end
    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = {
            label = ("%s  [%s%s]"):format(e.name, e.layout, e.visible and ", visible" or ""),
            icon = e.icon,
        }
    end
    ui.select({
        title = layout and ("Docks — " .. layout) or "Docks",
        items = items,
        callback = function(confirmed, index)
            if confirmed and index and entries[index] then
                M.show(entries[index].key)
            end
        end,
    })
end

--- Reveal the TOP of `layout`'s stack — the `:LvimDock <layout>` action. If a consumer is already visible
--- there, just FOCUS it; otherwise show the most-recently-used live one (pruning dead ones). No-op on an empty
--- stack. Complements `cycle` (step) and `menu` (pick) with a plain "bring this layout's dock forward".
---@param layout "area"|"bottom"|"float"
function M.reveal(layout)
    local st = stacks[layout]
    if not (st and #st > 0) then
        return
    end
    local vis = visible[layout]
    if vis and by_key[vis] then
        local c = by_key[vis]
        if c.focus then
            pcall(c.focus)
        end
        return
    end
    show_top(layout) -- shows + focuses the MRU-top live entry (prunes dead ones)
end

--- DESCEND from an OUTSIDE editor window into the visible docked consumer — landing on its HEADER (e.g. a
--- tab bar), the mirror of the surface's `<C-k>` escape-UP. Picks the first VISIBLE consumer across the
--- `bottom` → `area` → `float` stacks and calls its `descend` (else `focus`). Returns false — a no-op — when
--- the cursor is already inside a dock frame (its own sector key owns the navigation there) or nothing is
--- docked, so the global key handler can fall through to the editor's default key.
---@return boolean descended
function M.descend()
    if vim.w.lvim_frame then
        return false -- already inside a frame → its buffer-local sector key handles the navigation
    end
    for _, layout in ipairs({ "bottom", "area", "float" }) do
        local key = visible[layout]
        local c = key and by_key[key]
        if c and alive(key) then
            if c.descend then
                pcall(c.descend)
            elseif c.focus then
                pcall(c.focus)
            end
            return true
        end
    end
    return false
end

--- Notify the manager that consumer `id` closed ITSELF (its window was destroyed externally — a
--- `:q`, a killed terminal, a WinClosed). The manager only updates bookkeeping — it does NOT call
--- the consumer's hide/close (it is already gone) — then reveals the next on that layout (LIFO).
---@param key string
function M.closed(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    local was_visible = visible[L] == key
    if was_visible then
        visible[L] = nil
    end
    remove_leader(key)
    remove_id(stacks[L], key)
    forget(key)
    if was_visible then
        show_top(L)
    end
end

--- Notify the manager that consumer `id` closed ITSELF and should be DROPPED from the stack, WITHOUT
--- revealing another consumer (the difference from `closed` / `close`, which reveal the LIFO-next). The dock
--- collapses if it was visible, so focus returns to the editor rather than popping the parked neighbour. For a
--- consumer whose self-dismissal means "I'm done — back to the editor" (a finder's confirm / cancel), not
--- "pop the stack": revealing (and focusing) the parked neighbour would otherwise steal the window a confirm's
--- own action (e.g. opening the picked file) needs.
---@param key string
function M.dropped(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    if visible[L] == key then
        visible[L] = nil
    end
    remove_leader(key)
    remove_id(stacks[L], key)
    forget(key)
end

--- Notify the manager that consumer `id` PARKED itself — its window/surface is gone (a self-dismissal: a
--- finder confirm / cancel / `q` / `:q`, or an external replace) but its state is REMEMBERED, so it STAYS on
--- its stack (cyclable via `<Leader>n/p`, listed in the `<Leader>m` menu) and its `is_alive` stays true. The
--- manager only collapses the dock if it was the visible one — it does NOT reveal a neighbour (unlike
--- `closed`) and does NOT drop the entry (unlike `dropped` / `close`). Distinct from `M.hide`: the consumer
--- already tore its OWN window down, so the manager must NOT call the consumer's `hide` again — it only fixes
--- up bookkeeping (collapse + drop the leader owner). Re-showing it later (`M.open` / `M.show` / `cycle`)
--- calls the consumer's `show`, which rebuilds it from the remembered state.
---@param key string
function M.parked(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    if visible[L] == key then
        visible[L] = nil
    end
    remove_leader(key)
end

--- Re-install the leader owner on consumer `id`'s CURRENT buffers — for a VISIBLE consumer that SWAPS its
--- buffers while staying open (e.g. the fzf finder restarts its terminal in place on a keep-open file open, or
--- a terminal respawns): the owner was installed on the OLD buffers at show time, so the new ones would carry
--- none and `<Leader>n/p/x/m` would silently stop working there. Removes the owner from the buffers it left
--- and installs it on the current set (`c.buffers()`). No-op for an unknown id or one that is not the
--- currently-visible entry of its layout (a parked consumer re-installs on its next `show`).
---@param key string
function M.refresh_leader(key)
    if not by_key[key] then
        return
    end
    local L = key_layout(key)
    if visible[L] ~= key then
        return
    end
    remove_leader(key)
    install_leader(key)
end

--- Cycle the visible consumer of `layout` by `dir` (+1 next / -1 previous) through that layout's
--- stack, wrapping and skipping dead entries (which are pruned). Hides the visible one (kept on the
--- stack) and shows the neighbour. No-op when the stack has fewer than 2 live entries.
---@param layout ("area"|"bottom"|"float")?  defaults to the focused / last / configured layout
---@param dir integer  +1 next, -1 previous
function M.cycle(layout, dir)
    layout = layout or M.current_layout()
    local st = stacks[layout]
    if #st < 2 then
        return
    end
    local cur = visible[layout]
    local start = (cur and index_of(st, cur)) or #st
    local n = #st
    -- Step around the ring from the current index, showing the first live entry that isn't `cur`.
    for step = 1, n do
        local j = ((start - 1 + dir * step) % n) + 1
        local target = st[j]
        if target and target ~= cur then
            if alive(target) then
                -- COALESCE the cycle swap (hide the visible one, show the neighbour) into ONE zone reflow.
                run_swap(layout, cur ~= nil, function()
                    if cur then
                        do_hide(cur)
                    end
                    visible[layout] = target
                    do_show(target, "cycle", cur)
                end)
                return
            end
            -- dead: prune and retry from the same logical position (n shrinks, so recompute)
            remove_id(st, target)
            by_key[target] = nil
            return M.cycle(layout, dir)
        end
    end
end

--- The entry KEY visible in `layout`, or nil (the dock is collapsed).
---@param layout "area"|"bottom"|"float"
---@return string?
function M.visible(layout)
    return visible[layout]
end

--- A copy of `layout`'s stack (ordered entry KEYS, END = top / most-recently-shown) — for introspection.
---@param layout "area"|"bottom"|"float"
---@return string[]
function M.stack(layout)
    return vim.deepcopy(stacks[layout] or {})
end

--- The layout `cycle` acts on when none is given: the layout whose visible consumer owns the CURRENT
--- window, else the last-shown layout, else the configured default.
---@return "area"|"bottom"|"float"
function M.current_layout()
    for _, layout in ipairs(LAYOUTS) do
        local key = visible[layout]
        local c = key and by_key[key]
        if c and c.is_current and c.is_current() then
            return layout
        end
    end
    return last_layout or (config.dock or {}).default_layout or "area"
end

-- ─── canonical slot geometry (the SINGLE size authority) ─────────────────────────
-- Every docked / floated surface in the lvim-tech UI (pickers, the terminal, the qf browser,
-- control-center, standalone lvim-ui modals) reads its size from HERE — `config.dock.geometry.<layout>`
-- resolved to a rect by `M.slot`. No consumer keeps its own size. Two paths, one source: PUSH — `do_show`
-- hands the stack consumer `ctx.rect = M.slot(layout)`; PULL — a non-docked surface (an lvim-ui modal) calls
-- `M.slot("float", …)` directly. For `area` the msgarea zone OWNS the reserved rect (width + rows), so it
-- registers a provider (`set_slot_provider`) that `M.slot` prefers; bottom / float the dock computes itself.

---@class LvimDockSlot
---@field row         integer  editor-relative top row of the slot
---@field col         integer  editor-relative left col of the slot
---@field width       integer  slot width in columns (the resolved MAX when width_auto)
---@field height      integer  slot height in rows (the resolved MAX when height_auto)
---@field height_auto boolean  true → `height` is the MAXIMUM (a consumer that CAN content-fit shrinks up to it;
---                            one that can't — a terminal/shell — fills it); false → EXACT/fixed height
---@field width_auto  boolean  true → `width` is the MAXIMUM (else EXACT/fixed)
---@field backdrop    table?   this layout's backdrop spec (enabled / mode / dim / darken)
---@field keep_focus  boolean? keep focus in the dock after opening a file from it (area/bottom)
---@field auto_hide   boolean? close the surface when a file is opened from it

--- Resolve a fraction (≤ 1 → a share of `total`, > 1 → an absolute count) to a positive cell count.
---@param frac number
---@param total integer
---@return integer
local function res_frac(frac, total)
    if type(frac) ~= "number" then
        return math.max(1, total)
    end
    return frac <= 1 and math.max(1, math.floor(total * frac)) or math.max(1, math.floor(frac))
end

--- Register (or clear with nil) the slot provider for `layout` — the host that OWNS that layout's real
--- geometry. `M.slot(layout)` prefers it over its own computation. lvim-msgarea registers the `area` provider
--- (the zone owns the width + the reserved rows); bottom / float need none (the dock computes them).
---@param layout "area"|"bottom"|"float"
---@param provider (fun(req: { height: integer, height_auto: boolean }): LvimDockSlot?)?
function M.set_slot_provider(layout, provider)
    slot_providers[layout] = provider
end

--- Register (or clear with nil) the SWAP coalescer — the host zone's reflow handoff. The zone owner
--- (lvim-msgarea) injects `lvim-ui.surface.zone_handoff` here so the dock can wrap a consumer swap
--- (`do_hide` + `do_show`, or a same-id re-show) in ONE zone reflow instead of two (release then reserve),
--- eliminating the collapse-then-grow flicker + transient stacking of two AREA consumers. bottom / float are
--- not zone-hosted and register none (their surfaces just open / close). The edge stays INVERTED — the base
--- dock never `require`s lvim-ui / msgarea; the owner hands in the closure. Idempotent (re-set is fine).
---@param fn (fun(run: fun()))?  run `run()` inside a single coalesced zone reflow (nil clears → swaps run directly)
function M.set_handoff(fn)
    swap_handoff = fn
end

--- The canonical SLOT for `layout` — the ONE geometry authority. Reads `config.dock.geometry.<layout>` as the
--- DEFAULT (size + auto flags + backdrop / keep_focus / auto_hide), resolves the fractions to a rect, and for
--- `area` defers to the registered zone provider (which owns the reserved rect). A per-open `opts` is an
--- ANCHORED OVERRIDE that WINS over the global for THIS call only — the size fields (`height` / `width` ≤ 1 = a
--- fraction, > 1 = an absolute count; `height_auto` / `width_auto`) and the `backdrop` (`false` = no backdrop;
--- a table = merged over the central spec). So the centralization gives the DEFAULTS without taking away
--- per-open control (a programmatic caller can pin an exact size + backdrop). Pure apart from the live config.
---@param layout "area"|"bottom"|"float"
---@param opts? { height?: number, width?: number, height_auto?: boolean, width_auto?: boolean, backdrop?: table|false }
---@return LvimDockSlot
function M.slot(layout, opts)
    opts = opts or {}
    local g = ((config.dock or {}).geometry or {})[layout] or {}
    local h_frac = opts.height or g.height or 0.5
    local w_frac = opts.width or g.width or 1.0
    local h_auto = opts.height_auto
    if h_auto == nil then
        h_auto = g.height_auto ~= false
    end
    local w_auto = opts.width_auto
    if w_auto == nil then
        w_auto = g.width_auto == true
    end
    -- per-open BACKDROP override (anchored over the central default): `false` → disabled for this open; a table
    -- → merged over the central spec (so a caller can flip only `mode` / an `amount` and inherit the rest).
    local backdrop = g.backdrop
    if opts.backdrop ~= nil then
        if opts.backdrop == false then
            backdrop = { enabled = false }
        elseif type(opts.backdrop) == "table" then
            backdrop = vim.tbl_deep_extend("force", g.backdrop or {}, opts.backdrop)
        end
    end
    local lines, cols = vim.o.lines, vim.o.columns
    ---@type LvimDockSlot
    local slot = {
        row = 0,
        col = 0,
        width = cols,
        height = res_frac(h_frac, lines),
        height_auto = h_auto,
        width_auto = w_auto,
        backdrop = backdrop,
        keep_focus = g.keep_focus,
        auto_hide = g.auto_hide,
    }
    if layout == "area" then
        -- The msgarea zone owns the area rect (width + the reserved rows above the messages). Prefer its
        -- provider; without it, fall back to a bottom-edge rect of the configured height.
        local prov = slot_providers.area
        local r = prov and prov({ height = slot.height, height_auto = h_auto })
        if r then
            slot.row, slot.col, slot.width, slot.height = r.row, r.col, r.width, r.height
        else
            slot.row = math.max(0, lines - slot.height - 1)
        end
    elseif layout == "bottom" then
        -- Full-width, docked over the bottom rows (the statusline row stays free — the `- 1`).
        slot.row = math.max(0, lines - slot.height - 1)
    else -- float: centred, the configured fraction of the screen on both axes
        slot.width = res_frac(w_frac, cols)
        slot.row = math.max(0, math.floor((lines - slot.height) / 2))
        slot.col = math.max(0, math.floor((cols - slot.width) / 2))
    end
    return slot
end

--- Merge `opts` into the live dock config and bind the GLOBAL cycle keymaps (idempotent). The
--- buffer-local leader owner is installed per docked window by the show path, independently of this.
---@param opts? LvimUtilsDockConfig  dock config overrides (merged into lvim-utils.config.dock)
function M.setup(opts)
    if opts and next(opts) then
        config.setup({ dock = opts })
    end
    local dcfg = config.dock or {}
    if dcfg.enable == false or keys_bound then
        return
    end
    keys_bound = true
    local keys = dcfg.keys or {}
    if type(keys.cycle_next) == "string" and keys.cycle_next ~= "" then
        pcall(vim.keymap.set, "n", keys.cycle_next, function()
            M.cycle(nil, 1)
        end, { silent = true, desc = "lvim-dock: cycle to the next consumer in the current layout" })
    end
    if type(keys.cycle_prev) == "string" and keys.cycle_prev ~= "" then
        pcall(vim.keymap.set, "n", keys.cycle_prev, function()
            M.cycle(nil, -1)
        end, { silent = true, desc = "lvim-dock: cycle to the previous consumer in the current layout" })
    end
    -- Register the descend into lvim-msgarea's `focus_content`, so ONE user `<C-j>` → `focus_content()`
    -- binding descends into the AREA zone AND a bottom / float dock uniformly — the dock never grabs a global
    -- key (that would clobber the user's own navigator, exactly what msgarea deliberately avoids). Edge stays
    -- INVERTED: the dock does not `require` msgarea beyond this optional wiring; msgarea calls the fn it is given.
    pcall(function()
        require("lvim-msgarea").set_descend_fallback(M.descend)
    end)
    M.setup_command()
end

---@type table<string, true>  the three coordinated layouts, as a set (for the command validation)
local LAYOUT_SET = { area = true, bottom = true, float = true }

--- Register the `:LvimDock <layout> [menu]` user command (idempotent):
---   `:LvimDock area|bottom|float`        → reveal the TOP of that layout's stack (`M.reveal`)
---   `:LvimDock area|bottom|float menu`   → a layout-scoped dock menu (`M.menu(layout)`)
--- An unknown / missing layout notifies the usage. Completion offers the layouts, then `menu`.
function M.setup_command()
    pcall(vim.api.nvim_create_user_command, "LvimDock", function(o)
        local layout = o.fargs[1]
        if not (layout and LAYOUT_SET[layout]) then
            pcall(vim.notify, "LvimDock: usage — :LvimDock <area|bottom|float> [menu]", vim.log.levels.WARN)
            return
        end
        if o.fargs[2] == "menu" then
            M.menu(layout)
        else
            M.reveal(layout)
        end
    end, {
        nargs = "+",
        complete = function(arg_lead, cmd_line, _)
            local parts = vim.split(cmd_line, "%s+")
            if #parts <= 2 then
                return vim.tbl_filter(function(l)
                    return l:find(arg_lead, 1, true) == 1
                end, LAYOUTS)
            elseif #parts == 3 then
                return (("menu"):find(arg_lead, 1, true) == 1) and { "menu" } or {}
            end
            return {}
        end,
        desc = "LvimDock — reveal a layout's dock (:LvimDock <area|bottom|float> [menu])",
    })
end

return M
