local silly = require "silly"
local time = require "silly.time"
local np = require "silly.net.cluster.c"
local waitgroup = require "silly.sync.waitgroup"
local cluster = require "silly.net.cluster"
local crypto = require "silly.crypto.utils"
local errno = require "silly.errno"
local testaux = require "test.testaux"
local zproto = require "zproto"

-- NOTE (test-only use of silly.errno):
-- ETIMEDOUT is used here to white-box test that silly.net.cluster
-- surfaces silly.errno.TIMEDOUT when an RPC call times out. Production
-- code must NOT compare cluster errors against silly.errno — cluster's
-- public contract is `string?`, and it may rewrap errors in the future.
-- Only silly.net / silly.net.{tcp,tls,udp} callers may branch on
-- silly.errno values.
local ETIMEDOUT<const> = errno.TIMEDOUT

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
	accept = function(peer)
		accept_peer = peer
		accept_addr = peer.remoteaddr
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
			testaux.asserteq(err, ETIMEDOUT, "rpc timeout, ack is timeout")
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
	testaux.asserteq(client_peer.fd, nil, "fd should be nil before first call (lazy connect)")
	testaux.asserteq(client_peer.addr, "127.0.0.1:8989", "peer should have addr")
	testaux.asserteq(client_peer.remoteaddr, "127.0.0.1:8989", "peer should have remoteaddr")
	-- Trigger lazy connect so accept callback fires on the server side.
	case = case_one
	local ack = cluster.call(client_peer, "foo", { name = "x", age = 1, rand = "z" })
	testaux.assertneq(ack, nil, "first call should establish connection")
	testaux.assertneq(client_peer.fd, nil, "fd should be set after first call")
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
	testaux.asserteq(err, ETIMEDOUT, "oversize response should timeout")
	case = case_one
end)

testaux.case("Test 21: Multiple connections to same address", function()
	case = case_one
	-- Connect two peers to the same listener
	local p1 = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(p1, nil, "p1 connect should succeed")
	testaux.asserteq(p1.fd, nil, "p1 fd should be nil before first call (lazy connect)")
	testaux.asserteq(p1.addr, "127.0.0.1:8989", "p1 should have addr")
	testaux.asserteq(p1.remoteaddr, "127.0.0.1:8989", "p1 should have remoteaddr")
	local p2 = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(p2, nil, "p2 connect should succeed")
	testaux.asserteq(p2.fd, nil, "p2 fd should be nil before first call (lazy connect)")
	-- First call triggers the actual connection for each peer independently
	local r1, _ = cluster.call(p1, "foo", { name = "a", age = 1, rand = "x" })
	testaux.assertneq(r1, nil, "p1 call should succeed")
	testaux.asserteq(r1.rand, "x", "p1 call should match")
	testaux.assertneq(p1.fd, nil, "p1 fd should be set after first call")
	local r2, _ = cluster.call(p2, "bar", { name = "b", age = 2, rand = "y" })
	testaux.assertneq(r2, nil, "p2 call should succeed")
	testaux.asserteq(r2.rand, "y", "p2 call should match")
	testaux.assertneq(p2.fd, nil, "p2 fd should be set after first call")
	-- Two connections to same address must hold independent fds
	testaux.assertneq(p1.fd, p2.fd, "two peers should have different fds")
	cluster.close(p1)
	cluster.close(p2)
end)

testaux.case("Test 22: Call after active close returns peer closed", function()
	case = case_one
	local p = cluster.connect("127.0.0.1:8989")
	-- Establish the connection so we exercise the active-close path, not
	-- just the never-connected path.
	local r, _ = cluster.call(p, "foo", { name = "c", age = 1, rand = "z" })
	testaux.assertneq(r, nil, "first call should succeed")
	testaux.assertneq(p.fd, nil, "fd should be set after first call")
	cluster.close(p)
	testaux.asserteq(p.fd, nil, "fd should be cleared after close")
	testaux.asserteq(p.addr, nil, "addr should be cleared after close")
	local r2, err = cluster.call(p, "foo", { name = "c", age = 1, rand = "z" })
	testaux.asserteq(r2, nil, "call after close should fail")
	testaux.asserteq(err, "Peer closed", "call after close should return peer closed")
	-- Never-connected peer: close immediately, then call.
	local q = cluster.connect("127.0.0.1:8989")
	cluster.close(q)
	local r3, err2 = cluster.call(q, "foo", { name = "c", age = 1, rand = "z" })
	testaux.asserteq(r3, nil, "call on never-connected closed peer should fail")
	testaux.asserteq(err2, "Peer closed", "call on never-connected closed peer should return peer closed")
end)

testaux.case("Test 23: Close during in-flight connect", function()
	case = case_one
	accept_peer = nil
	local p = cluster.connect("127.0.0.1:8989")
	-- Task A calls on a peer with fd == nil, so it yields inside
	-- net.tcpconnect waiting for the CONNECT event. Task B is scheduled
	-- while A is yielded and clears peer.addr. When A resumes, its
	-- in-flight fd must be discarded and the call must surface
	-- "peer closed" rather than returning a live connection on a peer
	-- the user already closed.
	local wg = waitgroup.new()
	local call_result, call_err
	wg:fork(function()
		call_result, call_err = cluster.call(p, "foo",
			{ name = "r", age = 1, rand = "z" })
	end)
	wg:fork(function()
		cluster.close(p)
	end)
	wg:wait()
	testaux.asserteq(call_result, nil,
		"concurrent close must abort the in-flight call")
	testaux.asserteq(call_err, "Peer closed",
		"concurrent close must surface peer closed")
	testaux.asserteq(p.fd, nil,
		"peer.fd must remain nil after concurrent close")
	testaux.asserteq(p.addr, nil,
		"peer.addr must remain cleared after concurrent close")
	-- The race closes the client-side fd after the server has already
	-- accepted it. Wait for the server-side accept to fire and then for
	-- its peer fd to be cleaned up before the netstat check runs.
	wait_done(function()
		return accept_peer ~= nil
	end, 2000, "server accept after race")
	wait_done(function()
		return accept_peer.fd == nil
	end, 2000, "server cleanup after race")
end)

testaux.case("Test 24: Cluster cleanup", function()
	cluster.close(client_peer)
	cluster.close(accept_peer)
	cluster.close(listener)
end)

testaux.case("Test 25: Cluster DNS failure returns host-specific string", function()
	testaux.with_mocked_dns(function(host, qtype)
		return nil, "Query timed out (10001)"
	end, {"silly.net.cluster"}, function(reloaded)
		local mock_cluster = reloaded["silly.net.cluster"]
		mock_cluster.serve {
			timeout = 1000,
			marshal = function(kind, cmd, obj)
				return 1, ""
			end,
			unmarshal = function(kind, cmd, body)
				return {}, nil
			end,
			call = function(fd, cmd, obj)
				return {}
			end,
		}
		local peer = mock_cluster.connect("dns-fail.test:8989")
		local resp, err = mock_cluster.call(peer, "foo", {})
		testaux.asserteq(resp, nil, "Test 25.1: Cluster call should fail on DNS error")
		testaux.assertcontains(err, "dns lookup",
			"Test 25.2: Error should mention dns lookup")
		testaux.assertcontains(err, "dns-fail.test",
			"Test 25.3: Error should include the failing host")
		testaux.assertcontains(err, "timed out",
			"Test 25.4: Error should propagate underlying DNS reason")
	end)
end)
