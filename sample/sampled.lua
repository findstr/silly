local core = require "sys.core"
local msg = require "saux.msg"
local rpc = require "saux.rpc"
local rpcproto = require "rpcproto"
local sampleproto = require "sampleproto"
local wire = require "wire"

local server
local rpcclient

local MSG = {}
local NIL = {}

local encode = wire.encode
local decode = wire.decode

local function send(fd, cmd, ack)
	local dat = encode(sampleproto, cmd, ack)
	return server:send(fd, dat)
end

MSG[sampleproto:tag("r_hello")] = function(fd, cmd, data)
	core.log(data.val)
	data.val = data.val .. "sample"
	local ok = send(fd, "a_hello", data)
	core.log("send:", ok)
	return
end

MSG[sampleproto:tag("r_sum")] = function(fd, cmd, data)
	local rrpc_sum = data
	data.suffix = data.suffix .. "sampled"
	local res = rpcclient:call("rrpc_sum", rrpc_sum)
	local ok = send(fd, "a_sum", res)
	core.log("a_sum", fd, ok)
end


rpcclient = rpc.createclient {
	addr = core.envget "rpcd_port",
	proto = rpcproto,
	timeout = 5000,
	close = function(fd, errno)
		core.log("close", fd, errno)
	end
}

server = msg.createserver {
	addr = core.envget("sampled_port"),
	accept = function(fd, addr)
		core.log("accept", addr)
	end,
	close = function(fd, errno)
		core.log("close", fd, errno)
	end,
	data = function(fd, d, sz)
		local cmd, data = decode(sampleproto, d, sz)
		assert(MSG[cmd])(fd, cmd, data)
	end
}

core.start(function()
	local ok = rpcclient:connect()
	core.log("rpc connect", ok)
	assert(ok)
	ok = server:start()
	core.log("server start", ok)
	assert(ok)
	local res = rpcclient:call("rrpc_sum", {val1 = 3, val2 = 4, suffix="hello"})
end)

