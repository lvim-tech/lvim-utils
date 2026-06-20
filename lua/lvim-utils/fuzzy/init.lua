-- lua/lvim-utils/fuzzy/init.lua
-- Shared fuzzy MATCHING engine: rank a list of strings against a query. The engine is the native `fzf`
-- binary in `--filter` mode (no TUI) — candidates go in on stdin, fzf returns them matched + ranked by its
-- score; without fzf it falls back to a pure-Lua subsequence matcher. fzf's `--filter` does NOT emit match
-- positions, so they are computed locally (utils.match_indices) for highlighting. Used by the picker and by
-- the native cmdline-completion integration, so both share one engine/ranking.
--
---@module "lvim-utils.fuzzy"

local utils = require("lvim-utils.utils")

local M = {}

-- ─── result ordering (config.fuzzy.sort) ──────────────────────────────────────
-- A composable sort applied AFTER the fuzzy ranking. Each criterion compares two items
-- `{ text, is_dir, ext, rank }` and returns a number (<0 = a first, 0 = equal). `sort` (in config.fuzzy)
-- is a single preset name, a LIST of names applied in priority order, or a custom boolean comparator. The
-- fuzzy `rank` is always the final tiebreak, so the order is total + deterministic.

---@type table<string, fun(a: table, b: table): integer>
local CRITERIA = {
    score = function(a, b)
        return a.rank - b.rank
    end,
    dirs_first = function(a, b)
        return (a.is_dir and 0 or 1) - (b.is_dir and 0 or 1)
    end,
    files_first = function(a, b)
        return (a.is_dir and 1 or 0) - (b.is_dir and 1 or 0)
    end,
    ext = function(a, b)
        return a.ext < b.ext and -1 or (a.ext > b.ext and 1 or 0)
    end,
    length = function(a, b)
        return #a.text - #b.text
    end,
    alpha = function(a, b)
        return a.text < b.text and -1 or (a.text > b.text and 1 or 0)
    end,
}

--- Build a `table.sort` boolean comparator from the `sort` spec (a name, a list of names, or a function).
---@param spec string|string[]|fun(a: table, b: table): boolean|nil
---@return fun(a: table, b: table): boolean
local function comparator(spec)
    if type(spec) == "function" then
        return spec
    end
    local names = type(spec) == "table" and spec or { spec or "score" }
    local fns = {}
    for _, n in ipairs(names) do
        if CRITERIA[n] then
            fns[#fns + 1] = CRITERIA[n]
        end
    end
    return function(a, b)
        for _, f in ipairs(fns) do
            local r = f(a, b)
            if r ~= 0 then
                return r < 0
            end
        end
        return a.rank < b.rank -- deterministic final tiebreak
    end
end

--- Reorder `ranked` (`{ idx, match? }`, in fuzzy order) per `config.fuzzy.sort`. Decorates each entry with
--- `text`/`is_dir`/`ext`/`rank` for the criteria, sorts, and returns the reordered list (idx/match kept).
---@param ranked { idx: integer, match?: integer[] }[]
---@param texts string[]
---@return { idx: integer, match?: integer[] }[]
local function apply_sort(ranked, texts)
    local spec = (require("lvim-utils.config").fuzzy or {}).sort or "score"
    if spec == "score" then
        return ranked -- already in best-match order
    end
    local decorated = {}
    for rank, r in ipairs(ranked) do
        local t = texts[r.idx]
        decorated[rank] = {
            idx = r.idx,
            match = r.match,
            text = t,
            rank = rank,
            is_dir = t:sub(-1) == "/",
            ext = t:match("%.([%w_%-]+)/?$") or "",
        }
    end
    table.sort(decorated, comparator(spec))
    return decorated
end

---@type string?  cached fzf binary path ("" once probed-and-absent)
local fzf_bin

--- The fzf binary path, or nil when fzf is not installed.
---@return string?
local function fzf_path()
    if fzf_bin == nil then
        fzf_bin = vim.fn.exepath("fzf")
    end
    return (fzf_bin ~= "" and fzf_bin) or nil
end

--- Pure-Lua fallback: subsequence match + a simple score (earlier and tighter matches rank higher).
---@param texts string[]
---@param query string
---@return { idx: integer, match: integer[] }[]
local function lua_rank(texts, query)
    local scored = {}
    for i, t in ipairs(texts) do
        local m = utils.match_indices(query, t)
        if m then
            scored[#scored + 1] = { idx = i, match = m, score = m[1] * 1000 + (m[#m] - m[1]) }
        end
    end
    table.sort(scored, function(a, b)
        return a.score < b.score
    end)
    return scored
end

--- Rank `texts` against `query`, async. `cb` receives a list of `{ idx, match? }` in ranked order — `idx`
--- is the 1-based index into `texts`, `match` the 0-based matched-char indices (for highlighting; absent on
--- an empty query). Empty query = all, source order, no match. fzf when present (async via vim.system),
--- else the Lua fallback (synchronous, but `cb` is still called the same way).
---@param texts string[]
---@param query string
---@param cb fun(ranked: { idx: integer, match?: integer[] }[])
function M.filter(texts, query, cb)
    -- every path delivers through here so the config sort (dirs_first / ext / …) is applied uniformly
    local function deliver(ranked)
        cb(apply_sort(ranked, texts))
    end
    if query == "" then
        local out = {}
        for i = 1, #texts do
            out[i] = { idx = i }
        end
        deliver(out)
        return
    end
    local bin = fzf_path()
    if not bin or type(vim.system) ~= "function" then
        deliver(lua_rank(texts, query))
        return
    end
    -- Feed `idx\ttext` to `fzf --filter`, matching field 2 only; read back the ranked indices and attach the
    -- locally-computed match positions (fzf --filter emits none).
    local lines = {}
    for i, t in ipairs(texts) do
        lines[i] = i .. "\t" .. (t:gsub("[\t\n]", " "))
    end
    vim.system(
        { bin, "--filter", query, "--delimiter", "\t", "--nth", "2" },
        { stdin = table.concat(lines, "\n"), text = true },
        function(res)
            vim.schedule(function()
                local out = {}
                for line in (res.stdout or ""):gmatch("[^\n]+") do
                    local idx = tonumber(line:match("^(%d+)\t"))
                    if idx and texts[idx] then
                        out[#out + 1] = { idx = idx, match = utils.match_indices(query, texts[idx]) }
                    end
                end
                deliver(out)
            end)
        end
    )
end

return M
