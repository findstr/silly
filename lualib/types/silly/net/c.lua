---@meta silly.net.c

---@class silly.net.c
---@field ACCEPT integer
---@field CLOSE integer
---@field LISTEN integer
---@field CONNECT integer
---@field TCPDATA integer
---@field UDPDATA integer
local M = {}

---@param ptr lightuserdata
function M.free(ptr) end

---@param ip string
---@param port string
---@param backlog integer
---@return integer?, string? error
function M.tcp_listen(ip, port, backlog) end

---@param ip string
---@param port string
---@param bind_ip string
---@param bind_port string
---@return integer?, string? error
function M.tcp_connect(ip, port, bind_ip, bind_port) end

---@param ip string
---@param port string
---@return integer?, string? error
function M.udp_bind(ip, port) end

---@param ip string
---@param port string
---@param bind_ip string
---@param bind_port string
---@return integer?, string? error
function M.udp_connect(ip, port, bind_ip, bind_port) end

---@param fd integer
---@return boolean, string? error
function M.close(fd) end

---@param fd integer
---@param data string|lightuserdata|table
---@param size integer?
---@return boolean, string? error
function M.tcp_send(fd, data, size) end

---@param fd integer
---@param data string|lightuserdata|table
---@param size_or_addr integer|string?
---@param addr string?
---@return boolean, string? error
function M.udp_send(fd, data, size_or_addr, addr) end

---@param fd integer
---@param data lightuserdata
---@param size integer?
---@param addr string?
---@return boolean, string? error
function M.tcp_multicast(fd, data, size, addr) end

---@param fd integer
---@param enable boolean
function M.readenable(fd, enable) end

---@param ptr lightuserdata
---@param size integer
---@return string
function M.tostring(ptr, size) end

---@param ... any
---@return table
function M.multipack(...) end

---@param fd integer
---@return integer
function M.sendsize(fd) end

return M