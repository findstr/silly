---@meta silly.net.addr

---Address helpers backed by C module `silly.net.addr`.
---@class silly.net.addr
local M = {}

---@param addr string
---@return string? host, string? port
function M.parse(addr) end

---@param host string?
---@param port string
---@return string
function M.join(host, port) end

---@param host string
---@return 4|6|0 type  -- 4 for IPv4, 6 for IPv6, 0 for hostname
function M.iptype(host) end

---@param host string
---@return boolean
function M.isv4(host) end

---@param host string
---@return boolean
function M.isv6(host) end

---@param host string
---@return boolean
function M.ishost(host) end

return M
