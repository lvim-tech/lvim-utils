-- The two primitives every lvim-* plugin is built on.
--
-- `merge` is how every plugin applies a user's options to its defaults, and `match_indices` is how a
-- non-fuzzy consumer highlights a query — both called from fast event contexts, both impossible to
-- change safely without a statement of what they promise. This is that statement.

local utils = require("lvim-utils.utils")

describe("lvim-utils.utils.merge")

it("merges nested dictionaries rather than replacing them", function()
    local target = { a = { x = 1, y = 2 }, b = 3 }
    utils.merge(target, { a = { y = 9 } })
    eq({ a = { x = 1, y = 9 }, b = 3 }, target)
end)

it("mutates the target in place and returns it", function()
    -- The contract the config hub depends on: a module that hoisted `local cfg = config.cursor` at
    -- load time must keep seeing the effective values after setup().
    local target = { a = 1 }
    local alias = target
    local returned = utils.merge(target, { a = 2, b = 3 })
    eq(2, alias.a, "the alias sees the new value")
    eq(3, alias.b)
    truthy(returned == target, "the target itself is returned")
end)

it("replaces a list instead of merging it index by index", function()
    -- Merging lists positionally would leave a longer old list's tail behind: setting
    -- `keys = { "a" }` over `{ "x", "y", "z" }` must mean one key, not "a", "y", "z".
    local target = { keys = { "x", "y", "z" } }
    utils.merge(target, { keys = { "a" } })
    eq({ keys = { "a" } }, target)
end)

it("treats an EMPTY table as a list, so it clears the subtree", function()
    -- Lua cannot tell an empty dictionary from an empty list, and `vim.islist({})` is true. So an
    -- empty table in the OPTIONS clears what the defaults held — which is how a config disables a
    -- whole list of keymaps. Pinned here because it is a sharp edge either way: anyone changing it
    -- to "an empty table changes nothing" breaks that idiom deliberately, not by accident.
    local target = { keys = { "x", "y" }, nested = { a = 1 } }
    utils.merge(target, { keys = {}, nested = {} })
    eq({ keys = {}, nested = {} }, target)
end)

it("accepts no options at all", function()
    local target = { a = 1 }
    eq({ a = 1 }, utils.merge(target, nil))
end)

it("copies a function value as the value it is", function()
    local fn = function() end
    local target = {}
    utils.merge(target, { hook = fn })
    truthy(target.hook == fn)
end)

describe("lvim-utils.utils.match_indices")

it("returns the 0-based char indices of a subsequence", function()
    eq({ 0, 1, 2 }, utils.match_indices("abc", "abcdef"))
    eq({ 0, 3 }, utils.match_indices("ad", "abcd"))
end)

it("ignores case", function()
    eq({ 0, 1 }, utils.match_indices("AB", "abc"))
    eq({ 0, 1 }, utils.match_indices("ab", "ABC"))
end)

it("counts CHARACTERS, not bytes", function()
    -- The indices are handed to extmark highlighting per character; counting bytes would light up
    -- the middle of a Cyrillic letter.
    eq({ 0, 1 }, utils.match_indices("дб", "дбв"))
    eq({ 2 }, utils.match_indices("в", "дбв"))
end)

it("says nothing when there is nothing to say", function()
    eq(nil, utils.match_indices("", "abc"), "an empty needle is not a match")
    eq(nil, utils.match_indices("zz", "abc"), "a needle that is not a subsequence")
    eq(nil, utils.match_indices("cba", "abc"), "order matters")
end)
