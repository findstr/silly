--- @meta silly.crypto.hmac

---@class silly.crypto.hmac
local M = {}

---Compute HMAC digest
---@param key string secret key
---@param data string data to authenticate
---@param algorithm string hash algorithm (e.g., "sha256", "sha1")
---@return string
function M.digest(key, data, algorithm) end

return M
