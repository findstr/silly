local core = require "silly.core"
local msg = require "saux.msg"
local np = require "netpacket"

local server
local accept = {}
local client = {}
local recv = {}

return function()
	server = msg.createserver {
		addr = "127.0.0.1@8002",
		accept = function(fd, addr)
			accept[#accept + 1] = fd
			print("accept", addr)
		end,
		close = function(fd, errno)
			print("close", fd, errno)
		end,
		data = function(fd, d, sz)
			local p, sz = np.pack(d, sz)
			local m = core.packmulti(p, sz, #accept)
			for _, fd in pairs(accept) do
				local ok = server:multicast(fd, m, sz)
				print("server send", fd, ok)
			end
			np.drop(p)
			np.drop(d)
		end
	}
	local ok = server:start()
	assert(ok, "testmulticast start")

	local inst
	for i = 1, 10 do
		inst = msg.createclient {
			addr = "127.0.0.1@8002",
			data = function(fd, d, sz)
				print("recv", i)
				local m = core.tostring(d, sz)
				np.drop(d);
				assert(m == "testmulticast")
				recv[i] = true
			end,
			close = function(fd, errno)

			end
		}
		local ok = inst:connect()
		assert(ok > 0)
		client[i] = inst
	end
	inst:send("testmulticast")
	core.sleep(1000)
	for k, _ in pairs(client) do
		assert(recv[k], "multicast")
	end
	server:stop()
end


