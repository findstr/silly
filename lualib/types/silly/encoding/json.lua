--- @meta silly.encoding.json

---@class silly.encoding.json
local M = {}

---JSON null sentinel value
---@type table
M.null = {}

---Encode a Lua value to JSON string
---@param obj table|string|number|boolean
---@return string? result, string? err
function M.encode(obj) end

---Decode a JSON string to Lua value
---@param str string
---@return table? result, string? err
function M.decode(str) end

return M
