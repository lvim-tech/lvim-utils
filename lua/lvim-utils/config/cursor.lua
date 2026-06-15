-- lua/lvim-utils/config/cursor.lua
-- Default config for the cursor module (filetypes whose buffers hide the cursor).

return {
    -- Filetypes for which the cursor should be hidden.
    -- Populated at runtime via cursor.setup({ ft = { ... } }).
    filetypes = {},
}
