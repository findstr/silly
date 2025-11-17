--- @meta silly.crypto.hash

---@class silly.crypto.hash.CTX
local CTX = {}

---Reset hash context
function CTX:reset() end

---Update hash with data
---@param data string
function CTX:update(data) end

---Finalize hash computation
---@return string
function CTX:final() end

---Get digest (update with data and finalize)
---@param data string data to hash
---@return string
function CTX:digest(data) end

---@class silly.crypto.hash
local M = {}

---Create a new hash context
---@param algorithm string hash algorithm (e.g., "sha256", "md5", "sha1")
---@return silly.crypto.hash.CTX
function M.new(algorithm) end

---One-shot hash function
---@param algorithm string hash algorithm
---@param data string data to hash
---@return string
function M.hash(algorithm, data) end

return M
