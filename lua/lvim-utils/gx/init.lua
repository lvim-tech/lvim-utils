-- lua/lvim-utils/gx/init.lua
-- Universal "open under cursor" — resolves URLs, local paths (with optional
-- :line:col suffix), bare domain/repo references, and file-manager buffers
-- (neo-tree, nvim-tree, oil, mini.files, netrw) via registered adapters,
-- then falls back to a proximity scan of nearby lines.
--
-- Public API:
--   M.setup(opts?)          – initialise with optional config overrides
--   M.register_adapter(def) – add a custom file-manager adapter at runtime
--   M.map_default()         – bind gx → :GxOpen in normal mode
--   M.open_current()        – programmatically trigger open on current cursor

local M = {}

local uv = vim.uv or vim.loop

local _NS = vim.api.nvim_create_namespace("LvimGxTempHL")

---@class GxConfig
---@field highlight_match           boolean         Briefly highlight the matched token
---@field highlight_duration_ms     integer         Milliseconds to keep the highlight
---@field system_open_cmd           string|nil      Override the system opener (nil = auto-detect)
---@field force_system_open_local   boolean         Use system opener for local files too
---@field allow_bare_domains        boolean         Treat "domain.tld/path" strings as HTTPS URLs
---@field icon_guard                boolean         Skip tokens that look like Nerd Font glyphs
---@field dir_open_strategy         "system"|"edit" How to open directories
---@field search_forward_if_none    boolean         Scan lines below cursor when nothing found
---@field search_backward_if_none   boolean         Scan lines above cursor when nothing found
---@field search_max_lines          integer         Maximum lines to scan in each direction
---@field max_sequential_candidates integer         Stop collecting tokens after this many
---@field pattern                   string          Lua pattern used to extract tokens from a line
---@field adapters                  table<string, boolean>  Enable/disable built-in adapters by name
---@field extra_adapters            table           Additional adapter definitions to register

---@type GxConfig
local cfg = require("lvim-utils.config").gx

---@type table  List of registered adapter definitions.
local adapters = {}
local adapters_initialized = false

-- ─── environment ──────────────────────────────────────────────────────────────

--- Return true when running in a headless environment with no display server.
--- Checks DISPLAY (X11), WAYLAND_DISPLAY, and WSL_DISTRO_NAME.
--- Always returns false on Windows (Windows handles its own open commands).
---@return boolean
local function env_headless()
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return false
	end
	return not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") and not os.getenv("WSL_DISTRO_NAME")
end

--- Return the appropriate system opener command for the current OS.
--- Respects cfg.system_open_cmd when set explicitly.
---@return string  "open" (macOS) | "start" (Windows) | "xdg-open" (Linux)
local function detect_opener()
	if cfg.system_open_cmd then
		return cfg.system_open_cmd
	end
	if vim.fn.has("mac") == 1 then
		return "open"
	end
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return "start"
	end
	return "xdg-open"
end

-- ─── string / path helpers ────────────────────────────────────────────────────

--- Normalise a file path: convert backslashes, collapse double slashes,
--- and strip a trailing slash (unless the path is the filesystem root "/").
---@param p string
---@return string
local function normalize(p)
	p = p:gsub("\\", "/"):gsub("//+", "/")
	if #p > 1 and p:sub(-1) == "/" then
		p = p:sub(1, -2)
	end
	return p
end

--- Return true when the string starts with http://, https://, or file://.
---@param s string
---@return boolean
local function is_url(s)
	return s:match("^https?://") ~= nil or s:match("^file://") ~= nil
end

--- Strip common trailing punctuation that is unlikely to be part of a URL/path.
---@param s string
---@return string
local function strip_punct(s)
	return (s:gsub("[)>.,;:]+$", ""))
end

--- Remove surrounding single or double quotes from a string.
---@param s string
---@return string
local function unquote(s)
	if s:match('^".*"$') or s:match("^'.*'$") then
		return s:sub(2, -2)
	end
	return s
end

--- Expand a leading "~" to the user's home directory.
---@param p string
---@return string
local function expand_home(p)
	return p:sub(1, 1) == "~" and vim.fn.expand(p) or p
end

--- Parse an optional ":line" or ":line:col" suffix from a path string.
---@param s string  Raw token (may contain :line:col suffix)
---@return string   file part
---@return integer|nil  line number
---@return integer|nil  column number
local function split_file_loc(s)
	local f, l, c = s:match("^(.+):(%d+):(%d+)$")
	if f then
		return f, tonumber(l), tonumber(c)
	end
	f, l = s:match("^(.+):(%d+)$")
	if f then
		return f, tonumber(l), nil
	end
	return s, nil, nil
end

--- Return true when the path exists on disk (uses libuv fs_stat).
---@param p string|nil
---@return boolean
local function exists(p)
	if not p then
		return false
	end
	return uv.fs_stat(p) ~= nil
end

--- Return true when the path points to a directory.
---@param p string
---@return boolean
local function is_dir(p)
	local st = uv.fs_stat(p)
	return st ~= nil and st.type == "directory"
end

--- Return true when the string looks like a bare "domain.tld/owner/repo"
--- reference that should be opened as an HTTPS URL.
---@param s string
---@return boolean
local function is_domain_repo(s)
	if not cfg.allow_bare_domains then
		return false
	end
	return s:match("^[%w%.%-]+%.[%w%.%-]+/.+") ~= nil
end

--- Return true when the token consists entirely of non-alphanumeric glyphs
--- and is short enough to be a Nerd Font icon rather than a path or URL.
---@param token string|nil
---@return boolean
local function is_icon(token)
	if not cfg.icon_guard then
		return false
	end
	if not token or token == "" then
		return true
	end
	if token:match("[%w%./~]") then
		return false
	end
	return vim.fn.strchars(token) <= 6
end

-- ─── highlight ────────────────────────────────────────────────────────────────

--- Briefly highlight a byte range in a buffer with the Visual group,
--- then remove the extmark after cfg.highlight_duration_ms milliseconds.
---@param buf   integer  Buffer handle
---@param lnum0 integer  Zero-based line number
---@param s     integer  Start byte column (0-based)
---@param e     integer|nil  End byte column; defaults to end-of-line
local function highlight_temp(buf, lnum0, s, e)
	if not cfg.highlight_match then
		return
	end
	if not e then
		e = #(vim.api.nvim_buf_get_lines(buf, lnum0, lnum0 + 1, false)[1] or "")
	end
	local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, _NS, lnum0, s, {
		end_col = e,
		hl_group = "Visual",
		hl_mode = "combine",
		priority = 150,
	})
	if not ok then
		return
	end
	vim.defer_fn(function()
		pcall(vim.api.nvim_buf_del_extmark, buf, _NS, id)
	end, cfg.highlight_duration_ms)
end

-- ─── token scanning ───────────────────────────────────────────────────────────

---@class GxToken
---@field s    integer  1-based start column of the match in the line string
---@field e    integer  1-based end column of the match in the line string
---@field text string   Cleaned token text (unquoted, trailing punct stripped)

--- Scan a line and return all tokens that match the configured Lua pattern.
---@param line    string
---@param pattern string
---@return GxToken[]
local function scan_tokens(line, pattern)
	local out, idx = {}, 1
	while true do
		local s, e = line:find(pattern, idx)
		if not s then
			break
		end
		local text = strip_punct(unquote(line:sub(s, e)))
		out[#out + 1] = { s = s, e = e, text = text }
		idx = e >= idx and e + 1 or idx + 1 -- guard against zero-length matches
	end
	return out
end

--- Return the token whose column range covers the cursor column,
--- skipping icon-like tokens.
---@param line    string
---@param col1    integer  1-based cursor column
---@param pattern string
---@return GxToken|nil
local function token_at(line, col1, pattern)
	for _, t in ipairs(scan_tokens(line, pattern)) do
		if col1 >= t.s and col1 <= t.e and not is_icon(t.text) then
			return t
		end
	end
end

--- Return all non-empty, non-icon tokens found in a line.
---@param line    string
---@param pattern string
---@return GxToken[]
local function tokens_in(line, pattern)
	local out = {}
	for _, t in ipairs(scan_tokens(line, pattern)) do
		if not is_icon(t.text) and t.text ~= "" then
			out[#out + 1] = t
		end
	end
	return out
end

-- ─── built-in file-manager adapters ──────────────────────────────────────────
-- Each adapter is a table with:
--   name   string    unique identifier
--   detect fun(ctx)  returns true when this adapter applies to the current buffer
--   get    fun(ctx)  returns { path: string, type: "file"|"dir"|"unknown" } or nil

---@class GxAdapter
---@field name   string
---@field detect fun(ctx: GxContext): boolean
---@field get    fun(ctx: GxContext): { path: string, type: string }|nil

--- Adapter for neo-tree.nvim buffers.
--- Tries the renderer API first, then the source manager as a fallback.
---@return GxAdapter
local function adapter_neo_tree()
	return {
		name = "neo_tree",
		detect = function(ctx)
			return ctx.filetype == "neo-tree"
		end,
		get = function(ctx)
			local ok, renderer = pcall(require, "neo-tree.ui.renderer")
			if ok then
				local ok2, node = pcall(renderer.get_node)
				if ok2 and node and node.path then
					return { path = node.path, type = node.type == "directory" and "dir" or "file" }
				end
			end
			local ok3, mgr = pcall(require, "neo-tree.sources.manager")
			if ok3 and mgr.get_state then
				for _, src in ipairs({ "filesystem", "buffers", "git_status" }) do
					local st = mgr.get_state(src)
					if st and st.bufnr == ctx.bufnr and st.tree then
						local n = st.tree:get_node()
						if n and n.path then
							return { path = n.path, type = n.type == "directory" and "dir" or "file" }
						end
					end
				end
			end
		end,
	}
end

--- Adapter for nvim-tree.lua buffers.
---@return GxAdapter
local function adapter_nvim_tree()
	return {
		name = "nvim_tree",
		detect = function(ctx)
			return ctx.filetype == "NvimTree"
		end,
		get = function()
			local ok, api = pcall(require, "nvim-tree.api")
			if not ok then
				return
			end
			local ok2, node = pcall(api.tree.get_node_under_cursor)
			if ok2 and node and node.absolute_path then
				return { path = node.absolute_path, type = node.type == "directory" and "dir" or "file" }
			end
		end,
	}
end

--- Adapter for oil.nvim directory buffers.
---@return GxAdapter
local function adapter_oil()
	return {
		name = "oil",
		detect = function(ctx)
			return ctx.filetype == "oil"
		end,
		get = function()
			local ok, oil = pcall(require, "oil")
			if not ok then
				return
			end
			local ok_d, dir = pcall(oil.get_current_dir)
			local ok_e, entry = pcall(oil.get_cursor_entry)
			if ok_d and type(dir) == "string" and ok_e and entry and entry.name then
				return { path = normalize(dir .. entry.name), type = entry.type == "directory" and "dir" or "file" }
			end
		end,
	}
end

--- Adapter for mini.files buffers. Supports both the newer get_fs_entry
--- API and the older get_cursor_entry API.
---@return GxAdapter
local function adapter_mini_files()
	return {
		name = "mini_files",
		detect = function(ctx)
			return ctx.filetype == "minifiles" or ctx.filetype == "MiniFiles"
		end,
		get = function()
			local ok, mf = pcall(require, "mini.files")
			if not ok then
				return
			end
			if mf.get_fs_entry then
				local ok2, e = pcall(mf.get_fs_entry)
				if ok2 and e and e.path then
					return {
						path = normalize(e.path),
						type = e.fs_type == "directory" and "dir" or (e.fs_type or "file"),
					}
				end
			end
			if mf.get_cursor_entry then
				local ok2, e = pcall(mf.get_cursor_entry)
				if ok2 and e and e.path then
					return {
						path = normalize(e.path),
						type = e.fs_type == "directory" and "dir" or (e.fs_type or "file"),
					}
				end
			end
		end,
	}
end

--- Adapter for the built-in netrw file browser.
--- Parses the entry name from the current line, stripping netrw's
--- leading line-number prefix.
---@return GxAdapter
local function adapter_netrw()
	return {
		name = "netrw",
		detect = function(ctx)
			return ctx.filetype == "netrw"
		end,
		get = function(ctx)
			local line = (ctx.line or ""):gsub("^%s*[%d%.]+%s*", "")
			local name = line:match("^(%S+)")
			if name and name ~= "" and not is_icon(name) then
				local dir = vim.b[ctx.bufnr].netrw_curdir or uv.cwd() or ""
				return { path = normalize(dir .. "/" .. name), type = "unknown" }
			end
		end,
	}
end

--- Map of adapter name → constructor function used during initialisation.
---@type table<string, fun(): GxAdapter>
local builders = {
	neo_tree = adapter_neo_tree,
	nvim_tree = adapter_nvim_tree,
	oil = adapter_oil,
	mini_files = adapter_mini_files,
	netrw = adapter_netrw,
}

-- ─── adapter registry ─────────────────────────────────────────────────────────

--- Register a custom file-manager adapter.
--- The definition must have: name (string), detect (function), get (function).
---@param def GxAdapter
function M.register_adapter(def)
	if not def or not def.name or not def.detect or not def.get then
		return
	end
	adapters[#adapters + 1] = def
end

--- Build and register all enabled built-in adapters. Runs once per setup().
local function ensure_adapters()
	if adapters_initialized then
		return
	end
	for k, b in pairs(builders) do
		if cfg.adapters[k] then
			local ok, d = pcall(b)
			if ok and d then
				M.register_adapter(d)
			end
		end
	end
	for _, d in ipairs(cfg.extra_adapters or {}) do
		M.register_adapter(d)
	end
	adapters_initialized = true
end

-- ─── context ──────────────────────────────────────────────────────────────────

---@class GxContext
---@field bufnr    integer
---@field winid    integer
---@field filetype string
---@field cursor   { lnum: integer, col0: integer, col1: integer }  col0 = 0-based, col1 = 1-based
---@field line     string   Full text of the line under the cursor
---@field cwd      string   Current working directory

--- Build a context snapshot for the current cursor position.
---@return GxContext
local function build_ctx()
	local cur = vim.api.nvim_win_get_cursor(0)
	return {
		bufnr = vim.api.nvim_get_current_buf(),
		winid = vim.api.nvim_get_current_win(),
		filetype = vim.bo.filetype,
		cursor = { lnum = cur[1], col0 = cur[2], col1 = cur[2] + 1 },
		line = vim.api.nvim_get_current_line(),
		cwd = uv.cwd(),
	}
end

--- Return the first registered adapter whose detect() returns true.
---@param ctx GxContext
---@return GxAdapter|nil
local function first_adapter(ctx)
	ensure_adapters()
	for _, ad in ipairs(adapters) do
		local ok, res = pcall(ad.detect, ctx)
		if ok and res then
			return ad
		end
	end
end

-- ─── open dispatcher ─────────────────────────────────────────────────────────

--- Invoke the OS system opener (xdg-open / open / start) for a target.
--- Local files require force_system_open_local = true.
--- Headless environments without a display are skipped for local files.
---@param target string
---@param kind   "url"|"file"
---@return boolean  true on success
local function sys_open(target, kind)
	local opener = detect_opener()
	if kind ~= "url" and not cfg.force_system_open_local then
		return false
	end
	if kind ~= "url" and env_headless() then
		return false
	end
	local cmd = opener == "start" and { "cmd", "/c", "start", "", target } or { opener, target }
	local ok, jid = pcall(vim.fn.jobstart, cmd, { detach = true })
	return ok and jid > 0
end

--- Jump the cursor to a 1-based line / column in the current window.
---@param line integer|nil
---@param col  integer|nil  1-based; converted to 0-based internally
local function jump(line, col)
	if line then
		pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(0, (col or 1) - 1) })
	end
end

--- Resolve and open a single target string (URL, local path, or bare domain).
--- Path resolution order:
---   1. Absolute path as-is
---   2. Relative to cwd
---   3. Relative to current buffer directory
---   4. Percent-decoded (%20 → space)
---   5. Bare domain/repo → prepend "https://"
---@param target string
---@param meta   table|nil  Optional metadata from the candidate (line, col)
---@return boolean  true when the target was successfully opened
local function open_target(target, meta)
	if not target or target == "" then
		return false
	end

	if is_url(target) then
		if not sys_open(target, "url") then
			return false
		end
		return true
	end

	local file, line, col = split_file_loc(target)
	file = normalize(expand_home(file))

	-- Resolve relative to cwd.
	if not exists(file) then
		local cwd = uv.cwd() or ""
		local alt = normalize(cwd .. "/" .. file)
		if exists(alt) then
			file = alt
		end
	end
	-- Resolve relative to the current buffer's directory.
	if not exists(file) then
		local bufname = vim.api.nvim_buf_get_name(0)
		if bufname ~= "" then
			local alt = normalize(vim.fn.fnamemodify(bufname, ":h") .. "/" .. file)
			if exists(alt) then
				file = alt
			end
		end
	end
	-- Percent-decode spaces (%20).
	if not exists(file) then
		local decoded = file:gsub("%%20", " ")
		if decoded ~= file and exists(decoded) then
			file = decoded
		end
	end

	if not exists(file) then
		-- Last resort: treat as a bare domain/repo and open as HTTPS.
		if is_domain_repo(file) then
			sys_open("https://" .. file, "url")
			return true
		end
		return false
	end

	if is_dir(file) then
		if cfg.dir_open_strategy == "system" then
			if not sys_open(file, "file") then
				vim.cmd.edit(vim.fn.fnameescape(file))
			end
		else
			vim.cmd.edit(vim.fn.fnameescape(file))
		end
		return true
	end

	if cfg.force_system_open_local then
		if not sys_open(file, "file") then
			vim.cmd.edit(vim.fn.fnameescape(file))
			jump(line, col)
		end
	else
		vim.cmd.edit(vim.fn.fnameescape(file))
		jump(line or (meta and meta.line), col or (meta and meta.col))
	end
	return true
end

-- ─── candidate collection ────────────────────────────────────────────────────

---@class GxCandidate
---@field text string  Token text
---@field meta table   Source metadata (lnum, start_col, end_col, origin)

--- Collect all unique candidate tokens ordered by proximity to the cursor.
--- Priority: token under cursor → other tokens on the same line →
---           tokens on nearby lines (alternating up/down, bounded by search_max_lines).
---@param ctx GxContext
---@return GxCandidate[]
local function collect_candidates(ctx)
	local buf = ctx.bufnr
	local pattern = cfg.pattern
	local lnum = ctx.cursor.lnum
	local col1 = ctx.cursor.col1
	local seen, order = {}, {}

	---Add a candidate if it hasn't been seen yet.
	---@param text string
	---@param meta table
	local function add(text, meta)
		if text and text ~= "" and not is_icon(text) and not seen[text] then
			seen[text] = true
			order[#order + 1] = { text = text, meta = meta }
		end
	end

	-- 1. Token directly under the cursor (highest priority).
	local line = ctx.line
	local under = token_at(line, col1, pattern)
	if under then
		add(under.text, { lnum = lnum, start_col = under.s, end_col = under.e, origin = "under" })
	end

	-- 2. Remaining tokens on the cursor line.
	for _, t in ipairs(tokens_in(line, pattern)) do
		if not (under and t.text == under.text) then
			add(t.text, { lnum = lnum, start_col = t.s, end_col = t.e, origin = "same_line" })
		end
	end

	-- 3. Expand outward, alternating up and down.
	-- Pre-fetch the entire scan window in two API calls instead of one per line.
	local total = vim.api.nvim_buf_line_count(buf)
	local max_l = cfg.search_max_lines
	local lo = math.max(0, lnum - 1 - max_l) -- 0-based inclusive
	local hi = math.min(total, lnum - 1 + max_l) -- 0-based inclusive
	local fetched = (cfg.search_backward_if_none or cfg.search_forward_if_none)
			and vim.api.nvim_buf_get_lines(buf, lo, hi + 1, false)
		or {}
	-- fetched[l - lo] = content of 1-based line l

	local up_c, dn_c, r = 0, 0, 1
	while (up_c < max_l or dn_c < max_l) and #order < cfg.max_sequential_candidates do
		local did = false
		if cfg.search_backward_if_none and lnum - r >= 1 and up_c < max_l then
			local l = lnum - r
			for _, t in ipairs(tokens_in(fetched[l - lo] or "", pattern)) do
				add(t.text, { lnum = l, start_col = t.s, end_col = t.e, origin = "up" })
			end
			up_c = up_c + 1
			did = true
		end
		if cfg.search_forward_if_none and lnum + r <= total and dn_c < max_l then
			local l = lnum + r
			for _, t in ipairs(tokens_in(fetched[l - lo] or "", pattern)) do
				add(t.text, { lnum = l, start_col = t.s, end_col = t.e, origin = "down" })
			end
			dn_c = dn_c + 1
			did = true
		end
		if not did then
			break
		end
		r = r + 1
	end
	return order
end

-- ─── resolution ──────────────────────────────────────────────────────────────

--- Build an ordered list of candidates from either an explicit argument,
--- an adapter result, or the line-scan heuristic.
---@param args string|nil  Explicit target passed from the user command (empty = auto)
---@return GxCandidate[]
---@return GxContext
local function resolve(args)
	local ctx = build_ctx()
	if args and args ~= "" then
		return { { text = args, meta = { source = "argument" } } }, ctx
	end
	local adapter = first_adapter(ctx)
	local list = {}
	if adapter then
		local ok, data = pcall(adapter.get, ctx)
		if ok and data and data.path and data.path ~= "" and not is_icon(data.path) then
			list[#list + 1] = { text = data.path, meta = { source = "adapter", adapter = adapter, type = data.type } }
		end
	end
	for _, c in ipairs(collect_candidates(ctx)) do
		list[#list + 1] = { text = c.text, meta = c.meta }
	end
	return list, ctx
end

-- ─── execution ───────────────────────────────────────────────────────────────

--- Try each candidate in order until one opens successfully.
--- Highlights and repositions the cursor on the matched token.
---@param candidates GxCandidate[]
local function execute(candidates)
	if #candidates == 0 then
		return
	end
	for _, c in ipairs(candidates) do
		if open_target(c.text, c.meta) then
			if c.meta and c.meta.lnum and c.meta.start_col and c.meta.end_col then
				highlight_temp(0, c.meta.lnum - 1, c.meta.start_col - 1, c.meta.end_col)
				pcall(vim.api.nvim_win_set_cursor, 0, { c.meta.lnum, c.meta.start_col - 1 })
			end
			return
		end
	end
end

-- ─── user commands ────────────────────────────────────────────────────────────

local cmds_created = false

--- Create the GxOpen and GxOpenDiag user commands (idempotent).
local function create_commands()
	if cmds_created then
		return
	end
	cmds_created = true

	-- :GxOpen [target]  — open the target under the cursor (or the given argument).
	vim.api.nvim_create_user_command("GxOpen", function(opts)
		execute((resolve(opts.args)))
	end, { nargs = "?", complete = "file", desc = "GxOpen: open URL / file / dir under cursor" })

	-- :GxOpenDiag  — print context, detected adapter, and first 10 candidates.
	vim.api.nvim_create_user_command("GxOpenDiag", function()
		local ctx = build_ctx()
		local adapter = first_adapter(ctx)
		local list = resolve("")
		local lines = {
			"=== GxOpenDiag ===",
			"filetype : " .. ctx.filetype,
			"cursor   : lnum=" .. ctx.cursor.lnum .. " col=" .. ctx.cursor.col0,
			"line     : " .. ctx.line,
			"adapter  : " .. (adapter and adapter.name or "none"),
			"candidates: " .. tostring(#list),
		}
		for i, c in ipairs(list) do
			if i > 10 then
				lines[#lines + 1] = "..."
				break
			end
			lines[#lines + 1] = i .. ": " .. c.text
		end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
	end, { desc = "GxOpen diagnostics" })
end

-- ─── public api ───────────────────────────────────────────────────────────────

--- Initialise the gx module with optional config overrides.
--- Resets the adapter list and re-registers all enabled built-in adapters.
---@param opts GxConfig|nil
function M.setup(opts)
	if opts then
		local config = require("lvim-utils.config")
		config.gx = vim.tbl_deep_extend("force", config.gx, opts)
		cfg = config.gx
	end
	adapters = {}
	adapters_initialized = false
	ensure_adapters()
	create_commands()
end

--- Bind gx → :GxOpen in normal mode.
function M.map_default()
	vim.keymap.set("n", "gx", "<cmd>GxOpen<CR>", { silent = true, desc = "GxOpen" })
end

--- Programmatically trigger GxOpen on the current cursor position.
function M.open_current()
	execute((resolve("")))
end

return M
