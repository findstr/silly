local rpc = require "saux.rpc"
local proto = require "rpcproto"
local env = require "silly.env"

local DO = {}

DO[proto:querytag("rrpc_sum")] = function(fd, cmd, msg)
	local arpc_sum = {
		val = msg.val1 + msg.val2,
		suffix = msg.suffix .. "rpcd"
	}
	print("call", fd, cmd, msg)
	return "arpc_sum", arpc_sum
end

local server = rpc.createserver {
	addr = env.get "rpcd_port",
	proto = proto,
	accept = function(fd, addr)
		print("accept", fd, addr)
	end,
	close = function(fd, errno)
		print("close", fd, errno)
	end,
	call = function(fd, cmd, msg)
		return assert(DO[cmd])(fd, cmd, msg)
	end,
}

local ok = server:listen()
print("rpc server start:", ok)

