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
