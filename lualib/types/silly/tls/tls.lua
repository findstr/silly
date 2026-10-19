--- @meta silly.tls.tls

---@class silly.tls.tls
local M = {}

---Release TLS resources, optionally attempting writes and close_notify
---@param notify boolean?
---@return silly.errno? error
function M:close(notify) end

---Read data from TLS connection
---@param size integer|string byte count up to 2^31-1, or a delimiter
---@return string? data
---@return silly.errno? error returned when the read cannot be satisfied
function M:read(size) end

---Write data to TLS connection
---@param data string|string[]
---@return boolean success
---@return silly.errno? error
function M:write(data) end

---Perform TLS handshake
---@return integer status 1 on success, 0 on failure, -1 while pending
---@return string|silly.errno|nil result ALPN protocol or error
function M:handshake() end

---Push data to TLS buffer
---@param data lightuserdata
---@param size integer nonnegative input length; ownership transfers after argument validation
---@return integer size buffered plaintext bytes
---@return silly.errno? error fatal TLS I/O error; normal EOF is returned by read
function M:push(data, size) end

---Request transport receiving; TLS progress may keep it enabled
---@param enable boolean
---@return boolean enabled effective receive state
function M:readenable(enable) end

---Get the TLS read error without consuming buffered plaintext
---@return silly.errno? error
function M:error() end

---Get buffer size
---@return integer
function M:size() end

---Get queued TLS plaintext and transport output size
---@return integer
function M:sendsize() end

---Open a new TLS connection
---@param CTX silly.tls.CTX TLS context
---@param fd integer file descriptor
---@param hostname string
---@param alpnprotos string
---@return silly.tls.tls
function M.open(CTX, fd, hostname, alpnprotos) end

return M
