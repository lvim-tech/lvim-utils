-- lvim-utils.store.sqlite: the SQLite backend.
-- Wraps sqlite.lua for the plugins that need real, queried, relational data (vault macros,
-- tasks history, space projects, control-center settings). Two faces on one database:
--   • a `settings` KV table (name UNIQUE, value TEXT, type TEXT) that backs the store's
--     DECLARATIVE fields — arbitrary Lua scalars/tables encoded int/float/bool/string/json.
--   • the caller's own declared tables, with `find/insert/update/remove/count/exec/transaction`.
-- Versioned migrations use `PRAGMA user_version`: a fresh db is stamped at the current version;
-- an older db runs `migrations[old+1..version]` in order.
--
-- Every op is pcall-guarded; when sqlite.lua is missing the handle opens CLOSED and each op
-- degrades to false/nil, so the store layer never has to guard it.
--
---@module "lvim-utils.store.sqlite"

local M = {}

local ok_db, sqlite = pcall(require, "sqlite.db")
local ok_tbl, sqlite_tbl = pcall(require, "sqlite.tbl")
local HAS_SQLITE = ok_db and ok_tbl

--- Whether sqlite.lua is installed.
---@return boolean
function M.available()
    return HAS_SQLITE
end

-- The always-present KV table backing the declarative fields.
local SETTINGS = "settings"
local SETTINGS_SCHEMA = {
    id = { "integer", primary = true, autoincrement = true },
    name = { "text", required = true, unique = true },
    value = { "text" },
    type = { "text" },
}

-- ── typed value encode/decode (for the settings KV) ─────────────────────────

---@param v any
---@return string tag, string text
local function encode(v)
    local t = type(v)
    if t == "boolean" then
        return "bool", v and "1" or "0"
    elseif t == "number" then
        -- LuaJIT has no math.type; an integer-valued number gets the "int" tag (both decode via
        -- tonumber, so the tag is only cosmetic).
        return (v == math.floor(v)) and "int" or "float", tostring(v)
    elseif t == "table" then
        return "json", vim.json.encode(v)
    end
    return "string", tostring(v)
end

---@param text string
---@param tag string
---@return any
local function decode(text, tag)
    if tag == "bool" then
        return text == "1"
    elseif tag == "int" or tag == "float" then
        return tonumber(text)
    elseif tag == "json" then
        local ok, val = pcall(vim.json.decode, text)
        return ok and val or nil
    end
    return text
end

---@class LvimUtilsStoreSqlite
---@field _db     table?
---@field _tables table<string, table>
---@field _path   string
local Sql = {}
Sql.__index = Sql

-- ── raw eval (sqlite.lua keeps the connection CLOSED between ops; a bare db:eval on a closed
-- connection errors, so every raw statement runs inside with_open — open → eval → close) ──────

--- Evaluate raw SQL, opening the connection when needed. Returns the rows (or nil), or nil on
--- error / closed handle.
---@param sql string
---@param params table?
---@return any
function Sql:_eval(sql, params)
    if not self._db then
        return nil
    end
    local result
    local ok = pcall(function()
        if self._db:isopen() then
            result = self._db:eval(sql, params)
        else
            self._db:with_open(function(conn)
                result = conn:eval(sql, params)
            end)
        end
    end)
    return ok and result or nil
end

--- Run one statement with every value bound BY INDEX, and return whether it succeeded.
---
--- This exists because sqlite.lua's convenience layer (`tbl:insert` / `tbl:update`, and its
--- named-parameter `stmt:bind(table)`) treats a string value matching `^%S+%(.*%)$` as a SQL
--- EXPRESSION and splices it into the statement unbound — the feature that lets you write
--- `insert { ts = "date('now')" }`. Any ordinary text of that shape (`client.log(1)`, a code
--- snippet, a body, a filename with parens) therefore becomes a call to a function SQLite does not
--- have, and the write silently fails. Binding BY INDEX takes the other branch of `stmt:bind`,
--- which goes straight to the C API with no heuristic, so a value is always just a value.
--- The new row's id comes back from the SAME connection: sqlite.lua closes the handle between ops,
--- and `last_insert_rowid()` asked on a fresh connection is 0.
---@param sql string   a statement using `?` placeholders
---@param args any[]   one value per placeholder, in order
---@return boolean ok, integer? rowid
function Sql:_exec_bound(sql, args)
    if not self._db then
        return false, nil
    end
    local stmt_ok, sqlstmt = pcall(require, "sqlite.stmt")
    if not stmt_ok then
        return false, nil
    end
    local rowid
    local function run(conn)
        local stmt = sqlstmt:parse(conn, sql)
        for i, v in ipairs(args) do
            -- sqlite.lua binds number/string/nil; a boolean has no bind function, so it takes the
            -- integer form SQLite stores booleans as anyway.
            if type(v) == "boolean" then
                v = v and 1 or 0
            end
            stmt:bind(i, v)
        end
        stmt:step()
        stmt:finalize()

        local id_stmt = sqlstmt:parse(conn, "select last_insert_rowid() as id")
        id_stmt:step()
        local row = id_stmt:kv()
        rowid = row and tonumber(row.id) or nil
        id_stmt:finalize()
    end
    local ok = pcall(function()
        if self._db:isopen() then
            run(self._db.conn)
        else
            self._db:with_open(function(conn)
                run(conn.conn)
            end)
        end
    end)
    return ok, rowid
end

-- ── version / migrations ────────────────────────────────────────────────────

---@return integer
function Sql:_user_version()
    local rows = self:_eval("PRAGMA user_version")
    if type(rows) == "table" and rows[1] and rows[1].user_version ~= nil then
        return tonumber(rows[1].user_version) or 0
    end
    return 0
end

---@param v integer
function Sql:_set_user_version(v)
    self:_eval("PRAGMA user_version = " .. tostring(tonumber(v) or 0))
end

---@param target integer
---@param migrations table<integer, fun(db: LvimUtilsStoreSqlite)>
function Sql:_migrate(target, migrations)
    local cur = self:_user_version()
    if cur >= target then
        return
    end
    if cur > 0 then
        for v = cur + 1, target do
            if type(migrations[v]) == "function" then
                pcall(migrations[v], self)
            end
        end
    end
    self:_set_user_version(target)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Open a sqlite backend at `opts.path`, ensuring the settings table + the caller's tables.
---@param opts { path: string, version?: integer, tables?: table<string, table>, migrations?: table<integer, fun(db: any)> }
---@return LvimUtilsStoreSqlite
function M.open(opts)
    local self = setmetatable({ _db = nil, _tables = {}, _path = opts.path }, Sql)
    if not HAS_SQLITE then
        return self
    end

    local dir = vim.fs.dirname(opts.path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        if not pcall(vim.fn.mkdir, dir, "p") then
            return self
        end
    end

    local ok = pcall(function()
        self._db = sqlite({ uri = opts.path, opts = { foreign_keys = "ON" } })
        if not self._db then
            error("sqlite constructor returned nil")
        end
    end)
    if not ok or not self._db then
        self._db = nil
        return self
    end

    -- Migrate the RAW database FIRST — before the sqlite.tbl handles, which schema-check the
    -- (new) declared shape against the on-disk table and would error on a not-yet-migrated db.
    -- A fresh db (version 0) runs no migration steps; its tables are then created at the current
    -- schema by the handles below.
    self:_migrate(opts.version or 1, opts.migrations or {})

    local ok2 = pcall(function()
        self._tables[SETTINGS] = sqlite_tbl(SETTINGS, SETTINGS_SCHEMA, self._db)
        for tname, schema in pairs(opts.tables or {}) do
            self._tables[tname] = sqlite_tbl(tname, schema, self._db)
        end
    end)
    if not ok2 then
        self._db = nil
        self._tables = {}
    end
    return self
end

---@return boolean
function Sql:is_open()
    return self._db ~= nil
end

function Sql:close()
    if self._db then
        pcall(function()
            if self._db.close then
                self._db:close()
            end
        end)
        self._db = nil
        self._tables = {}
    end
end

---@return string
function Sql:path()
    return self._path
end

-- ── declarative fields (settings KV) ────────────────────────────────────────

--- Load all declared fields as a decoded table.
---@return table<string, any>
function Sql:load()
    return self:all()
end

---@return table<string, any>
function Sql:all()
    local out = {}
    local rows = self:find(SETTINGS)
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            out[r.name] = decode(r.value, r.type)
        end
    end
    return out
end

--- Persist one field value (typed upsert into the settings table).
---@param key string
---@param value any
---@return boolean
function Sql:write(key, value)
    -- A nil assignment CLEARS the field — same contract as the json/file backends (which drop the key). Without
    -- this, encode(nil) falls through to ("string", "nil") and the row is persisted as the literal string "nil",
    -- so the field comes back as "nil" after a reload instead of being absent / falling back to its default.
    if value == nil then
        return self:erase(key)
    end
    local tag, text = encode(value)
    local existing = self:find(SETTINGS, { name = key })
    if type(existing) == "table" and existing[1] then
        return self:update(SETTINGS, { name = key }, { value = text, type = tag })
    end
    return self:insert(SETTINGS, { name = key, value = text, type = tag }) ~= false
end

--- Remove one field.
---@param key string
---@return boolean
function Sql:erase(key)
    return self:remove(SETTINGS, { name = key })
end

--- json/file backends flush on write; sqlite writes immediately, so this is a no-op.
---@return boolean
function Sql:flush()
    return true
end

-- ── relational CRUD (by table name) ──────────────────────────────────────────

---@param name string
---@param where table?
---@param options table?
---@return table[]|nil|false
function Sql:find(name, where, options)
    local t = self._tables[name]
    if not t then
        return false
    end
    local q = options or {}
    if where and next(where) ~= nil then
        q.where = where
    end
    local ok, res = pcall(function()
        return t:get(q)
    end)
    if not ok then
        return false
    end
    if res == nil or (type(res) == "table" and not next(res)) then
        return nil
    end
    return res
end

---@param name string
---@param values table
---@return integer|false
function Sql:insert(name, values)
    if not self._tables[name] then
        return false
    end
    local cols, marks, args = {}, {}, {}
    for k, v in pairs(values) do
        cols[#cols + 1] = k
        marks[#marks + 1] = "?"
        args[#args + 1] = v
    end
    if #cols == 0 then
        return false
    end
    local sql = ("insert into %s (%s) values (%s)"):format(name, table.concat(cols, ", "), table.concat(marks, ", "))
    local ok, rowid = self:_exec_bound(sql, args)
    return (ok and rowid) and rowid or false
end

---@param name string
---@param where table
---@param set table
---@return boolean
function Sql:update(name, where, set)
    if not self._tables[name] then
        return false
    end
    local sets, wheres, args = {}, {}, {}
    for k, v in pairs(set) do
        sets[#sets + 1] = k .. " = ?"
        args[#args + 1] = v
    end
    if #sets == 0 then
        return true
    end
    for k, v in pairs(where or {}) do
        wheres[#wheres + 1] = k .. " = ?"
        args[#args + 1] = v
    end
    local sql = ("update %s set %s"):format(name, table.concat(sets, ", "))
    if #wheres > 0 then
        sql = sql .. " where " .. table.concat(wheres, " and ")
    end
    return (self:_exec_bound(sql, args))
end

---@param name string
---@param where table
---@return boolean
function Sql:remove(name, where)
    local t = self._tables[name]
    if not t then
        return false
    end
    return (pcall(function()
        t:remove(where)
    end))
end

---@param name string
---@param where table?
---@return integer
function Sql:count(name, where)
    local t = self._tables[name]
    if not t then
        return 0
    end
    -- Unfiltered count: `t:count()` runs `SELECT COUNT(*)` — a scalar, no per-row transfer. A FILTERED count
    -- keeps the find path (the installed sqlite.tbl `count` takes no where clause).
    if where == nil or next(where) == nil then
        local ok, n = pcall(function()
            return t:count()
        end)
        return (ok and type(n) == "number") and n or 0
    end
    local rows = self:find(name, where)
    return (type(rows) == "table") and #rows or 0
end

--- Run `fn` in a single transaction (writes inside must use raw `self._db:eval` / `self:exec`).
---@param fn fun()
---@return boolean
function Sql:transaction(fn)
    if not self:is_open() then
        pcall(fn)
        return false
    end
    return (
        pcall(function()
            self._db:with_open(function(conn)
                conn:eval("BEGIN")
                fn()
                conn:eval("COMMIT")
            end)
        end)
    )
end

--- Raw SQL (bind named `:name` placeholders via `params`). Returns the rows, or nil (DDL / no
--- rows / error). Runs through the with_open path so it works on a closed connection.
---@param sql string
---@param params table?
---@return any
function Sql:exec(sql, params)
    return self:_eval(sql, params)
end

return M
