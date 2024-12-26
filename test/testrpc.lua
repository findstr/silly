local core = require "core"
local waitgroup = require "core.sync.waitgroup"
local cluster = require "core.cluster"
local crypto = require "core.crypto"
local testaux = require "test.testaux"
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

print(type(logic))
assert(logic)

local function case_one(msg, cmd, fd)
	return msg
end

local function case_two(msg, cmd, fd)
	core.sleep(100)
	return msg
end

local function case_three(msg, cmd, fd)
	core.sleep(2000)
end

local callret = {
	["foo"] = "bar",
	[0xff] = "bar",
	["bar"] = "foo",
	[0xfe] = "foo",
}

local function unmarshal(typ, cmd, buf, size)
	if typ == "response" then
		cmd = callret[cmd]
	end
	local dat, size = logic:unpack(buf, size, true)
	local body = logic:decode(cmd, dat, size)
	return body
end

local function marshal(typ, cmd, body)
	if typ == "response" then
		if not body then
			return nil, nil, nil
		end
		cmd = callret[cmd]
		if not cmd then --no need response
			return nil, nil, nil
		end
	end
	if type(cmd) == "string" then
		cmd = logic:tag(cmd)
	end
	print("marshal", typ, cmd, body)
	local dat, sz = logic:encode(cmd, body, true)
	local buf, size = logic:pack(dat, sz, true)
	return cmd, buf, size
end


local case = case_one
local accept_fd
local accept_addr

local server = cluster.new {
	timeout = 1000,
	marshal = marshal,
	unmarshal = unmarshal,
	accept = function(fd, addr)
		accept_fd = fd
		accept_addr = addr
	end,
	call = function(msg, cmd, fd)
		return case(msg, cmd, fd)
	end,
	close = function(fd, errno)
	end,
}

local listen_fd = server.listen("127.0.0.1:8989")
local client_fd
local client = cluster.new {
	timeout = 1000,
	marshal = marshal,
	unmarshal = unmarshal,
	callret = callret,
	call = function(msg, cmd, fd)
		return case(msg, cmd, fd)
	end,
	close = function(fd, errno)
	end,
}
assert(server)

local function request(fd, index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, err = client.call(fd, cmd, test)
			testaux.assertneq(body, nil, err)
			testaux.asserteq(test.rand, body and body.rand, "rpc match request/response")
		end
	end
end

local function timeout(fd, index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, err = client.call(fd, cmd, test)
			testaux.asserteq(body, nil, err)
			testaux.asserteq(err, "timeout", "rpc timeout, ack is timeout")
		end
	end
end



local function client_part()
	local err
	client_fd, err = client.connect("127.0.0.1:8989")
	print("connect", client_fd, err)
	local wg = waitgroup:create()
	case = case_one
	for i = 1, 2 do
		local cmd
		if i % 2 == 0 then
			cmd = "foo"
		else
			cmd = "bar"
		end
		wg:fork(request(client_fd, i, 5, cmd))
	end
	wg:wait()
	print("case one finish")
	case  = case_two
	for i = 1, 20 do
		wg:fork(request(client_fd, i, 50, "foo"))
		core.sleep(100)
	end
	wg:wait()
	print("case two finish")
	case = case_three
	for i = 1, 20 do
		wg:fork(timeout(client_fd, i, 2, "foo"))
		core.sleep(10)
	end
	wg:wait()
	print("case three finish")
end

local function server_part()
	print("server_part")
	case = case_one
	local req = {
		name = "hello",
		age = 1,
		rand = crypto.randomkey(8),
	}
	local ack, _ = server.call(accept_fd, "foo", req)
	testaux.assertneq(ack, nil, "rpc timeout")
	testaux.asserteq(req.rand, ack and ack.rand, "rpc match request/response")
end

client_part()
server_part()
client.close(client_fd)
server.close(listen_fd)
server.close(accept_fd)
testaux.asserteq(next(client.__fdaddr), nil, "client fdaddr empty")
testaux.asserteq(next(server.__fdaddr), nil, "client fdaddr empty")
