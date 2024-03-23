local core = require "core"
local crypto = require "core.crypto"
local rpc = require "cluster.rpc"
local zproto = require "zproto"

local proto = zproto:parse [[
ping 0x1 {
	.txt:string 1
}
pong 0x2 {
	.txt:string 1
}
]]


local server = rpc.listen {
	addr = "127.0.0.1:9999",
	proto = proto,
	accept = function(fd, addr)
		print("accept", fd, addr)
	end,

	close = function(fd, errno)
		print("close", fd, errno)
	end,

	call = function(msg, cmd, fd)
		print("callee", msg.txt, cmd, fd)
		return "pong", msg
	end
}


core.start(function()
	for i = 1, 3 do
		core.fork(function()
			local conn = rpc.connect {
				addr = "127.0.0.1:9999",
				proto = proto,
				timeout = 5000,
				close = function(fd, errno)
				end,
			}
			while true do
				local txt = crypto.randomkey(5)
				local ack, cmd = conn:call("ping", {txt = txt})
				print("caller", conn, txt, ack.txt)
				assert(ack.txt == txt)
				assert(cmd == proto:tag("pong"))
				core.sleep(1000)
			end
		end)
	end
end)

