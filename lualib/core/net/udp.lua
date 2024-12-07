local core = require "core"
local ns = require "core.netstream"
local assert = assert

---@class core.net.udp
local socket = {}

--udp client can be closed(because it use connect)
---@param cb async fun(data:string|nil, addr:string|nil)
local function udp_dispatch(cb)
	return function (typ, fd, message, addr)
		local data
		if typ == "udp" then
			data = ns.todata(message)
			cb(data, addr)
		elseif typ == "close" then
			cb()
		else
			assert(false, "type must be 'udp' or 'close'")
		end
	end
end

---@param addr string
---@param callback async fun(data:string|nil, addr:string|nil)
function socket.bind(addr, callback)
	return (core.udp_bind(addr, udp_dispatch(callback)))
end

---@param addr string
---@param callback fun(data:string|nil, addr:string|nil)
---@param bindip string|nil
function socket.connect(addr, callback, bindip)
	return (core.udp_connect(addr, udp_dispatch(callback), bindip))
end

socket.send = core.udp_send

return socket

