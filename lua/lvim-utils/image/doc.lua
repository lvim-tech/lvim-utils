-- lvim-utils.image.doc: discover image references inside a DOCUMENT buffer (markdown / html / latex, plus
-- any language injected into them) via treesitter, and resolve each to a readable local file. The queries
-- ship privately with the plugin (`image/queries/<lang>/images.scm`) and are read straight off the runtime
-- path — NOT registered under a global query name — so they never merge with or clash against another
-- plugin's `images.scm`. This module is pure discovery: it returns `{ row, src }` anchors; the actual inline
-- rendering + lifecycle live in image/inline.
--
---@module "lvim-utils.image.doc"

local api = vim.api
local config = require("lvim-utils.image.config")

local M = {}

-- Compiled queries per language: a Query, or `false` when the language has no shipped query / it failed to
-- parse against the installed grammar (so we skip that language instead of erroring on every reconcile).
---@type table<string, vim.treesitter.Query|false>
local query_cache = {}

--- Load + parse the private `images.scm` for `lang` from the plugin's runtime files. Cached (incl. misses).
---@param lang string
---@return vim.treesitter.Query|nil
local function get_query(lang)
    local cached = query_cache[lang]
    if cached ~= nil then
        return cached or nil
    end
    local files = api.nvim_get_runtime_file("lua/lvim-utils/image/queries/" .. lang .. "/images.scm", false)
    local q = false
    if files[1] then
        local fd = io.open(files[1], "r")
        if fd then
            local src = fd:read("*a")
            fd:close()
            local ok, parsed = pcall(vim.treesitter.query.parse, lang, src)
            q = (ok and parsed) or false
        end
    end
    query_cache[lang] = q
    return q or nil
end

--- Whether `path`'s extension is a format the image module will attempt to display.
---@param path string
---@return boolean
local function displayable(path)
    local e = (path:match("%.([%w]+)$") or ""):lower()
    for _, fmt in ipairs(config.formats) do
        if fmt == e then
            return true
        end
    end
    return false
end

--- The project root for `buf`: the nearest ancestor holding a `.git` / common project marker, else nil.
---@param buf integer
---@return string|nil
local function project_root(buf)
    local name = api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    return vim.fs.root(buf, { ".git", ".hg", ".svn", "package.json", "Cargo.toml", "Makefile" })
        or vim.fs.root(name, { ".git" })
end

--- First readable + displayable candidate among a list (already absolute, normalized). nil if none.
---@param candidates string[]
---@return string|nil
local function first_readable(candidates)
    for _, p in ipairs(candidates) do
        p = vim.fs.normalize(p)
        if displayable(p) and vim.fn.filereadable(p) == 1 then
            return p
        end
    end
    return nil
end

--- Resolve a raw source string (markdown destination, html src attr, latex path) to an absolute, readable
--- local image path — or nil for a remote/data URI, an unreadable file, or a non-image extension. Surrounding
--- quotes/angle-brackets and any markdown title are stripped; `~` is expanded. A RELATIVE path is tried
--- against the buffer's directory, then the project root, then cwd; a `/`-ROOTED path is tried as a real
--- filesystem path AND (the common README case) as project-root/cwd-relative, so `/assets/logo.png` resolves
--- to `<root>/assets/logo.png` when that exists.
---@param raw string
---@param buf integer
---@return string|nil
local function resolve(raw, buf)
    local src = vim.trim(raw)
    src = src:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"):gsub("^<(.*)>$", "%1")
    -- A markdown destination may carry a title: `path "alt"` — keep only the path token.
    src = src:gsub('%s+".*$', ""):gsub("%s+'.*$", "")
    if src == "" then
        return nil
    end
    -- Skip remote / data / any scheme:// — inline rendering is local-file only for now.
    if src:find("^%a[%w+.-]*://") or src:find("^data:") then
        return nil
    end
    if src:sub(1, 1) == "~" then
        return first_readable({ vim.fn.expand("~") .. src:sub(2) })
    end

    local bufdir = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":h")
    local root = project_root(buf)
    local cwd = vim.fn.getcwd()
    local candidates = {}
    if src:sub(1, 1) == "/" then
        -- A real absolute path first; then interpret it as ROOT-relative (strip the leading slash) against the
        -- project root / cwd — this is how READMEs write `/assets/logo.png` for the repo, not the filesystem.
        candidates[#candidates + 1] = src
        local rel = src:gsub("^/+", "")
        if root then
            candidates[#candidates + 1] = root .. "/" .. rel
        end
        candidates[#candidates + 1] = cwd .. "/" .. rel
    else
        if bufdir ~= "" then
            candidates[#candidates + 1] = bufdir .. "/" .. src
        end
        if root then
            candidates[#candidates + 1] = root .. "/" .. src
        end
        candidates[#candidates + 1] = cwd .. "/" .. src
    end
    return first_readable(candidates)
end

--- The last node of a capture value (Neovim returns a LIST of nodes per capture in `iter_matches`; older
--- builds a single node). Normalises both.
---@param v TSNode|TSNode[]
---@return TSNode
local function last_node(v)
    return type(v) == "table" and v[#v] or v
end

--- Discover every displayable inline image in `buf`. Walks ALL language trees (markdown_inline / html /
--- latex are injected into their host doc), runs each language's `images.scm`, and returns anchors sorted
--- by line. Each anchor: `row` (0-based line to render the image UNDER — the image node's end row) and the
--- resolved absolute `src`. Duplicate (row, src) pairs are collapsed.
---@param buf integer
---@return { row: integer, src: string }[]
function M.discover(buf)
    if not api.nvim_buf_is_valid(buf) then
        return {}
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf)
    if not ok or not parser then
        return {}
    end
    pcall(parser.parse, parser, true)

    local seen = {}
    local out = {}
    parser:for_each_tree(function(tree, ltree)
        local lang = ltree:lang()
        local query = get_query(lang)
        if not query then
            return
        end
        local root = tree:root()
        for _, match in query:iter_matches(root, buf, 0, -1) do
            local src_node, image_node
            for id, nodes in pairs(match) do
                local name = query.captures[id]
                if name == "image.src" then
                    src_node = last_node(nodes)
                elseif name == "image" then
                    image_node = last_node(nodes)
                end
            end
            if src_node then
                local raw = vim.treesitter.get_node_text(src_node, buf)
                local src = resolve(raw, buf)
                if src then
                    local anchor = image_node or src_node
                    local row = select(3, anchor:range()) -- end_row (0-based)
                    local key = row .. "\0" .. src
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = { row = row, src = src }
                    end
                end
            end
        end
    end)

    table.sort(out, function(a, b)
        return a.row < b.row
    end)
    return out
end

return M
