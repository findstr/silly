--- @meta silly.env

---@class silly.env
local M = {}

---Load configuration from file
---@param file string
---@return string? error
function M.load(file) end

---Get configuration value
---@param key string
---@return any
function M.get(key) end

---Set configuration value
---@param key string
---@param value any
function M.set(key, value) end

return M
