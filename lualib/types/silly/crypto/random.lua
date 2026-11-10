--- @meta silly.crypto.random

---@class silly.crypto.random
local M = {}

---Generate cryptographically secure binary data; raises an error if generation fails
---@param length integer byte count from 0 to 2^31-1
---@return string
function M.bytes(length) end

---Generate ordinary random lowercase ASCII letters; not suitable for cryptographic use
---@param length integer character count from 0 to 2^31-1
---@return string
function M.text(length) end

return M
