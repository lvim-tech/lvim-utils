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

--- Open `url` (or a path) with the system handler, reporting the REAL outcome.
---
--- `vim.ui.open` does not RAISE when no handler exists — it RETURNS `nil, err`. Every consumer that
--- wrapped it in `pcall` and branched on the status therefore took the success path even when nothing
--- opened, and their documented fallbacks (yank the URL, warn the user) were dead code. Four plugins had
--- that bug independently, which is why the knowledge lives here now instead of being rediscovered.
---
--- Returns `false, reason` when the URL could not be opened — a raise and a "no handler" both land there.
---@param url string
---@return boolean ok
---@return string? reason  why it did not open (nil on success)
function M.open_url(url)
    if type(url) ~= "string" or url == "" then
        return false, "no url"
    end
    if type(vim.ui.open) ~= "function" then
        return false, "vim.ui.open is unavailable"
    end
    local called, handle, err = pcall(vim.ui.open, url)
    if not called then
        return false, tostring(handle) -- pcall's second value is the ERROR here
    end
    if not handle then
        return false, err or "no handler"
    end
    return true, nil
end

return M
