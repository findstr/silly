--- @meta silly.tls.tls

---@class silly.tls.tls
local M = {}

---Release TLS resources after a final attempt to send pending writes and close_notify
---@return silly.errno? error
function M:close() end

---Only read buffered plaintext; every successful read ends the read-wait exemption
---@param size integer|string byte count from 0 to 2^31-1, or a single-byte delimiter
---@return string? data nil when insufficient data is buffered; zero bytes returns an empty string
function M:read(size) end

---Accept data for sending, buffering pending TLS writes; transport errors arrive through socket close
---Failure may follow an already queued prefix and does not set the Lua read-side error
---@param data string|string[]
---@return boolean success
---@return silly.errno? error
function M:write(data) end

---Perform TLS handshake; success ends the read-wait exemption; socket close reports transport errors
---The second result is the negotiated ALPN protocol on success, an errno on failure, and nil while pending.
---@return integer status 1 on success, 0 on failure, -1 while pending
---@return string|silly.errno|nil result
function M:handshake() end

---Push data to TLS buffer
---@param data lightuserdata
---@param size integer nonnegative input length; ownership transfers after argument validation
---@return silly.errno? error SSL read termination, including EOF; transport failures arrive via socket close
function M:push(data, size) end

---Set the plaintext receive limit; a waiting read or TLS progress may bypass it
---@param size integer? byte count from 0 to 2^31-1; nil removes the limit
---@return boolean enabled effective receive state
function M:limit(size) end

---Temporarily bypass the receive limit, unless native TLS state is already terminal
---@return silly.errno? error nil when a wait may be registered
function M:readwait() end

---End the pending-read exemption without consuming buffered plaintext
function M:readcancel() end

---Get buffer size
---@return integer
function M:size() end

---Get queued TLS plaintext and transport output size
---@return integer
function M:sendsize() end

---Open a new TLS connection; expected OpenSSL setup failures return nil and an errno
---@param CTX silly.tls.CTX TLS context retained until close
---@param fd integer borrowed socket ID
---@param hostname string?
---@param alpnprotos string? wire-format ALPN protocol list
---@return silly.tls.tls? connection
---@return silly.errno? error
function M.open(CTX, fd, hostname, alpnprotos) end

return M
