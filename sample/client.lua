local core = require "silly.core"
local env = require "silly.env"
local proto = require "sampleproto"
local msg = require "saux.msg"

local client = msg.createclient {
	addr = env.get "sampled_port",
	proto = proto,
}

local function oneuser()
	local fd = client:connect()
	local ok = client:send("r_hello", {
		val = "client"
	})
	print("send", ok)
	local cmd, dat = client:read()
	print("read", cmd, dat, dat and dat.val)
	local ok = client:send("r_sum", {
		val1 = 1,
		val2 = 3,
		suffix = "client"
	})
	print("send", ok)
	local cmd, dat = client:read()
	print("read", cmd, dat, dat and dat.suffix)
	client:close()

end


core.start(function()
	oneuser()
end)

