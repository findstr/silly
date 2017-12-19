local core = require "sys.core"
local testaux = require "testaux"
local msg = require "saux.msg"
local np = require "sys.netpacket"

local server
local accept = {}
local client = {}
local recv = {}

return function()
	server = msg.createserver {
		addr = "127.0.0.1:8002",
		accept = function(fd, addr)
			accept[#accept + 1] = fd
			--print("accept", addr)
		end,
		close = function(fd, errno)
			--print("close", fd, errno)
		end,
		data = function(fd, d, sz)
			local p, sz = np.pack(d, sz)
			local m = core.packmulti(p, sz, #accept)
			for _, fd in pairs(accept) do
				local ok = server:multicast(fd, m, sz)
				testaux.assertneq(fd, nil, "multicast test send")
				testaux.asserteq(ok, true, "multicast test send")
			end
			np.drop(p)
			np.drop(d)
		end
	}
	local ok = server:start()
	testaux.asserteq(not not ok, true, "multicast test start")

	local inst
	for i = 1, 10 do
		inst = msg.createclient {
			addr = "127.0.0.1:8002",
			data = function(fd, d, sz)
				local m = core.tostring(d, sz)
				np.drop(d);
				testaux.asserteq(m, "testmulticast", "muticast validate data")
				recv[i] = true
			end,
			close = function(fd, errno)

			end
		}
		local ok = inst:connect()
		testaux.asserteq(ok > 0, true, "multicast connect success")
		client[i] = inst
	end
	inst:send("testmulticast")
	core.sleep(1000)
	for k, _ in pairs(client) do
		testaux.asserteq(recv[k], true, "multicast recv count validate")
	end
	server:stop()
end


