-- lvim-utils.icons.on_bg: an lvim-icons IMAGE icon painted on a background of the caller's own (a bar,
-- a winbar). Its group's foreground is the terminal image id — it must survive; only the bg is added.

local iconlib = require("lvim-utils.icons")

describe("lvim-utils.icons.on_bg")

it("leaves a font icon to the caller", function()
    eq(nil, iconlib.on_bg({ glyph = "x", hl = "Normal", width = 1, name = "x" }, "#101010"))
    eq(nil, iconlib.on_bg({ glyph = "x", hl = "", width = 2, name = "x", image = true }, "#101010"))
end)

it("keeps the image id in the foreground and adds the background, under the icon's own prefix", function()
    vim.api.nvim_set_hl(0, "LvimIconImg_test", { fg = 0x0a0b0c })
    local r = { glyph = "", hl = "LvimIconImg_test", width = 2, name = "test", image = true }
    local group = iconlib.on_bg(r, "#202020")
    eq("LvimIconImg_test_on_202020", group)
    local got = vim.api.nvim_get_hl(0, { name = group })
    eq(0x0a0b0c, got.fg, "the image id")
    eq(0x202020, got.bg, "the bar background")
end)

it("re-asserts the group on every call (a :colorscheme clears it)", function()
    vim.api.nvim_set_hl(0, "LvimIconImg_test", { fg = 0x0a0b0c })
    local r = { glyph = "", hl = "LvimIconImg_test", width = 2, name = "test", image = true }
    local group = iconlib.on_bg(r, 0x303030)
    vim.cmd("hi clear " .. group)
    iconlib.on_bg(r, 0x303030)
    eq(0x0a0b0c, vim.api.nvim_get_hl(0, { name = group }).fg)
end)

it("named after a background GROUP: what that group shows, re-derived when the theme changes", function()
    vim.api.nvim_set_hl(0, "LvimIconImg_test", { fg = 0x0a0b0c })
    vim.api.nvim_set_hl(0, "TestBar", { fg = 0xffffff, bg = 0x111111 })
    local r = { glyph = "", hl = "LvimIconImg_test", width = 2, name = "test", image = true }
    local group = iconlib.on_bg(r, "TestBar")
    eq("LvimIconImg_test_on_TestBar", group, "the name does not carry a colour")
    eq(0x111111, vim.api.nvim_get_hl(0, { name = group }).bg)
    -- a new theme: the bar changes and :colorscheme clears every group
    vim.api.nvim_set_hl(0, "TestBar", { fg = 0xffffff, bg = 0x222222 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    vim.wait(50, function()
        return false
    end)
    eq(0x222222, vim.api.nvim_get_hl(0, { name = group }).bg, "re-derived from the bar")
    eq(0x0a0b0c, vim.api.nvim_get_hl(0, { name = group }).fg, "the image id kept")
end)

it("a reversed group shows its fg as the background", function()
    vim.api.nvim_set_hl(0, "LvimIconImg_test", { fg = 0x0a0b0c })
    vim.api.nvim_set_hl(0, "TestPill", { fg = 0x62966d, bg = 0x292b36, reverse = true })
    local r = { glyph = "", hl = "LvimIconImg_test", width = 2, name = "test", image = true }
    eq(0x62966d, vim.api.nvim_get_hl(0, { name = iconlib.on_bg(r, "TestPill") }).bg)
end)

describe("lvim-utils.icons: putting an icon on a buffer line")

local ns = vim.api.nvim_create_namespace("lvim-utils-icons-test")

it("a real icon is text of the line, coloured in place", function()
    local r = { glyph = "X", hl = "Comment", width = 1, name = "x", placement = "real" }
    eq("X ", iconlib.text(r))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { iconlib.text(r) .. "main.rs" })
    iconlib.mark(buf, ns, 0, 0, r)
    local m = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
    eq(1, m[4].end_col)
    eq("Comment", m[4].hl_group)
end)

it("a virtual icon is not text: an inline extmark that stays left of what is typed", function()
    local r = { glyph = "XX", hl = "LvimIconImg_x", width = 2, name = "x", image = true, placement = "virtual" }
    eq("", iconlib.text(r), "nothing in the line")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "main.rs" })
    iconlib.mark(buf, ns, 0, 0, r)
    eq({ "main.rs" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "the buffer text is untouched")
    local d = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1][4]
    eq("inline", d.virt_text_pos)
    eq({ { "XX", "LvimIconImg_x" }, { " " } }, d.virt_text)
    eq(false, d.right_gravity)
    eq("combine", d.hl_mode)
end)

it("a caller colour applies to a font icon, never to an image", function()
    local font = { glyph = "X", hl = "Comment", width = 1, name = "x", placement = "virtual" }
    local img = { glyph = "XX", hl = "LvimIconImg_x", width = 2, name = "x", image = true, placement = "virtual" }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
    iconlib.mark(buf, ns, 0, 0, font, { hl = "Directory" })
    iconlib.mark(buf, ns, 1, 0, img, { hl = "Directory" })
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq("Directory", marks[1][4].virt_text[1][2])
    eq("LvimIconImg_x", marks[2][4].virt_text[1][2], "the image keeps its id group")
end)

describe("lvim-utils.icons.ui_text")

it("leaves words, letters and empty text alone", function()
    eq("Hello", (iconlib.ui_text("Hello", "Comment")))
    eq(" M ", (iconlib.ui_text(" M ", "Comment")), "a letter badge is not an icon")
    eq("", (iconlib.ui_text("", "Comment")))
    eq(nil, (iconlib.ui_text(nil, "Comment")))
    local t, h, img = iconlib.ui_text(" \u{F07B}\u{F07C} ", "Comment")
    eq(" \u{F07B}\u{F07C} ", t, "two glyphs are not one icon")
    eq("Comment", h)
    eq(false, img)
end)

it("hands a single glyph to the provider, keeping the blanks around it", function()
    local ok, icons = pcall(require, "lvim-icons")
    if not ok then
        return skip("hands a single glyph to the provider", "needs lvim-icons beside this checkout")
    end
    local orig = icons.ui
    icons.ui = function(o)
        return { glyph = "<" .. o.glyph .. ">", hl = "Img_" .. o.hl, width = 2, image = true }
    end
    local t, h, img = iconlib.ui_text("  \u{E702}  ", "Git")
    icons.ui = orig
    eq("  <\u{E702}>  ", t)
    eq("Img_Git", h)
    eq(true, img)
end)
