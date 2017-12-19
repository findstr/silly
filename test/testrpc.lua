local core = require "sys.core"
local rpc = require "saux.rpc"
local crypt = require "sys.crypt"
local testaux = require "testaux"
local zproto = require "zproto"

local logic = zproto:parse [[
test 0xff {
	.name:string 1
	.age:integer 2
	.rand:string 3
}
]]

local server = rpc.createserver {
	addr = ":8989",
	proto = logic,
	accept = function(fd, addr)
		--print("accept", fd, addr)
	end,

	close = function(fd, errno)
		--print("close", fd, errno)
	end,

	call = function(fd, cmd, msg)
		--print("rpc recive", fd, cmd, msg.name, msg.age, msg.rand)
		core.sleep(100)
		return cmd, msg
	end
}

local client = rpc.createclient {
	addr = "127.0.0.1:8989",
	proto = logic,
	timeout = 5000,
	close = function(fd, errno)
		--print("close", fd, errno)
	end,
}

local function server_part()
	server:listen()
end

local N = 20
local n = 0
local function request(fd, index)
	return function()
		for i = 1, 50 do
			local test = {
				name = "hello",
				age = index,
				rand = crypt.randomkey(),
			}
			local body, ack = client:call("test", test)
			if not body then
				--print("rpc call fail", body)
				return
			end
			testaux.asserteq(test.rand, body.rand, "rpc match request/response")
		end
		n = n + 1
	end
end

local function client_part()
	client:connect()
	for i = 1, N do
		core.fork(request(client, i))
		core.sleep(100)
	end
	while true do
		core.sleep(100)
		if n >= N then
			break
		end
	end
end

return function()
	server_part()
	client_part()
	client:close()
	server:close()
end

