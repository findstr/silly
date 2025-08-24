local net = require "core.net"
local ns = require "core.netstream"
local assert = assert

---@class core.net.udp
local socket = {}

--udp client can be closed(because it use connect)
---@param cb async fun(data:string|nil, addr:string|nil)
local function udp_callback(cb)
	local e = {
		data = function(fd, ptr, size, addr)
			local data = ns.todata(ptr, size)
			cb(data, addr)
		end,
		close = function(fd, errno)
			cb(nil, errno)
		end,
	}
	return e
end



---@param addr string
---@param callback async fun(data:string|nil, addr:string|nil)
function socket.bind(addr, callback)
	return (net.udp_bind(addr, udp_callback(callback)))
end

---@param addr string
---@param callback fun(data:string|nil, addr:string|nil)
---@param bindip string|nil
function socket.connect(addr, callback, bindip)
	return (net.udp_connect(addr, udp_callback(callback), bindip))
end

socket.send = net.udp_send
socket.close = net.socket_close

return socket

