local core = require "silly.core"
local env = require "silly.env"
local proto = require "sampleproto"
local wire = require "wire"
local msg = require "saux.msg"

local decode = wire.decode
local encode = wire.encode

local client = msg.createclient {
	addr = env.get "sampled_port",
	accept = function(fd, addr)
		core.log("accept", addr)
	end,
	close = function(fd, errno)
		core.log("close", fd, errno)
	end,
	data = function(fd, d, sz)
		local cmd, dat = decode(proto, d, sz)
		core.log("read", cmd)
		for k, v in pairs(dat) do
			core.log(k, v)
		end
	end
}

local function oneuser()
	local fd = client:connect()
	local ok = client:send(encode(proto, "r_hello", {
		val = "client"
	}))
	core.log("send r_hello", ok)
	local ok = client:send(encode(proto, "r_sum", {
		val1 = 1,
		val2 = 3,
		suffix = "client"
	}))
	core.log("send r_sum", ok)
	core.sleep(100)
	client:close()
end


core.start(function()
	oneuser()
end)

