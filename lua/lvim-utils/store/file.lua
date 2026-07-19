-- lvim-utils.store.file: the plain-file backend.
-- A flat `key=value` text file (one field per line), values stored as raw strings — for a few
-- simple settings that must be human-readable and readable EARLY / externally (a shell script,
-- or Neovim at startup before plugins load — e.g. the chosen colorscheme). Writes are ATOMIC
-- (temp file + rename), so a concurrent early read never sees a half-written file.
--
-- Values are strings: numbers/booleans are stringified on write and come back as strings; use
-- the json backend when you need typed/nested data.
--
---@module "lvim-utils.store.file"

local uv = vim.uv or vim.loop

local M = {}

---@class LvimUtilsStoreFile
---@field _path  string
---@field _cache table<string, string>
local File = {}
File.__index = File

--- Atomically write `lines` to `path` (temp + rename). Creates the parent dir if needed.
---@param path string
---@param lines string[]
---@return boolean
local function atomic_write(path, lines)
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        if not pcall(vim.fn.mkdir, dir, "p") then
            return false
        end
    end
    local tmp = path .. ".tmp"
    local ok = pcall(vim.fn.writefile, lines, tmp)
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

--- Parse a `key=value` file into a table (one field per line; lines without a `=` are skipped). A single raw
--- value written by a `mirror` target is read back through the static `store.read_file`, not this backend.
---@param path string
---@return table<string, string>
local function parse(path)
    local out = {}
    if vim.fn.filereadable(path) == 0 then
        return out
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return out
    end
    for _, line in ipairs(lines) do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            out[k] = v
        end
    end
    return out
end

--- Open a plain-file backend at `opts.path`.
---@param opts { path: string }
---@return LvimUtilsStoreFile
function M.open(opts)
    local self = setmetatable({ _path = opts.path, _cache = {} }, File)
    self._cache = parse(self._path)
    return self
end

--- Load and return all values.
---@return table<string, string>
function File:load()
    self._cache = parse(self._path)
    return vim.deepcopy(self._cache)
end

--- All currently cached values.
---@return table<string, string>
function File:all()
    return vim.deepcopy(self._cache)
end

--- Persist one value (rewrites the whole file atomically). Non-strings are stringified.
---@param key string
---@param value any
---@return boolean
function File:write(key, value)
    self._cache[key] = (value == nil) and nil or tostring(value)
    return self:flush()
end

--- Remove one value.
---@param key string
---@return boolean
function File:erase(key)
    self._cache[key] = nil
    return self:flush()
end

--- Rewrite the file from the cache (atomic). Keys are sorted for a stable, diff-friendly file.
---@return boolean
function File:flush()
    local keys = {}
    for k in pairs(self._cache) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do
        lines[#lines + 1] = k .. "=" .. self._cache[k]
    end
    return atomic_write(self._path, lines)
end

--- The backing file path (for mirror/watch).
---@return string
function File:path()
    return self._path
end

--- A file backend is always "open" (no connection to fail).
---@return boolean
function File:is_open()
    return true
end

--- Nothing to close.
function File:close() end

return M
