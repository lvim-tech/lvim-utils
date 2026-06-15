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

return M
