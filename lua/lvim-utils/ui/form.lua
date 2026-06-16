-- lvim-utils.ui.form: a `frame` center provider for typed, EDITABLE rows — bool (toggle), select /
-- segmented (cycle), int / number / string / text (edit via vim.ui.input), action (run), and
-- expandable tree rows. Reuses the rows.lua row model (row_display / navigation). Non-selectable rows
-- (spacers) are skipped by j/k; the focused row is shown via the panel's cursorline.
--
-- A `form` is the center of the `tabs` / popup-style frames; switching a tab swaps the row set in place
-- (`set_rows`), and because the row tables are mutated IN PLACE, a consumer's captured rows (e.g. the
-- Quit dialog's action closures) always see the current values.
--
---@module "lvim-utils.ui.form"

local rows = require("lvim-utils.ui.rows")
local util = require("lvim-utils.ui.util")

local api = vim.api

local M = {}

--- Create a form provider.
---@param opts { rows: Row[], on_change?: fun(row: Row), ico?: table }
---@return table provider
function M.new(opts)
    local model = opts.rows or {}
    local ico = opts.ico or rows.icons()
    local on_change = opts.on_change
    local pan

    -- The visible rows (tree flattened, collapsed children hidden). The window line N maps to flat[N].
    local function flat()
        return rows.flatten(model, false)
    end
    local function refresh()
        if pan and pan.refresh then
            pan.refresh()
        end
    end
    local function cur_line()
        if pan and pan.win and api.nvim_win_is_valid(pan.win) then
            return api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end
    local function move(delta)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        local nxt = rows.next_selectable(flat(), cur_line(), delta)
        if nxt then
            pcall(api.nvim_win_set_cursor, pan.win, { nxt, 0 })
        end
    end

    --- Act on the focused row by type. `st` is the frame state (for action rows that close).
    ---@param st table
    local function activate(st)
        local row = flat()[cur_line()]
        if not row then
            return
        end
        local t = row.type
        if row.children then
            row.expanded = not row.expanded
            refresh()
        elseif t == "bool" or t == "boolean" then
            row.value = not row.value
            if on_change then
                on_change(row)
            end
            refresh()
        elseif t == "select" or t == "segmented" then
            local list = row.options or {}
            if #list > 0 then
                local cur = 1
                for i, o in ipairs(list) do
                    if o == row.value then
                        cur = i
                        break
                    end
                end
                row.value = list[(cur % #list) + 1]
                if on_change then
                    on_change(row)
                end
                refresh()
            end
        elseif t == "int" or t == "integer" or t == "float" or t == "number" or t == "string" or t == "text" then
            local numeric = t ~= "string" and t ~= "text"
            vim.ui.input({
                prompt = (row.label or row.name or "") .. ": ",
                default = tostring(row.value ~= nil and row.value or row.default or ""),
            }, function(input)
                if input ~= nil then
                    row.value = numeric and (tonumber(input) or row.value) or input
                    if on_change then
                        on_change(row)
                    end
                    refresh()
                end
            end)
        elseif t == "action" and row.run then
            row.run(row.value, function()
                st.close()
            end)
        end
    end

    return {
        hide_cursor = true,
        cursorline = true,
        size = function()
            local fr = flat()
            local w = 1
            for _, r in ipairs(fr) do
                w = math.max(w, util.dw(rows.row_display(r, ico)) + 4)
            end
            return w, math.max(1, #fr)
        end,
        render = function(width)
            local fr = flat()
            local lines, hls = {}, {}
            for i, r in ipairs(fr) do
                local disp = rows.row_display(r, ico)
                if not rows.is_selectable(r) then
                    lines[i] = r.center and util.center(disp, width) or util.lpad(disp, width, 2)
                else
                    lines[i] = util.lpad(disp, width, 2)
                    -- Colour the leading type icon; the rest reads on the panel background.
                    local icon_str = rows.row_icon_info(r, ico)
                    if icon_str and #icon_str > 0 then
                        hls[#hls + 1] = { i - 1, 2, 2 + #icon_str, "LvimUiRowIconInactive" }
                    end
                end
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            local fr = flat()
            local first = rows.first_selectable(fr) or 1
            vim.schedule(function()
                if p.win and api.nvim_win_is_valid(p.win) then
                    pcall(api.nvim_win_set_cursor, p.win, { first, 0 })
                end
            end)
            map({ "j", "<Down>" }, function()
                move(1)
            end)
            map({ "k", "<Up>" }, function()
                move(-1)
            end)
            map({ "<CR>", "<Space>" }, function()
                activate(st)
            end)
        end,
        --- Swap the row set in place (tab switch) and re-render.
        ---@param new_rows Row[]
        set_rows = function(new_rows)
            model = new_rows
            refresh()
        end,
    }
end

return M
