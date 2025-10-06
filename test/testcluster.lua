local silly = require "silly"
local time = require "silly.time"
local np = require "silly.net.cluster.c"
local waitgroup = require "silly.sync.waitgroup"
local cluster = require "silly.net.cluster"
local crypto = require "silly.crypto.utils"
local testaux = require "test.testaux"
local zproto = require "zproto"

local BUFF

local function popdata()
	local fd, data = np.pop(BUFF)
	return fd, data
end

local function buildpacket()
	local len = math.random(1, 30)
	local raw = testaux.randomdata(len)
	testaux.asserteq(#raw, len, "random packet length")
	local pk = string.pack(">I2", #raw + 16) .. string.pack("<c" .. #raw, raw) .. string.pack("<I8I8", 0, 0)
	return raw, pk
end

local function justpush(sid, pk)
	local ptr, size = testaux.new(pk)
	np.push(BUFF, sid, ptr, size)
end

local function randompush(sid, pk)
	local i = 1
	local len = #pk + 1
	local buf = {}
	while i < len do
		local last = len - i
		if last > 2 then
			last = last // 2
			last = math.random(1, last)
		end
		local x = pk:sub(i, i + last - 1)
		i = i + last;
		buf[#buf + 1] =  x
		justpush(sid, x)
	end
	assert(table.concat(buf), pk)
end

local function pushbroken(sid, pk)
	local pk2 = pk:sub(1, #pk - 17)
	randompush(sid, pk2)
end

local function testhashconflict_part1()
	local dat = "\x00\x101234567812345678"
	local part1 = dat:sub(1, 7)
	justpush(0, part1)
	justpush(2048, part1)
	justpush(4096, part1)
	justpush(8192, part1)
end

local function testhashconflict_part2()
	local dat = "\x00\x101234567812345678"
	local part2 = dat:sub(8, -1)
	justpush(2048, part2)
	justpush(4096, part2)
	justpush(8192, part2)
	justpush(0, part2)
	local fd, data = popdata()
	testaux.asserteq(fd, 2048, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 4096, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 8192, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 0, "netpacket first packet")

end

local function testpacket(push)
	print("--------testpacket-----------")
	local raw, pk = buildpacket()
	local sid = math.random(8193, 65535)
	push(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(sid, fd, "netpacket test fd")
	testaux.asserteq(raw, data, "netpacket test data")
	fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket empty test fd")
	testaux.asserteq(data, nil, "netpacket empty test data")
end

local function testclear()
	print("--------testclear-----------")
	local raw, pk = buildpacket()
	local sid = math.random(8193, 65535)
	pushbroken(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket broken test fd")
	testaux.asserteq(data, nil, "netpacket broken test data")
	np.clear(BUFF, sid)
	randompush(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(fd, sid, "netpacket clear test fd")
	testaux.asserteq(data, raw, "netpacket clear test fd")
end


local function testexpand()
	print("--------testexpand----------")
	local queue = {}
	local total = 8194
	print("push broken data")
	local raw, pk = buildpacket()
	local sid = 1
	pushbroken(sid, pk)
	print("begin push complete data")
	for i = 1, total do
		local raw, pk = buildpacket()
		local sid = math.random(8193, 65535)
		queue[#queue + 1] = {
			fd = sid,
			raw = raw,
		}
		randompush(sid, pk)
	end
	print("push complete, begin to pop")
	for i = 1, total do
		local obj = table.remove(queue, 1)
		local fd, data = np.pop(BUFF)
		testaux.assertneq(fd, nil, "test queue expand of " .. i)
		testaux.asserteq(obj.fd, fd, "test queue expand fd")
		testaux.asserteq(obj.raw, data, "test queue expand fd")
	end
end

collectgarbage("collect")
local seedx, seedy = math.randomseed()
print("seed", seedx, seedy)
math.randomseed(1721030230,139887399596712)

BUFF = np.create()
testhashconflict_part1()
testpacket(justpush)
testpacket(randompush)
testclear()
testexpand()
testhashconflict_part2()
BUFF = nil
collectgarbage("collect")


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

local function case_one(peer, cmd, msg)
	return msg
end

local function case_two(peer, cmd, msg)
	time.sleep(100)
	return msg
end

local function case_three(peer, cmd, msg)
	time.sleep(2000)
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
			return nil, nil
		end
		cmd = callret[cmd]
		if not cmd then --no need response
			return nil, nil
		end
	end
	if type(cmd) == "string" then
		cmd = logic:tag(cmd)
	end
	local dat, sz = logic:encode(cmd, body, true)
	local buf = logic:pack(dat, sz, false)
	return cmd, buf
end


local case = case_one
local accept_peer
local accept_addr

cluster.serve {
	timeout = 1000,
	marshal = marshal,
	unmarshal = unmarshal,
	accept = function(peer, addr)
		accept_peer = peer
		accept_addr = addr
	end,
	call = function(peer, cmd, msg)
		return case(peer, cmd, msg)
	end,
	close = function(peer, errno)
	end,
}

local listener, err = cluster.listen("127.0.0.1:8989")
testaux.assertneq(listener, nil, err)
local client_peer, err = cluster.connect("127.0.0.1:8989")
testaux.assertneq(client_peer, nil, err)

local function request(fd, index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, err = cluster.call(fd, cmd, test)
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
			local body, err = cluster.call(fd, cmd, test)
			testaux.asserteq(body, nil, err)
			testaux.asserteq(err, "timeout", "rpc timeout, ack is timeout")
		end
	end
end



local function client_part()
	local err
	local wg = waitgroup.new()
	case = case_one
	for i = 1, 2 do
		local cmd
		if i % 2 == 0 then
			cmd = "foo"
		else
			cmd = "bar"
		end
		wg:fork(request(client_peer, i, 5, cmd))
	end
	wg:wait()
	print("case one finish")
	case  = case_two
	for i = 1, 20 do
		wg:fork(request(client_peer, i, 50, "foo"))
		time.sleep(100)
	end
	wg:wait()
	print("case two finish")
	case = case_three
	for i = 1, 20 do
		wg:fork(timeout(client_peer, i, 2, "foo"))
		time.sleep(10)
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
	local ack, _ = cluster.call(accept_peer, "foo", req)
	testaux.assertneq(ack, nil, "rpc timeout")
	testaux.asserteq(req.rand, ack and ack.rand, "rpc match request/response")
end

client_part()
server_part()

-- Test reconnection after remote close
local function test_reconnect_after_remote_close()
	print("--------test reconnect after remote close-----------")
	case = case_one

	-- Server closes the client connection
	print("server closing accept_peer")
	local old_fd = accept_peer.fd
	cluster.close(accept_peer)
	time.sleep(100) -- wait for close event

	-- Verify the peer fd is cleared
	testaux.asserteq(accept_peer.fd, nil, "accept_peer fd should be nil after close")

	-- Client tries to call again, should trigger reconnection
	print("client calling after server closed connection")
	local test = {
		name = "hello",
		age = 999,
		rand = crypto.randomkey(8),
	}
	local body, err = cluster.call(client_peer, "foo", test)
	testaux.assertneq(body, nil, "reconnection should succeed: " .. tostring(err))
	testaux.asserteq(test.rand, body and body.rand, "reconnect call should match request/response")

	-- Verify new connection was established
	testaux.assertneq(client_peer.fd, nil, "client_peer should have new fd")
	testaux.assertneq(client_peer.fd, old_fd, "client_peer should have different fd after reconnect")

	-- Verify accept was called again with new peer
	testaux.assertneq(accept_peer, nil, "accept_peer should be set again")
	testaux.assertneq(accept_peer.fd, nil, "new accept_peer should have fd")

	-- Server can also call back to verify bidirectional communication
	print("server calling back to verify bidirectional")
	local req = {
		name = "world",
		age = 888,
		rand = crypto.randomkey(8),
	}
	local ack, _ = cluster.call(accept_peer, "bar", req)
	testaux.assertneq(ack, nil, "server callback should succeed")
	testaux.asserteq(req.rand, ack and ack.rand, "server callback should match")

	print("test reconnect after remote close passed")
end

test_reconnect_after_remote_close()

cluster.close(client_peer)
cluster.close(accept_peer)
cluster.close(listener)