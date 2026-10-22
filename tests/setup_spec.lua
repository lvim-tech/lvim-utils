-- What setup() promises: the whole option set arrives, and running it twice changes nothing.

local utils_cfg = require("lvim-utils.config")

--- The autocmds registered under `group`, by name.
---@param group string
---@return integer
local function autocmds_in(group)
    local ok, list = pcall(vim.api.nvim_get_autocmds, { group = group })
    return ok and #list or -1
end

describe("lvim-utils.config.setup: the options arrive")

it("forwards dock, section and ui, not only cursor", function()
    -- These three used to be dropped on the floor: setup() forwarded `cursor` alone, so a user's
    -- override of the dock keys, the fold tint or the chrome theme did nothing at all.
    utils_cfg.setup({
        cursor = { hide_on_cmdline = false },
        dock = { enable = false },
        section = { tint = 0.42 },
        ui = { tint = { panel = 0.33 } },
    })
    eq(false, utils_cfg.cursor.hide_on_cmdline, "cursor")
    eq(false, utils_cfg.dock.enable, "dock")
    eq(0.42, utils_cfg.section.tint, "section")
    eq(0.33, utils_cfg.ui.tint.panel, "ui")
end)

it("merges in place, so a hoisted alias keeps seeing the effective values", function()
    -- Every module does `local cfg = require("lvim-utils.config").cursor` at load time. If setup()
    -- reassigned the table instead of merging into it, each of them would be reading a dead copy.
    local alias = utils_cfg.cursor
    utils_cfg.setup({ cursor = { hide_on_cmdline = true } })
    eq(true, alias.hide_on_cmdline)
    truthy(alias == utils_cfg.cursor, "the table itself must not be replaced")
end)

it("leaves untouched keys alone", function()
    local tint_hover = utils_cfg.section.tint_hover
    utils_cfg.setup({ section = { tint = 0.11 } })
    eq(tint_hover, utils_cfg.section.tint_hover, "a sibling key survives an override")
end)

describe("lvim-utils.setup: running it twice")

it("leaves one of each autocmd, not two", function()
    local base = require("lvim-utils")
    base.setup({ cursor = { filetypes = { "lvim-test-ft" } } })
    local first = {
        colors = autocmds_in("LvimUtilsColors"),
        cursor = autocmds_in("LvimUtilsCursor"),
    }
    base.setup({ cursor = { filetypes = { "lvim-test-ft" } } })
    local second = {
        colors = autocmds_in("LvimUtilsColors"),
        cursor = autocmds_in("LvimUtilsCursor"),
    }
    truthy(first.colors > 0, "the colors group should have autocmds, got " .. first.colors)
    eq(first, second, "a second setup() must not stack handlers")
end)

describe("lvim-utils: health")

it("the health check runs to completion", function()
    local health = require("lvim-utils.health")
    truthy(type(health.check) == "function", "no check() to run")
    local ok, err = pcall(health.check)
    truthy(ok, tostring(err))
end)
