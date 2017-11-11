local core = require "sys.core"
local patch = require "sys.patch"
local console = require "sys.console"
local proto = require "rpcproto"
local rpc = require "saux.rpc"
local DO = require "rpcl"

local server = rpc.createserver {
	addr = core.envget "rpcd_port",
	proto = proto,
	accept = function(fd, addr)
		core.log("accept", fd, addr)
	end,
	close = function(fd, errno)
		core.log("close", fd, errno)
	end,
	call = function(fd, cmd, msg)
		return assert(DO[cmd])(fd, cmd, msg)
	end,
}

local ok = server:listen()
core.log("rpc server start:", ok)

console {
	addr = ":2323"
}

