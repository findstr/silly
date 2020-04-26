local core = require "sys.core"
local waitgroup = require "sys.waitgroup"
local rpc = require "saux.rpc"
local crypto = require "sys.crypto"
local testaux = require "testaux"
local zproto = require "zproto"

local logic = zproto:parse [[
foo 0xff {
	.name:string 1
	.age:integer 2
	.rand:string 3
}
bar 0xfe {
	.rand:string 1
}
]]

local function case_one(msg, cmd, fd)
	if cmd == 0xff then
		cmd = 0xfe
	else
		cmd = 0xff
	end
	return cmd, msg
end

local function case_two(msg, cmd, fd)
	core.sleep(100)
	return cmd, msg
end

local case = case_one

local server = rpc.createserver {
	addr = ":8989",
	proto = logic,
	accept = function(fd, addr)
	end,

	close = function(fd, errno)
	end,

	call = function(msg, cmd, fd)
		return case(msg, cmd, fd)
	end
}

local client = rpc.createclient {
	addr = "127.0.0.1:8989",
	proto = logic,
	timeout = 5000,
	close = function(fd, errno)
	end,
}

local function server_part()
	server:listen()
end

local function request(fd, index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, ack = client:call(cmd, test)
			testaux.assertneq(body, nil, "rpc timeout")
			testaux.asserteq(test.rand, body.rand, "rpc match request/response")
		end
	end
end

local function client_part()
	client:connect()
	local wg = waitgroup:create()
	case = case_one
	for i = 1, 2 do
		local cmd
		if i % 2 == 0 then
			cmd = "foo"
		else
			cmd = "bar"
		end
		wg:fork(request(client, i, 5, cmd))
	end
	wg:wait()
	print("case one finish")
	case  = case_two
	for i = 1, 20 do
		wg:fork(request(client, i, 50, "foo"))
		core.sleep(100)
	end
	wg:wait()
end

return function()
	server_part()
	client_part()
	client:close()
	server:close()
end

