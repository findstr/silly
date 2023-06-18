local core = require "sys.core"
local ns = require "sys.netstream"
local assert = assert

local socket = {}

--udp client can be closed(because it use connect)
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

function socket.bind(addr, callback)
	return (core.udp_bind(addr, udp_dispatch(callback)))
end

function socket.connect(addr, callback, bindip)
	return (core.udp_connect(addr, udp_dispatch(callback), bindip))
end

socket.send = core.udp_send

return socket

