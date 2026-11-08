--- @meta silly.tls.CTX

---TLS context managed by Lua garbage collection.
---@class silly.tls.CTX
local CTX = {}

---@class silly.tls.CTX.module
local M = {}

---Create client TLS context without certificate verification
---@return silly.tls.CTX? context
---@return string? error
function M.client() end

---Create server TLS context
---@param certs {cert:string, key:string}[] nonempty list of PEM certificates and private keys
---@param ciphers string? OpenSSL cipher list
---@param alpnprotos string? wire-format ALPN protocol list
---@return silly.tls.CTX? context
---@return string? error
function M.server(certs, ciphers, alpnprotos) end

return M
