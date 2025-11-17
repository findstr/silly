--- @meta silly.crypto.utils

---@class silly.crypto.utils
local M = {}

---XOR two strings byte-by-byte
---@param a string
---@param b string
---@return string
function M.xor(a, b) end

---Generate a random key
---@param length integer key length in bytes
---@return string
function M.randomkey(length) end

return M
