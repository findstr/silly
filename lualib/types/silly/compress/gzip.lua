--- @meta silly.compress.gzip

---@class silly.compress.gzip
local M = {}

---Compress data using gzip
---@param data string
---@return string? compressed
---@return string? error
function M.compress(data) end

---Decompress gzip data
---@param data string
---@return string? decompressed
---@return string? error
function M.decompress(data) end

return M
