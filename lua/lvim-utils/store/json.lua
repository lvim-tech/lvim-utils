-- lvim-utils.store.json: the JSON-document backend.
-- The whole store is ONE JSON object held in memory and written atomically (temp + rename).
-- Human-readable and git-friendly — for typed/nested data that does not need SQL queries (the
-- lvim-linguistics local data, lvim-pkg install state, simple structured settings). Values keep
-- their Lua type (string/number/boolean/table) round-trip through vim.json.
--
-- Writes flush immediately by default; a caller batching many `write`s can defer with the
-- store's transaction/save flow (init.lua) to write the file once.
--
---@module "lvim-utils.store.json"

local uv = vim.uv or vim.loop

local M = {}

---@class LvimUtilsStoreJson
---@field _path  string
---@field _cache table<string, any>
local Json = {}
Json.__index = Json

--- Atomically write `text` to `path` (temp + rename), creating the parent dir if needed.
---@param path string
---@param text string
---@return boolean
local function atomic_write(path, text)
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        if not pcall(vim.fn.mkdir, dir, "p") then
            return false
        end
    end
    local tmp = path .. ".tmp"
    local ok = pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), tmp)
    if not ok then
        return false
    end
    -- Sync uv.fs_rename returns nil,err on failure (it does NOT raise), so `pcall(...) == true` would report
    -- success on a failed rename — capture the real result and clean up the dead .tmp.
    local renamed_ok, renamed = pcall(uv.fs_rename, tmp, path)
    if not (renamed_ok and renamed == true) then
        pcall(uv.fs_unlink, tmp)
        return false
    end
    return true
end

--- Read + decode the JSON document at `path`, or an empty table on missing/invalid.
---@param path string
---@return table<string, any>
local function read_doc(path)
    if vim.fn.filereadable(path) == 0 then
        return {}
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return {}
    end
    local decoded_ok, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
    if decoded_ok and type(doc) == "table" then
        return doc
    end
    return {}
end

--- Open a JSON backend at `opts.path`.
---@param opts { path: string }
---@return LvimUtilsStoreJson
function M.open(opts)
    local self = setmetatable({ _path = opts.path, _cache = {} }, Json)
    self._cache = read_doc(self._path)
    return self
end

--- Load and return all values (re-reads the file).
---@return table<string, any>
function Json:load()
    self._cache = read_doc(self._path)
    return vim.deepcopy(self._cache)
end

--- All currently cached values.
---@return table<string, any>
function Json:all()
    return vim.deepcopy(self._cache)
end

--- Set one value and flush.
---@param key string
---@param value any
---@return boolean
function Json:write(key, value)
    self._cache[key] = value
    return self:flush()
end

--- Remove one value and flush.
---@param key string
---@return boolean
function Json:erase(key)
    self._cache[key] = nil
    return self:flush()
end

--- Write the whole document (atomic). `vim.json.encode` emits a single line (it has no indent option); a
--- per-key change is still a whole-line change, so the file stays git-diffable.
---@return boolean
function Json:flush()
    local ok, text = pcall(function()
        return vim.json.encode(self._cache)
    end)
    if not ok then
        return false
    end
    return atomic_write(self._path, text)
end

--- The backing file path (for mirror/watch).
---@return string
function Json:path()
    return self._path
end

--- A json backend is always "open".
---@return boolean
function Json:is_open()
    return true
end

--- Nothing to close.
function Json:close() end

return M
