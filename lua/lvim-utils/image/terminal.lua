-- lvim-utils.image.terminal: the terminal I/O + capability layer for the image module. It (1) writes raw
-- graphics escape sequences to the attached UI via `nvim_ui_send` (wrapped in tmux DCS passthrough when
-- inside tmux), (2) detects WHICH graphics protocol the terminal supports (kitty / iTerm2 / sixel /
-- ueberzug) from env + async terminal queries, and (3) measures the CELL pixel size so images can be sized
-- to the grid. Everything protocol-specific lives in `image/protocols/*`; this file is the shared substrate.
--
-- Writing: `nvim_ui_send(bytes)` reaches the real terminal even though the nvim process' own stdout is an
-- RPC pipe (so `io.stdout` / `/dev/tty` are unreliable here). Detection is ASYNC — queries are emitted on
-- `setup()` and their replies land on `TermResponse`; callers read the best current estimate.
--
---@module "lvim-utils.image.terminal"

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

---@class lvim-utils.image.terminal.Caps
---@field kitty    boolean  kitty graphics protocol (kitty, ghostty)
---@field iterm2   boolean  iTerm2 inline-image protocol (iTerm2, WezTerm, Konsole)
---@field sixel    boolean  sixel (foot, xterm +sixel, mlterm, contour, mintty, WezTerm, Konsole)
---@field ueberzug boolean  ueberzugpp overlay available (X11/Wayland + the binary) — universal fallback
---@field placeholders boolean  kitty UNICODE PLACEHOLDER support (kitty/ghostty yes, WezTerm no)

---@class lvim-utils.image.terminal.State
---@field term string|nil            resolved terminal name (kitty/ghostty/wezterm/iterm2/foot/…)
---@field in_tmux boolean
---@field in_zellij boolean
---@field is_ssh boolean
---@field cell { w: integer, h: integer }  cell size in pixels (best current estimate)
---@field caps lvim-utils.image.terminal.Caps
---@field transform (fun(s: string): string)|nil  tmux passthrough wrapper, if any
---@field queried boolean
local state = {
    term = nil,
    in_tmux = false,
    in_zellij = false,
    is_ssh = false,
    cell = { w = 9, h = 18 }, -- conservative fallback until a query/ioctl refines it
    caps = { kitty = false, iterm2 = false, sixel = false, ueberzug = false, placeholders = false },
    transform = nil,
    queried = false,
}

-- ── raw write to the terminal ───────────────────────────────────────────────

-- Graphics escapes MUST go to the terminal DEVICE, not to nvim's stdout / `nvim_ui_send` (those do not reach
-- the emulator from the TUI). We resolve the controlling tty (e.g. /dev/pts/3) once and write straight to it —
-- exactly what `kitten icat` does — so kitty composites the image over nvim's own rendering. Under tmux the
-- tty is the pane pty and the passthrough wrapper carries the sequence on to the outer terminal.
---@type string|false|nil
local tty_path = nil
---@type file*|false|nil
local tty_fh = nil

--- The controlling terminal device path (e.g. /dev/pts/3), resolved once via `tty(1)`. false when headless.
---@return string|nil
local function device_path()
    if tty_path ~= nil then
        return tty_path or nil
    end
    local path
    local ok, h = pcall(io.popen, "tty 2>/dev/null")
    if ok and h then
        path = h:read("*l")
        h:close()
    end
    tty_path = (path and path:match("^/dev/") and path) or false
    return tty_path or nil
end

--- The cached write handle to the terminal device, or nil when it cannot be resolved (e.g. headless).
---@return file*|nil
local function tty()
    if tty_fh ~= nil then
        return tty_fh or nil
    end
    local path = device_path()
    tty_fh = (path and io.open(path, "wb")) or false
    return tty_fh or nil
end

--- Write raw bytes to the terminal device (tmux-wrapped inside tmux). The ONE sink every protocol encoder
--- writes through. Falls back to `nvim_ui_send` only when no tty device is resolvable.
---@param data string
function M.write(data)
    if state.transform then
        data = state.transform(data)
    end
    local fh = tty()
    if fh then
        fh:write(data)
        fh:flush()
    else
        pcall(api.nvim_ui_send, data)
    end
end

--- Emit a terminal QUERY (a control sequence whose reply arrives on `TermResponse`).
---@param seq string
local function query(seq)
    M.write(seq)
end

-- ── cell-pixel size (ioctl TIOCGWINSZ, refined by CSI 14 t) ─────────────────

local ffi_ok, ffi = pcall(require, "ffi")
local ioctl_ready = false
local function ensure_ioctl()
    if ioctl_ready or not ffi_ok then
        return ffi_ok
    end
    local ok = pcall(
        ffi.cdef,
        [[
        struct lvim_winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
        int ioctl(int fd, unsigned long request, ...);
        int open(const char *path, int flags);
        int close(int fd);
    ]]
    )
    ioctl_ready = ok
    return ok
end

--- Read the cell pixel size via `ioctl(TIOCGWINSZ)` on the terminal DEVICE (the pty reports its own pixel
--- geometry; the nvim process' fd 1 is an RPC pipe and reports nothing). Returns nil when the ioctl is
--- unavailable, fails, or the terminal reports no pixel geometry (then the CSI-14t query / fallback is used).
---@return integer? cell_w, integer? cell_h
local function ioctl_cell()
    if not ensure_ioctl() then
        return nil
    end
    local path = device_path()
    if not path then
        return nil
    end
    -- TIOCGWINSZ: 0x5413 on Linux; 0x40087468 on macOS/BSD. O_RDWR|O_NOCTTY = 2|0x100 (Linux).
    local os = (jit and jit.os) or ""
    local TIOCGWINSZ = (os == "OSX" or os == "BSD") and 0x40087468 or 0x5413
    local ok, cw, ch = pcall(function()
        local fd = ffi.C.open(path, 0x102)
        if fd < 0 then
            return nil, nil
        end
        local ws = ffi.new("struct lvim_winsize")
        local rc = ffi.C.ioctl(fd, TIOCGWINSZ, ws)
        ffi.C.close(fd)
        if rc ~= 0 or ws.ws_col == 0 or ws.ws_row == 0 or ws.ws_xpixel == 0 or ws.ws_ypixel == 0 then
            return nil, nil
        end
        return math.floor(ws.ws_xpixel / ws.ws_col), math.floor(ws.ws_ypixel / ws.ws_row)
    end)
    if ok and cw and ch and cw > 0 and ch > 0 then
        return cw, ch
    end
    return nil
end

--- Current best estimate of the cell pixel size `{ w, h }`. Recomputed from ioctl on demand; refined
--- asynchronously by the `CSI 14 t` reply (see `setup`). Never returns zero.
---@return { w: integer, h: integer }
function M.cell_size()
    local cw, ch = ioctl_cell()
    if cw and ch then
        state.cell = { w = cw, h = ch }
    end
    return state.cell
end

-- ── detection ───────────────────────────────────────────────────────────────

--- Resolve the terminal name from the environment (a synchronous first guess; `CSI > q` refines it).
---@return string|nil
local function term_from_env()
    local env = vim.env
    if env.KITTY_WINDOW_ID or (env.TERM or ""):find("kitty", 1, true) then
        return "kitty"
    end
    if env.GHOSTTY_RESOURCES_DIR or env.GHOSTTY_BIN_DIR or (env.TERM_PROGRAM or "") == "ghostty" then
        return "ghostty"
    end
    if env.WEZTERM_EXECUTABLE or env.WEZTERM_PANE or (env.TERM_PROGRAM or "") == "WezTerm" then
        return "wezterm"
    end
    if (env.TERM_PROGRAM or "") == "iTerm.app" or env.ITERM_SESSION_ID then
        return "iterm2"
    end
    if env.KONSOLE_VERSION then
        return "konsole"
    end
    if (env.TERM or ""):find("foot", 1, true) then
        return "foot"
    end
    if (env.TERM or ""):find("contour", 1, true) then
        return "contour"
    end
    if (env.TERM or ""):find("mlterm", 1, true) then
        return "mlterm"
    end
    return nil
end

--- Map the resolved terminal name to protocol capabilities. Refined by async queries: `CSI 14 t` proves the
--- terminal answers pixel geometry, and DA1 (`CSI c`) with a `;4` attribute proves sixel.
local function recompute_caps()
    local t = state.term or ""
    local caps = state.caps
    -- kitty graphics protocol (+ unicode placeholders on kitty/ghostty)
    caps.kitty = t == "kitty" or t == "ghostty" or t == "wezterm" or vim.env.KITTY_WINDOW_ID ~= nil
    caps.placeholders = t == "kitty" or t == "ghostty" -- wezterm supports the protocol but NOT placeholders
    -- iTerm2 inline images
    caps.iterm2 = t == "iterm2" or t == "wezterm" or t == "konsole"
    -- sixel (known terminals; DA1 may add more at runtime)
    caps.sixel = t == "foot" or t == "contour" or t == "mlterm" or t == "wezterm" or t == "konsole"
    -- ueberzugpp overlay: available when the binary exists and we are on X11/Wayland (not headless/tty).
    caps.ueberzug = (vim.fn.executable("ueberzugpp") == 1 or vim.fn.executable("ueberzug") == 1)
        and (vim.env.DISPLAY ~= nil or vim.env.WAYLAND_DISPLAY ~= nil)
end

--- Handle a `TermResponse` payload: XTVERSION (terminal name), CSI-14t (text-area pixel size → cell), DA1
--- (sixel attribute). Unknown replies are ignored.
---@param data string
local function on_term_response(data)
    if type(data) ~= "string" then
        return
    end
    -- XTVERSION: DCS > | <name> <version> ST  → e.g. ">|kitty 0.32.2"
    local name = data:match("[>P]|(%a+)")
    if name then
        state.term = name:lower()
        recompute_caps()
    end
    -- CSI 4 ; height ; width t  → text-area size in pixels; divide by the grid to get the cell size.
    local h, w = data:match("\27%[4;(%d+);(%d+)t")
    if h and w then
        local cols, lines = vim.o.columns, vim.o.lines
        local cw, ch = math.floor(tonumber(w) / math.max(1, cols)), math.floor(tonumber(h) / math.max(1, lines))
        if cw > 0 and ch > 0 then
            state.cell = { w = cw, h = ch }
        end
    end
    -- DA1: CSI ? <attrs> c  — a "4" attribute means sixel graphics.
    local attrs = data:match("\27%[%?([%d;]+)c")
    if attrs and (";" .. attrs .. ";"):find(";4;", 1, true) then
        state.caps.sixel = true
    end
end

--- Set up terminal I/O + detection. Enables tmux passthrough, installs the `TermResponse` listener, and
--- emits the capability/size queries. Idempotent.
function M.setup()
    if state.queried then
        return
    end
    state.queried = true
    state.in_tmux = vim.env.TMUX ~= nil
    state.in_zellij = vim.env.ZELLIJ ~= nil
    state.is_ssh = vim.env.SSH_CLIENT ~= nil or vim.env.SSH_CONNECTION ~= nil
    state.term = term_from_env()

    if state.in_tmux then
        -- Wrap every sequence as `DCS tmux; <ESC doubled> ST` and allow it through the multiplexer. Set the
        -- transform NOW (so the deferred queries are wrapped); the `allow-passthrough` toggle is applied async
        -- below — it costs a process spawn and is only needed by the time an image actually renders.
        state.transform = function(s)
            return "\27Ptmux;" .. s:gsub("\27", "\27\27") .. "\27\\"
        end
    end

    recompute_caps()

    api.nvim_create_autocmd("TermResponse", {
        group = api.nvim_create_augroup("LvimImageTerm", { clear = true }),
        callback = function(ev)
            on_term_response(type(ev.data) == "table" and (ev.data.sequence or ev.data) or ev.data)
        end,
    })

    -- DEFER the blocking terminal I/O off the startup path: enabling tmux passthrough shells out, and priming
    -- the cell size + firing the capability queries resolve the controlling tty (a process spawn) and write to
    -- it. None is needed until the first image renders, so a `vim.schedule` keeps `setup()` (and the plugin's
    -- measured load time) cheap — env-based caps are already set above, and the queries only refine them.
    vim.schedule(function()
        if state.in_tmux then
            pcall(function()
                vim.system({ "tmux", "set", "-p", "allow-passthrough", "all" }) -- async: fire and forget
            end)
        end
        M.cell_size() -- prime from ioctl (refined by the CSI-14t reply on TermResponse)
        -- Fire the queries; replies arrive on TermResponse. XTVERSION (name), text-area pixels, DA1 (sixel).
        query("\27[>q")
        query("\27[14t")
        query("\27[c")
    end)
end

--- The detected capabilities (best current estimate).
---@return lvim-utils.image.terminal.Caps
function M.capabilities()
    return state.caps
end

--- The resolved terminal name, tmux/zellij/ssh flags, and cell size — for `:checkhealth` and debugging.
---@return lvim-utils.image.terminal.State
function M.info()
    return state
end

--- Whether ANY image display path is available on this terminal.
---@return boolean
function M.supported()
    local c = state.caps
    return c.kitty or c.iterm2 or c.sixel or c.ueberzug
end

--- Pick the best protocol id for the current terminal, in order kitty > iTerm2 > sixel > ueberzug.
--- `force` (from config) returns "kitty" even when nothing is detected, for terminals we cannot probe.
---@param force? boolean
---@return "kitty"|"iterm2"|"sixel"|"ueberzug"|nil
function M.pick_protocol(force)
    local c = state.caps
    if c.kitty then
        return "kitty"
    elseif c.iterm2 then
        return "iterm2"
    elseif c.sixel then
        return "sixel"
    elseif c.ueberzug then
        return "ueberzug"
    end
    return force and "kitty" or nil
end

return M
