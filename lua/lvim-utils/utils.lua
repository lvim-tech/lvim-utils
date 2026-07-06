-- lvim-utils: shared helper functions used across the lvim-tech plugins.
--
---@module "lvim-utils.utils"

local M = {}

--- Deep-merge `opts` into `target` IN PLACE. Maps (dict tables) are merged recursively;
--- lists (arrays) and scalars are REPLACED wholesale — so an override list is the list,
--- not an index-merge (`vim.tbl_deep_extend` would leave stale tail elements). Used by a
--- plugin's setup() to merge user options into its live config so every
--- require("<plugin>.config") reader sees the effective values.
---@param target table   The live config table (mutated in place)
---@param opts?  table    User overrides
---@return table target
function M.merge(target, opts)
    for k, v in pairs(opts or {}) do
        if type(v) == "table" and type(target[k]) == "table" and not vim.islist(v) then
            M.merge(target[k], v)
        else
            target[k] = v
        end
    end
    return target
end

--- Split a string into its UTF-8 characters (pure Lua, so it is safe in a fast event context — unlike
--- `vim.fn.split(s, "\\zs")`, which errors there). The pattern matches one lead byte + its continuation
--- bytes per character.
---@param s string
---@return string[]
local function utf8_chars(s)
    local out = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = c
    end
    return out
end

--- Case-insensitive SUBSEQUENCE match of `needle` against `haystack`: the 0-based CHAR indices in
--- `haystack` that the needle's characters matched (greedy, left-to-right) — the SAME shape the msgarea
--- grid highlights via an item's `match`. So a non-blink consumer can light up matches against a query
--- without a fuzzy engine: `item.match = utils.match_indices(query, item.text)`. Returns nil when the
--- needle is empty or not a subsequence (leave `match` unset). Character-based (multibyte-safe), and safe
--- to call from a fast event context (e.g. a `vim.system` callback) — uses no Vimscript functions.
---@param needle string
---@param haystack string
---@return integer[]?  0-based char indices, or nil
function M.match_indices(needle, haystack)
    if not needle or needle == "" then
        return nil
    end
    local nchars = utf8_chars(needle:lower())
    local hchars = utf8_chars((haystack or ""):lower())
    local idxs, ni = {}, 1
    for hi = 1, #hchars do
        if ni > #nchars then
            break
        end
        if hchars[hi] == nchars[ni] then
            idxs[#idxs + 1] = hi - 1 -- 0-based, to match blink's fuzzy indices
            ni = ni + 1
        end
    end
    if ni <= #nchars then
        return nil -- the needle was not fully matched
    end
    return idxs
end

return M
