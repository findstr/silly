local core = require "sys.core"
local testaux = require "testaux"
local msg = require "saux.msg"
local np = require "sys.netpacket"
local zproto = require "zproto"
local logic = zproto:parse [[
test 0xff {
	.str:string 1
}
]]


local server
local accept = {}
local client = {}
local recv = {}

return function()
	server = msg.createserver {
		proto = logic,
		addr = "127.0.0.1:8002",
		accept = function(fd, addr)
			accept[#accept + 1] = fd
			--print("accept", addr)
		end,
		close = function(fd, errno)
			--print("close", fd, errno)
		end,
		data = function(fd, cmd, obj)
			local m, sz = server:multipack(cmd, obj, #accept)
			for _, fd in pairs(accept) do
				local ok = server:multicast(fd, m, sz)
				testaux.assertneq(fd, nil, "multicast test send")
				testaux.asserteq(ok, true, "multicast test send")
			end
		end
	}
	local ok = server:listen()
	testaux.asserteq(not not ok, true, "multicast test listen")

	local inst
	for i = 1, 10 do
		inst = msg.createclient {
			proto = logic,
			addr = "127.0.0.1:8002",
			data = function(fd, cmd, obj)
				testaux.asserteq(obj.str, "testmulticast", "muticast validate data")
				recv[i] = true
			end,
			close = function(fd, errno)

			end
		}
		local ok = inst:connect()
		testaux.asserteq(ok > 0, true, "multicast connect success")
		client[i] = inst
	end
	inst:send("test", {str = "testmulticast"})
	core.sleep(1000)
	for k, _ in pairs(client) do
		testaux.asserteq(recv[k], true, "multicast recv count validate")
	end
	server:stop()
end


