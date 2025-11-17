--- @meta silly.encoding.base64

---@class silly.encoding.base64
local M = {}

---Encode data to base64
---@param data string
---@return string
function M.encode(data) end

---Decode base64 data
---@param data string
---@return string
function M.decode(data) end

---Encode data to URL-safe base64
---@param data string
---@return string
function M.urlsafe_encode(data) end

---Decode URL-safe base64 data
---@param data string
---@return string
function M.urlsafe_decode(data) end

return M
