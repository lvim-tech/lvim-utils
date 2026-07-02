-- lvim-utils.config.gx: the live defaults for the gx "open under cursor" module — match highlighting, the
-- system-opener behaviour, bare-domain / directory handling, the proximity scan bounds, the token pattern,
-- and which file-manager adapters are enabled. `setup()` merges the user's `gx = {…}` into this table in
-- place; readers `require("lvim-utils.config").gx`. Field docs live on `GxConfig` in lvim-utils/gx/init.lua.
--
---@module "lvim-utils.config.gx"

---@type GxConfig
return {
    highlight_match = true,
    highlight_duration_ms = 300,
    system_open_cmd = nil, -- nil = auto-detect (xdg-open / open / start)
    force_system_open_local = true, -- use system opener for local files too
    allow_bare_domains = true, -- treat "domain.tld/path" as HTTPS URLs
    icon_guard = true, -- skip tokens that look like Nerd Font glyphs
    dir_open_strategy = "system", -- "system" | "edit"
    search_forward_if_none = true,
    search_backward_if_none = true,
    search_max_lines = 60,
    max_sequential_candidates = 200,
    pattern = "[%w%._~/#%-%+%%%?=&@:%d]+",

    adapters = {
        neo_tree = true,
        nvim_tree = true,
        oil = true,
        mini_files = true,
        netrw = true,
    },

    extra_adapters = {},
}
