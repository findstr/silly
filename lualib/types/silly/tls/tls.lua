--- @meta silly.tls.tls

---@class silly.tls.tls
local M = {}

---Close TLS connection
function M:close() end

---Read data from TLS connection
---@param size integer
---@return string? data
---@return string? error
function M:read(size) end

---Write data to TLS connection
---@param data string
---@return boolean success
---@return string? error
function M:write(data) end

---Perform TLS handshake
---@return boolean success
---@return string? error
function M:handshake() end

---Push data to TLS buffer
---@overload fun(self: silly.tls.tls, data: string): nil
---@overload fun(self: silly.tls.tls, data: lightuserdata, size: integer): nil
function M:push(data, size) end

---Get buffer size
---@return integer
function M:size() end

---Open a new TLS connection
---@param CTX silly.tls.CTX TLS context
---@param fd integer file descriptor
---@param hostname string
---@param alpnprotos string
---@return silly.tls.tls
function M.open(CTX, fd, hostname, alpnprotos) end

return M
