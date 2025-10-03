local time = require "silly.time"
local silly = require "silly"
local crypto = require "silly.crypto.utils"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
ping 0x1 {
	.txt:string 1
}
pong 0x2 {
	.txt:string 1
}
]]

assert(proto)
local function unmarshal(typ, cmd, buf, size)
	if typ == "response" then
		if cmd == "ping" then
			cmd = "pong"
		end
	end
	local dat, size = proto:unpack(buf, size, true)
	local body = proto:decode(cmd, dat, size)
	return body
end

local function marshal(typ, cmd, body)
	if typ == "response" then
		if cmd == "ping" then
			cmd = "pong"
		end
	end
	if type(cmd) == "string" then
		cmd = proto:tag(cmd)
	end
	print("marshal 2", cmd, body)
	local dat, size = proto:encode(cmd, body, true)
	local buf, size = proto:pack(dat, size, true)
	return cmd, buf, size
end

local callret = {
	["ping"] = "pong",
	[0x01] = "pong",
}

local server = cluster.new {
	marshal = marshal,
	unmarshal = unmarshal,
	callret = callret,
	accept = function(fd, addr)
		print("accept", fd, addr)
	end,
	call = function(msg, cmd, fd)
		print("callee", msg.txt, fd)
		return msg
	end,
	close = function(fd, errno)
		print("close", fd, errno)
	end,
}
--Prevent the `server` from being garbage collected.
_G['xxx'] = server
server.listen("127.0.0.1:9999")

local client = cluster.new {
	marshal = marshal,
	unmarshal = unmarshal,
	callret = callret,
	call = function(msg, cmd, fd)
		print("callee", msg.txt, fd)
		return msg
	end,
	close = function(fd, errno)
		print("close", fd, errno)
	end,
}

silly.start(function()
	for i = 1, 3 do
		silly.fork(function()
			local fd, err = client.connect("127.0.0.1:9999")
			print("connect", fd, err)
			for j = 1, 10000 do
				local txt = crypto.randomkey(5)
				local ack = client.call(fd, "ping", {txt = txt})
				--print("caller", fd, txt, ack.txt)
				assert(ack.txt == txt)
				time.sleep(1000)
			end
			client.close(fd)
		end)
	end
end)

