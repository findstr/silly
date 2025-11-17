--- @meta silly.tls.CTX

---@class silly.tls.CTX
local CTX = {}

---Free TLS context
function CTX:free() end

---@class silly.tls.CTX.module
local M = {}

---Create client TLS context
---@param cert_file string? client certificate file
---@param key_file string? client key file
---@param ca_file string? CA certificate file
---@return silly.tls.CTX
function M.client(cert_file, key_file, ca_file) end

---Create server TLS context
---@param cert_file string server certificate file
---@param key_file string server key file
---@param ca_file string? CA certificate file
---@return silly.tls.CTX
function M.server(cert_file, key_file, ca_file) end

return M
