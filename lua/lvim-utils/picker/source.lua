-- lua/lvim-utils/picker/source.lua
-- Shared SOURCE layer for the finder: the LISTING commands (files / directories), the content PREVIEW
-- reader, and the async line STREAMER. Both picker backends use it so they list and ignore IDENTICALLY:
--   • the tint backend (picker/init.lua) — streams the lines into the Lua-rendered list;
--   • the fzf-TUI backend (picker/fzf.lua) — runs the same command as fzf's `FZF_DEFAULT_COMMAND`.
-- The engine and what it ignores are user-configurable via `config.picker.source` (engine / exclude /
-- hidden / follow / respect_gitignore / file_types), so a project's fd / rg / fzf-lua setup is matched.
--
---@module "lvim-utils.picker.source"

local M = {}

-- ─── the single OPEN finder (shared across both backends) ─────────────────────
-- Opening ANY finder must first FULLY close the one already open — releasing its docked area — so the new
-- finder REPLACES it in place instead of stacking above it. The two backends (the tint picker/init.lua and
-- the fzf picker/fzf.lua) reserve DIFFERENT msgarea host segments, so neither closes the other on its own;
-- this one shared registry does. Each finder registers an `entry = { close = fn }` after it opens and clears
-- it on close; opening calls `close_active()` first.
---@type { close: fun() }?
M._active = nil

--- Close whatever finder is currently open (either backend), if any.
function M.close_active()
    local a = M._active
    M._active = nil
    if a and a.close then
        pcall(a.close)
    end
end

--- Register `entry` ({ close }) as the open finder.
---@param entry { close: fun() }
function M.set_active(entry)
    M._active = entry
end

--- Clear the registry if `entry` is still the open finder (called from a finder's own close).
---@param entry { close: fun() }
function M.clear_active(entry)
    if M._active == entry then
        M._active = nil
    end
end

--- The `guicursor` fragment for the finder INPUT caret, from `config.picker.caret` ({ hl, shape }). `modes`
--- is the guicursor mode-list to apply it to — "t" for the fzf terminal input, "i-ci-ve" for the tint
--- finder's insert prompt. Shared so both backends build it identically.
---@param modes string
---@return string
function M.caret_fragment(modes)
    local caret = (require("lvim-utils.config").picker or {}).caret or {}
    return modes .. ":" .. (caret.shape or "ver25") .. "-" .. (caret.hl or "LvimUiPickerCursor")
end

--- True when `bin` is an executable on PATH.
---@param bin string
---@return boolean
function M.has(bin)
    return vim.fn.executable(bin) == 1
end

--- Build the LIST command (argv) for `kind` ("files" | "dirs") from `config.picker.source` — the engine and
--- what it ignores are user-configurable (`engine` / `exclude` / `hidden` / `follow` / `respect_gitignore` /
--- `file_types`). `engine = "auto"` picks the first available (fd → fdfind → rg → find); `rg` can only list
--- files, so a `dirs` request with rg falls back to fd/find. `find` has no ignore-file support (it always
--- lists everything but the excluded paths).
---@param kind "files"|"dirs"
---@return string[]
function M.build_list_cmd(kind)
    local cfg = (require("lvim-utils.config").picker or {}).source or {}
    local hidden = cfg.hidden ~= false
    local follow = cfg.follow == true
    local no_ignore = cfg.respect_gitignore == false
    local exclude = cfg.exclude or {}
    local want = cfg.engine or "auto"
    local order = want == "auto" and { "fd", "fdfind", "rg", "find" } or { want }
    local eng
    for _, c in ipairs(order) do
        if M.has(c) then
            eng = c
            break
        end
    end
    eng = eng or "find"
    if kind == "dirs" and eng == "rg" then -- rg lists files only
        eng = (M.has("fd") and "fd") or (M.has("fdfind") and "fdfind") or "find"
    end

    if eng == "fd" or eng == "fdfind" then
        local argv = { eng, "--color", "never", "--strip-cwd-prefix" }
        if kind == "dirs" then
            argv[#argv + 1], argv[#argv + 2] = "--type", "d"
        else
            for _, t in ipairs(cfg.file_types or { "f" }) do
                argv[#argv + 1], argv[#argv + 2] = "--type", t
            end
        end
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "--exclude", x
        end
        return argv
    elseif eng == "rg" then -- files only
        local argv = { "rg", "--color", "never", "--files" }
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "-g", "!" .. x
        end
        return argv
    end
    -- find: no gitignore support, just exclude the named paths
    local argv = { "find", ".", "-type", kind == "dirs" and "d" or "f" }
    for _, x in ipairs(exclude) do
        argv[#argv + 1], argv[#argv + 2], argv[#argv + 3] = "-not", "-path", "*/" .. x .. "/*"
    end
    return argv
end

--- The command (argv) to LIST files under cwd, from config.picker.source.
---@return string[]
function M.file_list_cmd()
    return M.build_list_cmd("files")
end

--- The command (argv) to LIST directories under cwd, from config.picker.source.
---@return string[]
function M.dir_list_cmd()
    return M.build_list_cmd("dirs")
end

--- Build the ripgrep argv for a LIVE content search of `query`, sharing the file-source config so CONTENT
--- search matches what `files` LISTS (hidden / .gitignore / excluded dirs). `regex = false` (the default)
--- matches the query literally (`--fixed-strings`); `regex = true` treats it as a pattern.
---@param query string
---@param regex? boolean
---@return string[]
function M.grep_cmd(query, regex)
    local rg = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    local src = (require("lvim-utils.config").picker or {}).source or {}
    if src.hidden ~= false then
        rg[#rg + 1] = "--hidden"
    end
    if src.follow == true then
        rg[#rg + 1] = "--follow"
    end
    if src.respect_gitignore == false then
        rg[#rg + 1] = "--no-ignore"
    end
    for _, x in ipairs(src.exclude or {}) do
        rg[#rg + 1] = "-g"
        rg[#rg + 1] = "!" .. x
    end
    if not regex then
        rg[#rg + 1] = "--fixed-strings"
    end
    rg[#rg + 1] = "--"
    rg[#rg + 1] = query
    return rg
end

--- Build the ripgrep RELOAD shell string for the fzf-TUI live grep — a shell command containing a literal
--- `{q}` placeholder that fzf substitutes (shell-quoted) on every keystroke. The static flags are
--- shell-escaped here; `{q}` is left literal for fzf. Guarded with `[ -n {q} ]` so an EMPTY query lists
--- nothing (instead of rg's empty pattern matching every line), and `|| true` so "no matches" is not an error.
---@param regex? boolean
---@return string
function M.grep_reload(regex)
    local argv = M.grep_cmd("", regex) -- flags + a trailing "" placeholder we drop
    argv[#argv] = nil -- remove the empty query
    local parts = {}
    for _, a in ipairs(argv) do
        parts[#parts + 1] = vim.fn.shellescape(a)
    end
    return ("[ -n {q} ] && %s {q} || true"):format(table.concat(parts, " "))
end

--- Read up to `n` lines of `path` for a preview, with a filetype guessed from the name.
---@param path string
---@param n? integer
---@return string[] lines, string filetype
function M.read_preview(path, n)
    local ft = vim.filetype.match({ filename = path }) or ""
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.readfile(path, "", n or 500), ft
    end
    return { "[unreadable]" }, ""
end

--- Run an argv synchronously and return its stdout lines (empty on failure).
---@param argv string[]
---@return string[]
function M.run_lines(argv)
    local ok, res = pcall(vim.fn.systemlist, argv)
    if not ok or vim.v.shell_error ~= 0 then
        return type(res) == "table" and res or {}
    end
    return res or {}
end

--- Spawn `argv` and stream its stdout LINES asynchronously — `on_lines(lines)` is called (on the main loop)
--- for each batch of complete lines as they arrive, `on_done()` once at exit. NEVER blocks the editor (unlike
--- `run_lines`), so a huge tree (e.g. `~/`) lists incrementally instead of a multi-second freeze. Returns a
--- cancel function that kills the producer. Falls back to a one-shot sync read when `vim.system` is missing.
---@param argv string[]
---@param on_lines fun(lines: string[])
---@param on_done fun()
---@return fun() cancel
function M.spawn_stream(argv, on_lines, on_done)
    if type(vim.system) ~= "function" then
        local lines = M.run_lines(argv)
        vim.schedule(function()
            on_lines(lines)
            on_done()
        end)
        return function() end
    end
    local rest = "" -- partial trailing line carried between chunks
    local function emit(data, final)
        rest = rest .. data
        local lines, start = {}, 1
        while true do
            local nl = rest:find("\n", start, true)
            if not nl then
                break
            end
            lines[#lines + 1] = rest:sub(start, nl - 1)
            start = nl + 1
        end
        rest = rest:sub(start)
        if final and rest ~= "" then
            lines[#lines + 1] = rest
            rest = ""
        end
        if #lines > 0 then
            vim.schedule(function()
                on_lines(lines)
            end)
        end
    end
    local ok, sys = pcall(vim.system, argv, {
        text = true,
        stdout = function(err, data) -- libuv fast-event ctx; only string ops here, UI work is scheduled in emit
            if err or not data then
                return
            end
            emit(data, false)
        end,
    }, function()
        emit("", true) -- flush the final partial line, then signal done
        vim.schedule(on_done)
    end)
    if not ok then
        vim.schedule(on_done)
        return function() end
    end
    return function()
        pcall(function()
            sys:kill("sigterm")
        end)
    end
end

return M
