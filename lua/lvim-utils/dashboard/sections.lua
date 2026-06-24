-- lua/lvim-utils/dashboard/sections.lua
-- The built-in SECTION generators referenced by `{ section = "<name>" }` in config.dashboard.sections. Each
-- `M.<name>(item)` returns either a single item, a list of items, or a `fun(self)` producing them — the
-- render engine (dashboard.render.resolve) then flattens it. They pull their CONTENT from the user's config
-- (preset.header / preset.keys) or live data (oldfiles, git roots, startup stats); the module ships no baked-
-- in menu. No snacks code — an independent implementation of the same sections.
--
---@module "lvim-utils.dashboard.sections"

local uv = vim.uv or vim.loop
local M = {}

-- ─── shared data sources ──────────────────────────────────────────────────────

--- An iterator over recent files (`v:oldfiles`): deduplicated, existing on disk, and skipping the data /
--- cache / state dirs (which hold non-user scratch). `opts.filter(path)` further narrows.
---@param opts? { filter?: fun(path: string): boolean }
---@return fun(): string?
local function oldfiles(opts)
    opts = opts or {}
    local exclude = {}
    for _, d in ipairs({ vim.fn.stdpath("data"), vim.fn.stdpath("cache"), vim.fn.stdpath("state") }) do
        exclude[#exclude + 1] = vim.fs.normalize(d)
    end
    local list, seen, i = vim.v.oldfiles or {}, {}, 0
    return function()
        while true do
            i = i + 1
            local f = list[i]
            if not f then
                return nil
            end
            local nf = vim.fs.normalize(f)
            if not seen[nf] then
                seen[nf] = true
                local ok = true
                for _, e in ipairs(exclude) do
                    if nf:sub(1, #e + 1) == e .. "/" then
                        ok = false
                        break
                    end
                end
                if ok and (not opts.filter or opts.filter(nf)) and uv.fs_stat(nf) then
                    return f
                end
            end
        end
    end
end

--- The git work-tree root containing `path` (walks up for a `.git`), or nil. No subprocess.
---@param path string
---@return string?
local function git_root(path)
    local ok, root = pcall(vim.fs.root, path, ".git")
    return (ok and root) and vim.fs.normalize(root) or nil
end

--- Best-effort "is plugin `name` installed" — scans the runtimepath (works for lazy.nvim and vim.pack).
---@param name string
---@return boolean
local function have_plugin(name)
    for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        if p:find(name, 1, true) then
            return true
        end
    end
    return false
end

-- ─── sections ─────────────────────────────────────────────────────────────────

--- The HEADER banner — the configured `preset.header` (centred, with breathing room). Empty header → nothing.
---@return fun(self: table): table?
function M.header()
    return function(self)
        local h = self.opts.preset.header
        if not h or h == "" then
            return nil
        end
        return { header = h, padding = 2 }
    end
end

--- The KEY menu — a copy of the configured `preset.keys` (each `{ icon, key, desc, action }`). Empty → nothing.
---@return fun(self: table): table
function M.keys()
    return function(self)
        return vim.deepcopy(self.opts.preset.keys or {})
    end
end

--- RECENT FILES — the latest `limit` oldfiles as openable rows (an auto-assigned key each). `cwd` restricts to
--- a directory (`true` = the current working dir).
---@param item table  the section item (carries `limit` / `cwd` / `filter`)
---@return fun(self: table): table[]
function M.recent_files(item)
    return function()
        local opts = item or {}
        local limit = opts.limit or 5
        local root = opts.cwd and vim.fs.normalize(opts.cwd == true and vim.fn.getcwd() or opts.cwd) or nil
        local out = {}
        for f in oldfiles({ filter = opts.filter }) do
            if not root or vim.fs.normalize(f):sub(1, #root) == root then
                out[#out + 1] = {
                    file = f,
                    icon = "file",
                    action = ":e " .. vim.fn.fnameescape(f),
                    autokey = true,
                }
                if #out >= limit then
                    break
                end
            end
        end
        return out
    end
end

--- PROJECTS — the git roots of the recent files (deduped, up to `limit`), or a custom `dirs` list. Confirming
--- a project `:cd`s into it and opens the file finder (override with `opts.action(dir)`).
---@param item table  the section item (carries `limit` / `dirs` / `action` / `filter`)
---@return fun(self: table): table[]
function M.projects(item)
    return function()
        local opts = item or {}
        local limit = opts.limit or 5
        local out, seen = {}, {}
        local function add(dir)
            dir = vim.fs.normalize(dir)
            if seen[dir] or (opts.filter and not opts.filter(dir)) then
                return
            end
            seen[dir] = true
            out[#out + 1] = {
                file = dir,
                icon = "directory",
                autokey = true,
                action = function()
                    if opts.action then
                        return opts.action(dir)
                    end
                    vim.fn.chdir(dir)
                    pcall(function()
                        require("lvim-utils.picker").files()
                    end)
                end,
            }
        end
        if opts.dirs then
            local dirs = type(opts.dirs) == "function" and opts.dirs() or opts.dirs
            for _, d in ipairs(dirs) do
                add(d)
                if #out >= limit then
                    break
                end
            end
        else
            for f in oldfiles({}) do
                local root = git_root(vim.fn.fnamemodify(f, ":h"))
                if root then
                    add(root)
                    if #out >= limit then
                        break
                    end
                end
            end
        end
        return out
    end
end

--- STARTUP stat — a centred "loaded N plugins in Xms" line. Pulls from lazy.nvim's stats when present; pass
--- `item.text` (string or chunks) or `item.stats` (a `fun(): {loaded, count, ms}`) to override the source.
---@param item table
---@return fun(self: table): table
function M.startup(item)
    return function()
        local opts = item or {}
        if opts.text ~= nil then
            return { text = opts.text, align = "center", padding = opts.padding }
        end
        local stats
        if type(opts.stats) == "function" then
            stats = opts.stats()
        else
            local ok, s = pcall(function()
                return require("lazy.stats").stats()
            end)
            if ok and s and s.count then
                stats = { loaded = s.loaded, count = s.count, ms = math.floor((s.startuptime or 0) * 100 + 0.5) / 100 }
            end
        end
        if not stats then
            return { text = "", align = "center" }
        end
        return {
            align = "center",
            padding = opts.padding,
            text = {
                { "⚡ ", hl = "special" },
                { "Loaded ", hl = "footer" },
                { tostring(stats.loaded) .. "/" .. tostring(stats.count), hl = "special" },
                { " plugins in ", hl = "footer" },
                { tostring(stats.ms or 0) .. "ms", hl = "special" },
            },
        }
    end
end

--- SESSION restore — detects an installed session manager and returns an item whose action restores the last
--- session, or nil when none is found. Used standalone or referenced by a key (`{ section = "session" }`).
---@return table?
function M.session()
    local managers = {
        { "persistence.nvim", ":lua require('persistence').load()" },
        { "persisted.nvim", ":lua require('persisted').load()" },
        { "neovim-session-manager", ":SessionManager load_current_dir_session" },
        { "possession.nvim", ":PossessionLoadCwd" },
        { "auto-session", ":AutoSession restore" },
        { "mini.sessions", ":lua require('mini.sessions').read()" },
    }
    for _, m in ipairs(managers) do
        if have_plugin(m[1]) then
            return { action = m[2] }
        end
    end
    return nil
end

return M
