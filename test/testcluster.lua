local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local np = require "silly.net.cluster.c"
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"
local cluster = require "silly.net.cluster"
local crypto = require "silly.crypto.utils"
local errno = require "silly.errno"
local testaux = require "test.testaux"

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
	local hdr = string.pack("<I8I8", 0, 0) --session(8), traceid(8)
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
	local hdr = string.pack("<I8I8", 0, 0) --session(8), traceid(8)
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
	local expected_session = 0x100000001
	local expected_traceid = 42
	-- Wire request body header: session(8), traceid(8).
	local hdr = string.pack("<I8I8", expected_session,
		expected_traceid)
	local body = hdr .. raw
	local pk = string.pack("<I4", #body) .. body
	local ptr, size = testaux.new(pk)
	local ok, err = np.push(buf, 1, ptr, size)
	testaux.asserteq(ok, true, "hardlimit push within limit should succeed")
	testaux.asserteq(err, nil, "hardlimit push within limit should have no error")
	local fd, data, session, traceid, isreq = np.pop(buf)
	testaux.asserteq(fd, 1, "hardlimit push within limit fd")
	testaux.asserteq(data, raw, "hardlimit push within limit data")
	testaux.asserteq(session, expected_session,
		"Test 10.1: Request session should be decoded")
	testaux.asserteq(traceid, expected_traceid,
		"Test 10.2: Request traceid should be decoded")
	testaux.asserteq(isreq, nil,
		"Test 10.3: Pop should return four values")

	local response = np.response(buf, session, "response")
	local response_ptr, response_size = testaux.new(response)
	local response_ok, response_err = np.push(buf, 2,
		response_ptr, response_size)
	testaux.asserteq(response_ok, true,
		"Test 10.4: Response packet should be accepted")
	testaux.asserteq(response_err, nil,
		"Test 10.5: Response packet should not return an error")
	local response_fd, response_data, response_session,
		response_traceid, response_isreq = np.pop(buf)
	testaux.asserteq(response_fd, 2,
		"Test 10.6: Response fd should be decoded")
	testaux.asserteq(response_data, "response",
		"Test 10.7: Response data should be decoded")
	testaux.asserteq(response_session, session,
		"Test 10.8: Response session should be decoded")
	testaux.asserteq(response_traceid, nil,
		"Test 10.9: Response traceid should be nil")
	testaux.asserteq(response_isreq, nil,
		"Test 10.10: Pop should not return a request flag")
end)

testaux.case("Test 11: Hardlimit request (error)", function()
	local limit = 32
	local buf = np.create(limit, limit)
	local data = string.rep("x", limit)
	local session, err = np.request(buf, 0, data)
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


local function case_one(peer, data)
	return data
end

local function case_two(peer, data)
	time.sleep(100)
	return data
end

local function case_three(peer, data)
	time.sleep(2000)
end

local function case_four(peer, data)
	local big = string.rep("x", CLUSTER_HARDLIMIT + 1024)
	return big
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
	accept = function(peer)
		accept_peer = peer
		accept_addr = peer.remoteaddr
	end,
	call = function(peer, data)
		return case(peer, data)
	end,
	close = function(peer, errno)
	end,
}

local function request(fd, index, count)
	return function()
		for i = 1, count do
			local data = "hello-" .. index .. "-" .. crypto.randomkey(8)
			local body, err = cluster.call(fd, data)
			testaux.assertneq(body, nil, err)
			testaux.asserteq(data, body, "rpc match request/response")
		end
	end
end

local function timeout(fd, index, count)
	return function()
		for i = 1, count do
			local data = "hello-" .. index
			local body, err = cluster.call(fd, data)
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
	local err
	client_peer, err = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(client_peer, nil, "connect should succeed: " .. tostring(err))
	testaux.assertneq(client_peer.fd, nil, "fd should be set (eager connect)")
	testaux.asserteq(client_peer.remoteaddr, "127.0.0.1:8989", "peer should have remoteaddr")
	wait_done(function()
		return accept_peer ~= nil
	end, 2000, "accept")
	testaux.assertneq(accept_addr, nil, "accept addr should be set")
	-- Verify RPC works
	case = case_one
	local ack = cluster.call(client_peer, "test-data")
	testaux.assertneq(ack, nil, "call should succeed")
	testaux.asserteq(ack, "test-data", "call should echo")
end)

testaux.case("Test 14: RPC case one", function()
	local wg = waitgroup.new()
	case = case_one
	for i = 1, 2 do
		wg:fork(request(client_peer, i, 5))
	end
	wg:wait()
end)

testaux.case("Test 15: RPC case two (delay)", function()
	local wg = waitgroup.new()
	case = case_two
	for i = 1, 20 do
		wg:fork(request(client_peer, i, 50))
		time.sleep(100)
	end
	wg:wait()
end)

testaux.case("Test 16: RPC case three (timeout)", function()
	local wg = waitgroup.new()
	case = case_three
	for i = 1, 20 do
		wg:fork(timeout(client_peer, i, 2))
		time.sleep(10)
	end
	wg:wait()
end)

testaux.case("Test 18: Late response after timeout", function()
	local entered = channel.new()
	local release = channel.new()
	local completed = channel.new()
	case = function(peer, data)
		entered:push(true)
		release:pop()
		return data
	end
	task.fork(function()
		local body, err = cluster.call(client_peer, "late-response")
		completed:push({body, err})
	end)
	entered:pop()
	local result = completed:pop()
	testaux.asserteq(result[1], nil,
		"Test 18.1: Delayed call should time out")
	testaux.asserteq(result[2], ETIMEDOUT,
		"Test 18.2: Delayed call should return timeout error")
	case = case_one
	release:push(true)
	local body, err = cluster.call(client_peer, "after-late-response")
	testaux.asserteq(body, "after-late-response",
		"Test 18.3: Cluster should process calls after a late response")
	testaux.asserteq(err, nil,
		"Test 18.4: Call after late response should not fail")
end)

testaux.case("Test 17: Server callback", function()
	case = case_one
	local data = "server-callback-" .. crypto.randomkey(8)
	local ack, _ = cluster.call(accept_peer, data)
	testaux.assertneq(ack, nil, "rpc should succeed")
	testaux.asserteq(data, ack, "rpc should echo")
	local old_fd = accept_peer.fd
	cluster.close(accept_peer)
	wait_done(function()
		return accept_peer.fd == nil
	end, 2000, "accept close")
	wait_done(function()
		return client_peer.fd == nil
	end, 2000, "client close")
	accept_peer = nil
	-- client_peer connection dropped by server close; reconnect for subsequent tests
	client_peer = nil
	local err
	client_peer, err = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(client_peer, nil, "reconnect should succeed: " .. tostring(err))
	wait_done(function()
		return accept_peer ~= nil
	end, 2000, "reconnect accept")
end)

testaux.case("Test 19: Cluster call oversize request", function()
	case = case_one
	local big = string.rep("x", CLUSTER_HARDLIMIT + 1024)
	local body, err = cluster.call(client_peer, big)
	testaux.asserteq(body, nil, "oversize request should fail")
	testaux.assertneq(err, nil, "oversize request should return error")
end)

testaux.case("Test 20: Cluster call oversize response", function()
	case = case_four
	local body, err = cluster.call(client_peer, "trigger-big-response")
	testaux.asserteq(body, nil, "oversize response should fail")
	testaux.asserteq(err, ETIMEDOUT, "oversize response should timeout")
	case = case_one
end)

testaux.case("Test 21: Multiple connections to same address", function()
	case = case_one
	local err1, err2
	local p1, _ = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(p1, nil, "p1 connect should succeed")
	testaux.assertneq(p1.fd, nil, "p1 fd should be set (eager connect)")
	testaux.asserteq(p1.remoteaddr, "127.0.0.1:8989", "p1 should have remoteaddr")
	local p2, _ = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(p2, nil, "p2 connect should succeed")
	testaux.assertneq(p2.fd, nil, "p2 fd should be set (eager connect)")
	local r1, _ = cluster.call(p1, "data-a")
	testaux.assertneq(r1, nil, "p1 call should succeed")
	testaux.asserteq(r1, "data-a", "p1 call should match")
	local r2, _ = cluster.call(p2, "data-b")
	testaux.assertneq(r2, nil, "p2 call should succeed")
	testaux.asserteq(r2, "data-b", "p2 call should match")
	testaux.assertneq(p1.fd, p2.fd, "two peers should have different fds")
	cluster.close(p1)
	cluster.close(p2)
end)

testaux.case("Test 22: Call after active close returns peer closed", function()
	case = case_one
	local p, err = cluster.connect("127.0.0.1:8989")
	testaux.assertneq(p, nil, "connect should succeed: " .. tostring(err))
	local r, _ = cluster.call(p, "test")
	testaux.assertneq(r, nil, "first call should succeed")
	testaux.assertneq(p.fd, nil, "fd should be set after connect")
	cluster.close(p)
	testaux.asserteq(p.fd, nil, "fd should be cleared after close")
	local r2, err2 = cluster.call(p, "test")
	testaux.asserteq(r2, nil, "call after close should fail")
	testaux.asserteq(err2, "Peer closed", "call after close should return peer closed")
end)

testaux.case("Test 23: Connect to non-listening port fails", function()
	local p, err = cluster.connect("127.0.0.1:19999")
	testaux.asserteq(p, nil, "connect should fail to non-listening port")
	testaux.assertneq(err, nil, "should return error string")
end)

testaux.case("Test 24: Cluster cleanup", function()
	cluster.close(client_peer)
	cluster.close(accept_peer)
	cluster.close(listener)
end)

testaux.case("Test 25: Cluster connect DNS failure returns host-specific string", function()
	testaux.with_mocked_dns(function(host, qtype)
		return nil, "Query timed out (10001)"
	end, {"silly.net.cluster"}, function(reloaded)
		local mock_cluster = reloaded["silly.net.cluster"]
		mock_cluster.serve {
			timeout = 1000,
			call = function(peer, data)
				return data
			end,
		}
		local peer, err = mock_cluster.connect("dns-fail.test:8989")
		testaux.asserteq(peer, nil, "Test 25.1: connect should fail on DNS error")
		testaux.assertcontains(err, "dns lookup",
			"Test 25.2: Error should mention dns lookup")
		testaux.assertcontains(err, "dns-fail.test",
			"Test 25.3: Error should include the failing host")
		testaux.assertcontains(err, "timed out",
			"Test 25.4: Error should propagate underlying DNS reason")
	end)
end)
