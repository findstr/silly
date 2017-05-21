local core = require "silly.core"
local env = require "silly.env"
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

MSG[sampleproto:querytag("r_hello")] = function(fd, cmd, data)
	print(data.val)
	data.val = data.val .. "sample"
	local ok = send(fd, "a_hello", data)
	print("send:", ok)
	return
end

MSG[sampleproto:querytag("r_sum")] = function(fd, cmd, data)
	local rrpc_sum = data
	data.suffix = data.suffix .. "sampled"
	local res = rpcclient:call("rrpc_sum", rrpc_sum)
	local ok = send(fd, "a_sum", res)
	print("a_sum", fd, ok)
end


rpcclient = rpc.createclient {
	addr = env.get "rpcd_port",
	proto = rpcproto,
	timeout = 5000,
	close = function(fd, errno)
		print("close", fd, errno)
	end
}

server = msg.createserver {
	addr = env.get("sampled_port"),
	accept = function(fd, addr)
		print("accept", addr)
	end,
	close = function(fd, errno)
		print("close", fd, errno)
	end,
	data = function(fd, d, sz)
		local cmd, data = decode(sampleproto, d, sz)
		assert(MSG[cmd])(fd, cmd, data)
	end
}

core.start(function()
	local ok = rpcclient:connect()
	print("rpc connect", ok)
	assert(ok)
	ok = server:start()
	print("server start", ok)
	assert(ok)
	local res = rpcclient:call("rrpc_sum", {val1 = 3, val2 = 4, suffix="hello"})
end)

