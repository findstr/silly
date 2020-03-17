local core = require "sys.core"
local proto = require "sampleproto"
local wire = require "wire"
local msg = require "saux.msg"

local client = msg.createclient {
	proto = proto,
	addr = core.envget "sampled_port",
	accept = function(fd, addr)
		core.log("accept", addr)
	end,
	close = function(fd, errno)
		core.log("close", fd, errno)
	end,
	data = function(fd, cmd, obj)
		core.log("read", cmd)
		for k, v in pairs(obj) do
			core.log(k, v)
		end
	end
}

local function oneuser()
	local fd = client:connect()
	local ok = client:send("r_hello", {
		val = "client"
	})
	core.log("send r_hello", ok)
	local ok = client:send("r_sum", {
		val1 = 1,
		val2 = 3,
		suffix = "client"
	})
	core.log("send r_sum", ok)
	core.sleep(100)
	client:close()
end


core.start(function()
	oneuser()
end)

