-- Every module of the base plugin loads on its own.
--
-- lvim-utils is required by every other lvim-* plugin, usually module by module
-- (`require("lvim-utils.colors")`, `require("lvim-utils.highlight")`), so a module that only
-- loads as a side effect of another one is a break waiting for the first plugin that reaches
-- for it directly.

local root = PLUGIN_ROOT .. "/lua/lvim-utils"

--- Every module name under lua/lvim-utils, `init.lua` folded into its directory.
---@return string[]
local function modules()
    local out = {}
    local function walk(dir, prefix)
        for name, kind in vim.fs.dir(dir) do
            if kind == "directory" then
                walk(dir .. "/" .. name, prefix .. name .. ".")
            elseif name:match("%.lua$") then
                local stem = name:sub(1, -5)
                out[#out + 1] = stem == "init" and prefix:sub(1, -2) or (prefix .. stem)
            end
        end
    end
    walk(root, "lvim-utils.")
    table.sort(out)
    return out
end

describe("lvim-utils: every module loads")

local mods = modules()

it("there are modules to load at all", function()
    truthy(#mods > 5, "found only " .. #mods .. " modules under " .. root)
end)

for _, mod in ipairs(mods) do
    it(mod, function()
        local ok, err = pcall(require, mod)
        truthy(ok, tostring(err))
    end)
end
