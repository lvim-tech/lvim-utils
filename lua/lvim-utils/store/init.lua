-- lvim-utils.store: the unified persistence model for the lvim-tech set.
-- ONE model, three backends, plus mirroring + cross-instance sync — so no plugin hand-rolls
-- persistence again and every kind of stored state goes through the same seam:
--
--   backend = "file"   → a plain key=value text file. String values, human-readable, readable
--                        EARLY / externally (a shell script, or Neovim at startup before plugins
--                        — the chosen colorscheme). Atomic writes.
--   backend = "json"   → a JSON document. Typed/nested Lua data, git-friendly (lvim-linguistics
--                        local data, lvim-pkg state, structured settings).
--   backend = "sqlite" → real relational tables + CRUD + versioned migrations (vault / tasks /
--                        space / control-center). Its declarative FIELDS live in a settings KV
--                        table; its structured data in the caller's own tables.
--
-- READ/WRITE is a DECLARATIVE LIVE TABLE: declare the fields (with a backend, mirror, watch),
-- then just read/assign them — assignment auto-persists and auto-mirrors, no manual save():
--
--   local s = require("lvim-utils.store").new({
--     backend = "sqlite", name = "control-center",
--     fields  = { colorscheme = "lvim_dark", opacity = 0.9 },
--     mirror  = { colorscheme = vim.fn.stdpath("config") .. "/.theme" }, -- plain-file for early read
--     watch   = true, on_change = function(all) --[[ another instance changed it ]] end,
--   })
--   s.colorscheme = "lvim_light"     -- persists to sqlite + writes the .theme mirror
--   print(s.colorscheme)             -- reads (from the live cache)
--   s:find("macros", { name = "q" }) -- relational CRUD stays available on the sqlite backend
--
-- SYNC has two parts: `mirror` writes a field's raw value to a plain file (source of truth stays
-- the backend) so it can be read EARLY/externally; `watch` reloads + fires `on_change` when the
-- backing file changes on disk (another Neovim instance / an external tool). For the earliest
-- startup path there is a DEPENDENCY-FREE static read that opens no store:
--
--   require("lvim-utils.store").read_file(path)      -- the mirror's raw value
--   require("lvim-utils.store").read_json(path, key) -- a value out of a json store
--
-- Shared is the CODE ONLY — every plugin owns its OWN file/db (own path, own schema). No central
-- store, no cross-plugin coupling.
--
---@module "lvim-utils.store"

local uv = vim.uv

local M = {}

local BACKENDS = {
    file = "lvim-utils.store.file",
    json = "lvim-utils.store.json",
    sqlite = "lvim-utils.store.sqlite",
}
local EXT = { file = "conf", json = "json", sqlite = "db" }
-- Reserved method names on a store handle (fields may not use these).
local METHODS = {
    save = true,
    reload = true,
    close = true,
    is_open = true,
    path = true,
    all = true,
    find = true,
    insert = true,
    update = true,
    remove = true,
    count = true,
    exec = true,
    transaction = true,
}

-- ── static, dependency-free early reads ─────────────────────────────────────

--- The raw first-line value of a plain file (a `mirror` target), trimmed. nil when absent.
--- Opens no store and requires nothing — safe on the earliest startup path.
---@param path string
---@return string?
function M.read_file(path)
    if not path or vim.fn.filereadable(path) == 0 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines[1] then
        return nil
    end
    return vim.trim(lines[1])
end

--- Decode a json store file; return the whole document, or `key`'s value when given. nil on
--- missing/invalid. Dependency-free.
---@param path string
---@param key string?
---@return any
function M.read_json(path, key)
    if not path or vim.fn.filereadable(path) == 0 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return nil
    end
    local dok, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not dok then
        return nil
    end
    if key ~= nil then
        return (type(doc) == "table") and doc[key] or nil
    end
    return doc
end

--- Whether the sqlite backend is available (sqlite.lua installed).
---@return boolean
function M.available()
    return require("lvim-utils.store.sqlite").available()
end

--- Report the sqlite backend in a plugin's `:checkhealth`. `mandatory` = the plugin cannot work
--- without persistence (error vs info). file/json backends need no dependency.
---@param health table
---@param mandatory boolean?
function M.health(health, mandatory)
    if M.available() then
        health.ok("sqlite.lua found (lvim-utils.store sqlite backend)")
    elseif mandatory then
        health.error("sqlite.lua not found — persistence is unavailable (install kkharji/sqlite.lua)")
    else
        health.info("sqlite.lua not found — the sqlite backend is disabled (file/json still work)")
    end
end

-- ── mirror write (raw single value, atomic) ──────────────────────────────────

---@param path string
---@param value any
---@return boolean
local function write_mirror(path, value)
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        pcall(vim.fn.mkdir, dir, "p")
    end
    local tmp = path .. ".tmp"
    if not pcall(vim.fn.writefile, { tostring(value) }, tmp) then
        return false
    end
    -- Sync uv.fs_rename does NOT raise on failure — it returns nil,err. So `pcall(...) == true` would only
    -- test "didn't throw" and report success on a FAILED rename (read-only dir, ENOSPC, cross-device tmp);
    -- capture the real result. Drop the dead .tmp so a failed write leaves nothing behind.
    local ok, renamed = pcall(uv.fs_rename, tmp, path)
    if not (ok and renamed == true) then
        pcall(uv.fs_unlink, tmp)
        return false
    end
    return true
end

-- ── the declarative store handle ────────────────────────────────────────────

--- Open a store as a declarative live table. Fields are read/assigned directly on the returned
--- handle; assignment auto-persists (and auto-mirrors). Reserved method names (see METHODS) are
--- callable with `:` (`s:save()`, `s:find(...)`); everything else is a field.
---@param opts { backend?: "file"|"json"|"sqlite", name?: string, dir?: string, path?: string, version?: integer, tables?: table<string, table>, migrations?: table<integer, fun(db: any)>, fields?: table<string, any>, mirror?: table<string, string>, watch?: boolean, on_change?: fun(all: table) }
---@return table  the live store handle
function M.new(opts)
    opts = opts or {}
    local backend_name = opts.backend or "json"
    local mod = require(BACKENDS[backend_name] or BACKENDS.json)

    local name = opts.name or "lvim-utils"
    local path = opts.path
    if path then
        path = vim.fs.normalize(path)
    else
        local dir = vim.fs.normalize(opts.dir or (vim.fn.stdpath("data") .. "/" .. name))
        path = dir .. "/" .. name .. "." .. (EXT[backend_name] or "json")
    end

    local backend = mod.open({
        path = path,
        version = opts.version,
        tables = opts.tables,
        migrations = opts.migrations,
    })

    -- Live cache: declared defaults, overlaid with what is persisted on disk.
    local defaults = opts.fields or {}
    local function fresh_cache()
        local c = {}
        for k, v in pairs(defaults) do
            c[k] = v
        end
        for k, v in pairs(backend:load()) do
            c[k] = v
        end
        return c
    end

    local state = {
        backend = backend,
        cache = fresh_cache(),
        mirror = opts.mirror or {},
        on_change = opts.on_change,
        watcher = nil, ---@type uv.uv_fs_event_t?
        suppress = false, -- ignore watch echoes of our own writes
    }

    -- Seed the mirror files from the current (source-of-truth) values so an early read works
    -- from the first startup.
    for field, mpath in pairs(state.mirror) do
        if state.cache[field] ~= nil then
            write_mirror(mpath, state.cache[field])
        end
    end

    -- Methods (called with `:`; the self arg is the proxy and is ignored — they close over state).
    local methods = {}
    function methods.save()
        return state.backend:flush()
    end
    function methods.reload()
        state.cache = fresh_cache()
        return vim.deepcopy(state.cache)
    end
    function methods.all()
        return vim.deepcopy(state.cache)
    end
    function methods.is_open()
        return state.backend:is_open()
    end
    function methods.path()
        return state.backend:path()
    end
    function methods.close()
        if state.watcher then
            pcall(function()
                state.watcher:stop()
                state.watcher:close()
            end)
            state.watcher = nil
        end
        state.backend:close()
    end
    -- Relational passthrough (meaningful on the sqlite backend; false/nil elsewhere).
    for _, m in ipairs({ "find", "insert", "update", "remove", "count", "exec", "transaction" }) do
        methods[m] = function(_, ...)
            local b = state.backend
            if type(b[m]) == "function" then
                return b[m](b, ...)
            end
            return false
        end
    end

    -- Cross-instance sync: reload + notify when the backing file changes on disk. Watch the
    -- DIRECTORY (an atomic rename swaps the inode, so a file watch would go deaf) and filter by
    -- name; suppress the echo of our own writes.
    if opts.watch then
        local bpath = backend:path()
        if bpath then
            local dir, base = vim.fs.dirname(bpath), vim.fs.basename(bpath)
            local ev = uv.new_fs_event()
            if ev then
                local ok = pcall(function()
                    ev:start(
                        dir,
                        {},
                        vim.schedule_wrap(function(err, filename)
                            if err or state.suppress then
                                return
                            end
                            if filename and filename ~= base and filename ~= (base .. ".tmp") then
                                return
                            end
                            state.cache = fresh_cache()
                            if state.on_change then
                                pcall(state.on_change, vim.deepcopy(state.cache))
                            end
                        end)
                    )
                end)
                if ok then
                    state.watcher = ev
                end
            end
        end
    end

    return setmetatable({}, {
        __index = function(_, k)
            if METHODS[k] then
                return methods[k]
            end
            return state.cache[k]
        end,
        __newindex = function(_, k, v)
            if METHODS[k] then
                error("lvim-utils.store: '" .. tostring(k) .. "' is a reserved method name", 2)
            end
            state.cache[k] = v
            state.suppress = true
            state.backend:write(k, v)
            local mpath = state.mirror[k]
            if mpath then
                write_mirror(mpath, v)
            end
            -- Clear the self-write suppression after the fs_event has had a chance to fire.
            vim.defer_fn(function()
                state.suppress = false
            end, 150)
        end,
    })
end

return M
