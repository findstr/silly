local env = require "silly.env"
local patch = require "silly.patch"
local console = require "console"
local proto = require "rpcproto"
local rpc = require "saux.rpc"
local DO = require "rpcl"

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

console {
	addr = "@2323"
}

