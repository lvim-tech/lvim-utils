-- lua/lvim-utils/config/fuzzy.lua
-- Live config for the shared fuzzy engine (lvim-utils.fuzzy) — applies to EVERY consumer (the picker /
-- navigator and the native cmdline completion). setup() merges user opts in place; readers do
-- `require("lvim-utils.config").fuzzy`.
--
---@module "lvim-utils.config.fuzzy"

return {
    -- Result ORDERING after the fuzzy match — HIGHLY configurable. `sort` is ANY of:
    --   * a STRING preset (one criterion), or
    --   * a LIST of criteria applied in PRIORITY order (the first decides; the rest break ties), or
    --   * a custom `function(a, b) -> boolean` comparator (each item: `.text`, `.is_dir`, `.ext`,
    --     `.rank` = 1 for the best fuzzy match).
    -- Built-in criteria:
    --   "score"       — best fuzzy-match score first (the engine's ranking)
    --   "dirs_first"  — directories (text ending "/") before files
    --   "files_first" — files before directories
    --   "ext"         — group by file extension (A→Z)
    --   "length"      — shorter text first
    --   "alpha"       — text A→Z
    -- The fuzzy rank is ALWAYS the final tiebreak, so the order is deterministic. Examples:
    --   "score"  ·  { "dirs_first", "score" }  ·  { "score", "dirs_first" }  ·  { "ext", "alpha" }
    sort = "score",
}
