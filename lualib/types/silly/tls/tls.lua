--- @meta silly.tls.tls

---@class silly.tls.tls
local Tls = {}

---Close TLS connection
function Tls:close() end

---Read data from TLS connection
---@param size integer
---@return string? data
---@return string? error
function Tls:read(size) end

---Write data to TLS connection
---@param data string
---@return boolean success
---@return string? error
function Tls:write(data) end

---Perform TLS handshake
---@return boolean success
---@return string? error
function Tls:handshake() end

---Push data to TLS buffer
---@param data string
function Tls:push(data) end

---Get buffer size
---@return integer
function Tls:size() end

---@class silly.tls.tls.module
local M = {}

---Open a new TLS connection
---@param CTX silly.tls.CTX TLS context
---@param fd integer file descriptor
---@param hostname string
---@param alpnprotos string
---@return silly.tls.tls
function M.open(CTX, fd, hostname, alpnprotos) end

return M
