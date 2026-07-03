-- lvim-utils.store: persistence adapter for the runtime UI settings (the shared surface geometry — the
-- `config.ui.size` heights/widths + `auto_max`).
--
-- One key/value store, accessed the same way regardless of what is installed:
--   * lvim-control-center present (and its sqlite backend working) → values go through ITS
--     `persistence.data` module — the SAME database it reads on startup, so the two plugins recognise each
--     other's values automatically (the keys match control-center's setting names). No sqlite path/schema is
--     duplicated here.
--   * otherwise → a plain JSON file under stdpath("data")/lvim-utils/ (pure Lua, no sqlite). lvim-utils
--     therefore NEVER hard-depends on sqlite or on the control-center.
--
-- Every control-center call is pcall-guarded (the require AND the operation), so a present-but-broken backend
-- (sqlite missing, db not yet initialised) falls back to the JSON file instead of erroring.
--
---@module "lvim-utils.store"

local M = {}

local FILE = vim.fn.stdpath("data") .. "/lvim-utils/settings.json"

--- lvim-control-center's data module, only when it is present AND usable.
---@return table? data  the persistence.data module, or nil to use the JSON fallback
local function cc_data()
    local ok, data = pcall(require, "lvim-control-center.persistence.data")
    if ok and type(data) == "table" and type(data.save) == "function" and type(data.load) == "function" then
        return data
    end
    return nil
end

--- Read the whole JSON file (empty table when missing/unreadable).
---@return table<string, any>
local function read_file()
    local fd = io.open(FILE, "r")
    if not fd then
        return {}
    end
    local content = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, content or "")
    return (ok and type(decoded) == "table") and decoded or {}
end

--- Write the whole table back to the JSON file (creates the directory).
---@param tbl table<string, any>
local function write_file(tbl)
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(FILE, ":h"), "p")
    local fd = io.open(FILE, "w")
    if not fd then
        return
    end
    fd:write(vim.json.encode(tbl))
    fd:close()
end

--- Persist a value under `name` (control-center DB when available, else the JSON file).
---@param name string
---@param value any
function M.save(name, value)
    local data = cc_data()
    if data and pcall(data.save, name, value) then
        return
    end
    local tbl = read_file()
    tbl[name] = value
    write_file(tbl)
end

--- Read a persisted value, or nil when nothing has been saved.
---@param name string
---@return any
function M.load(name)
    local data = cc_data()
    if data then
        local ok, val = pcall(data.load, name)
        if ok then
            return val
        end
    end
    return read_file()[name]
end

--- Delete a persisted value under `name` from BOTH backends, so a superseded key (e.g. a migrated legacy
--- setting) cannot linger and be re-read on the next start.
---@param name string
function M.clear(name)
    local data = cc_data()
    if data and data.clear then
        pcall(data.clear, name)
    end
    local tbl = read_file()
    if tbl[name] ~= nil then
        tbl[name] = nil
        write_file(tbl)
    end
end

--- Seed the control-center DB from the standalone JSON file the first time the two cohabit: for each `name`
--- present in the JSON but absent from the DB, copy it over. A no-op without the control-center (JSON stays the
--- store) or when the JSON is empty. Called once by `settings.restore()`.
---@param names string[]
function M.migrate(names)
    local data = cc_data()
    if not data then
        return
    end
    local tbl = read_file()
    if not next(tbl) then
        return
    end
    for _, name in ipairs(names) do
        if tbl[name] ~= nil then
            local ok, existing = pcall(data.load, name)
            if ok and existing == nil then
                pcall(data.save, name, tbl[name])
            end
        end
    end
end

return M
