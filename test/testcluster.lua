local silly = require "silly"
local time = require "silly.time"
local np = require "silly.net.cluster.c"
local waitgroup = require "silly.sync.waitgroup"
local cluster = require "silly.net.cluster"
local crypto = require "silly.crypto.utils"
local testaux = require "test.testaux"
local zproto = require "zproto"

local BUFF
local CLUSTER_HARDLIMIT = 4096
local CLUSTER_SOFTLIMIT = 4096
local CLUSTER_TIMEOUT = 1000

local function wait_done(cond, timeout_ms, label)
	-- Wait for async accept/close/data callbacks to finish before moving
	-- to the next case, avoiding cross-case interference.
	local deadline = time.monotonic() + (timeout_ms or 2000)
	while not cond() do
		if time.monotonic() > deadline then
			testaux.asserteq(true, false, (label or "wait_done") .. " timeout")
		end
		time.sleep(10)
	end
end

local function popdata()
	local fd, data = np.pop(BUFF)
	return fd, data
end

local function buildpacket()
	local len = math.random(1, 30)
	local raw = testaux.randomdata(len)
	testaux.asserteq(#raw, len, "random packet length")
	local hdr = string.pack("<I4I4I8", 0, 0, 0) --session, cmd, traceid
	local body = hdr .. raw
	local pk = string.pack("<I4", #body) .. body
	return raw, pk
end

local function justpush(sid, pk)
	local ptr, size = testaux.new(pk)
	local ok, err = np.push(BUFF, sid, ptr, size)
	testaux.asserteq(ok, true, err)
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

collectgarbage("collect")
local seedx, seedy = math.randomseed()
print("seed", seedx, seedy)
math.randomseed(1721030230,139887399596712)

testaux.case("Test 1: Netpacket hash conflict part1", function()
	BUFF = np.create()
	local dat = string.pack("<I4", 16) .. "1234567812345678"
	local part1 = dat:sub(1, 10)
	justpush(0, part1)
	justpush(2048, part1)
	justpush(4096, part1)
	justpush(8192, part1)
end)

testaux.case("Test 2: Netpacket packet (justpush)", function()
	local raw, pk = buildpacket()
	local sid = math.random(8193, 65535)
	justpush(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(sid, fd, "netpacket test fd")
	testaux.asserteq(raw, data, "netpacket test data")
	fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket empty test fd")
	testaux.asserteq(data, nil, "netpacket empty test data")
end)

testaux.case("Test 3: Netpacket packet (randompush)", function()
	local raw, pk = buildpacket()
	local sid = math.random(8193, 65535)
	randompush(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(sid, fd, "netpacket test fd")
	testaux.asserteq(raw, data, "netpacket test data")
	fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket empty test fd")
	testaux.asserteq(data, nil, "netpacket empty test data")
end)

testaux.case("Test 4: Netpacket clear", function()
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
end)

testaux.case("Test 5: Netpacket queue expand", function()
	local queue = {}
	local total = 8194
	local raw, pk = buildpacket()
	local sid = 1
	pushbroken(sid, pk)
	for i = 1, total do
		local raw, pk = buildpacket()
		local sid = math.random(8193, 65535)
		queue[#queue + 1] = {
			fd = sid,
			raw = raw,
		}
		randompush(sid, pk)
	end
	for i = 1, total do
		local obj = table.remove(queue, 1)
		local fd, data = np.pop(BUFF)
		testaux.assertneq(fd, nil, "test queue expand of " .. i)
		testaux.asserteq(obj.fd, fd, "test queue expand fd")
		testaux.asserteq(obj.raw, data, "test queue expand fd")
	end
end)

testaux.case("Test 6: Netpacket hash conflict part2", function()
	local dat = string.pack("<I4", 16) .. "1234567812345678"
	local part2 = dat:sub(11, -1)
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
end)

testaux.case("Test 7: Netpacket cleanup", function()
	BUFF = nil
	collectgarbage("collect")
end)

testaux.case("Test 8: Hardlimit invalid config", function()
	local hardlimit = 64
	local softlimit = 65535
	testaux.assert_error(function()
		np.create(hardlimit, softlimit)
	end, "hardlimit must >= softlimit")
end)

testaux.case("Test 9: Hardlimit push (error)", function()
	local limit = 64
	local buf = np.create(limit, limit)
	local body = string.rep("x", limit + 1)
	local hdr = string.pack("<I4I4I8", 0, 0, 0) --session, cmd, traceid
	body = hdr .. body
	local pk = string.pack("<I4", #body) .. body
	local ptr, size = testaux.new(pk)
	local ok, err = np.push(buf, 1, ptr, size)
	testaux.asserteq(ok, false, "hardlimit push should fail")
	testaux.assertneq(err, nil, "hardlimit push should return error string")
end)

testaux.case("Test 10: Hardlimit push (ok)", function()
	local limit = 256
	local buf = np.create(limit, limit)
	local raw = "hello"
	local hdr = string.pack("<I4I4I8", 0, 0, 0) --session, cmd, traceid
	local body = hdr .. raw
	local pk = string.pack("<I4", #body) .. body
	local ptr, size = testaux.new(pk)
	local ok, err = np.push(buf, 1, ptr, size)
	testaux.asserteq(ok, true, "hardlimit push within limit should succeed")
	testaux.asserteq(err, nil, "hardlimit push within limit should have no error")
	local fd, data = np.pop(buf)
	testaux.asserteq(fd, 1, "hardlimit push within limit fd")
	testaux.asserteq(data, raw, "hardlimit push within limit data")
end)

testaux.case("Test 11: Hardlimit request (error)", function()
	local limit = 32
	local buf = np.create(limit, limit)
	local data = string.rep("x", limit)
	local session, err = np.request(buf, 1, 0, data)
	testaux.asserteq(session, false, "hardlimit request should fail")
	testaux.assertneq(err, nil, "hardlimit request should return error string")
end)

testaux.case("Test 12: Hardlimit response (error)", function()
	local limit = 32
	local buf = np.create(limit, limit)
	local data = string.rep("x", limit)
	local body, err = np.response(buf, 1, data)
	testaux.asserteq(body, false, "hardlimit response should fail")
	testaux.assertneq(err, nil, "hardlimit response should return error string")
end)


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

local function case_four(peer, cmd, msg)
	local big = string.rep("x", CLUSTER_HARDLIMIT + 1024)
	return {
		name = msg.name,
		age = msg.age,
		rand = big,
	}
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
local listener
local client_peer

cluster.serve {
	timeout = CLUSTER_TIMEOUT,
	hardlimit = CLUSTER_HARDLIMIT,
	softlimit = CLUSTER_SOFTLIMIT,
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

testaux.case("Test 13: Cluster listen/connect", function()
	accept_peer = nil
	accept_addr = nil
	listener = cluster.listen("127.0.0.1:8989")
	testaux.assertneq(listener, nil, "listener should start")
	client_peer = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(client_peer, nil, "client connect should succeed")
	wait_done(function()
		return accept_peer ~= nil
	end, 2000, "accept")
	testaux.assertneq(accept_addr, nil, "accept addr should be set")
end)

testaux.case("Test 14: RPC case one", function()
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
end)

testaux.case("Test 15: RPC case two (delay)", function()
	local wg = waitgroup.new()
	case = case_two
	for i = 1, 20 do
		wg:fork(request(client_peer, i, 50, "foo"))
		time.sleep(100)
	end
	wg:wait()
end)

testaux.case("Test 16: RPC case three (timeout)", function()
	local wg = waitgroup.new()
	case = case_three
	for i = 1, 20 do
		wg:fork(timeout(client_peer, i, 2, "foo"))
		time.sleep(10)
	end
	wg:wait()
end)

testaux.case("Test 17: Server callback", function()
	case = case_one
	local req = {
		name = "hello",
		age = 1,
		rand = crypto.randomkey(8),
	}
	local ack, _ = cluster.call(accept_peer, "foo", req)
	testaux.assertneq(ack, nil, "rpc timeout")
	testaux.asserteq(req.rand, ack and ack.rand, "rpc match request/response")
end)

testaux.case("Test 18: Reconnect after remote close", function()
	case = case_one
	local old_fd = accept_peer.fd
	cluster.close(accept_peer)
	wait_done(function()
		return accept_peer.fd == nil
	end, 2000, "accept close")
	wait_done(function()
		return client_peer.fd == nil
	end, 2000, "client close")
	accept_peer = nil

	local test = {
		name = "hello",
		age = 999,
		rand = crypto.randomkey(8),
	}
	local body, err = cluster.call(client_peer, "foo", test)
	testaux.assertneq(body, nil, "reconnection should succeed: " .. tostring(err))
	testaux.asserteq(test.rand, body and body.rand, "reconnect call should match request/response")

	wait_done(function()
		return accept_peer and accept_peer.fd and accept_peer.fd ~= old_fd
	end, 2000, "accept reconnect")

	local req = {
		name = "world",
		age = 888,
		rand = crypto.randomkey(8),
	}
	local ack, _ = cluster.call(accept_peer, "bar", req)
	testaux.assertneq(ack, nil, "server callback should succeed")
	testaux.asserteq(req.rand, ack and ack.rand, "server callback should match")
end)

testaux.case("Test 19: Cluster call oversize request", function()
	case = case_one
	local big = string.rep("x", CLUSTER_HARDLIMIT + 1024)
	local test = {
		name = "hello",
		age = 123,
		rand = big,
	}
	local body, err = cluster.call(client_peer, "foo", test)
	testaux.asserteq(body, nil, "oversize request should fail")
	testaux.assertneq(err, nil, "oversize request should return error")
end)

testaux.case("Test 20: Cluster call oversize response", function()
	case = case_four
	local test = {
		name = "hello",
		age = 456,
		rand = crypto.randomkey(8),
	}
	local body, err = cluster.call(client_peer, "foo", test)
	testaux.asserteq(body, nil, "oversize response should fail")
	testaux.asserteq(err, "timeout", "oversize response should timeout")
	case = case_one
end)

testaux.case("Test 21: Cluster cleanup", function()
	cluster.close(client_peer)
	cluster.close(accept_peer)
	cluster.close(listener)
end)
