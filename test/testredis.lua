local silly = require "silly"
local pcall = silly.pcall
local task = require "silly.task"
local channel = require "silly.sync.channel"
local tcp = require "silly.net.tcp"
local env = require "silly.env"
local redis = require "silly.store.redis"
local testaux = require "test.testaux"
local fakeredis = require "test.fake_redis_server"
local errno = require "silly.errno"

-- White-box checks only: higher-level Redis errors remain opaque to callers.
local ECLOSED<const> = errno.CLOSED
local ECONNREFUSED<const> = errno.CONNREFUSED
local eq = testaux.asserteq
local await = testaux.await
local next_port = 16379
local redis_addr = env.get("redis.addr") or "127.0.0.1:6379"

local function fork(fn)
	local done = channel.new()
	local co = task.fork(function()
		done:push(table.pack(pcall(fn)))
	end)
	return {done = done, co = co}
end

local function join(worker)
	local result = await(worker.done, "Redis request completed")
	assert(result[1], result[2])
	return table.unpack(result, 2, result.n)
end

local fixture_mt = {
	__close = function(f)
		for _, db in ipairs(f.clients) do
			db:close()
		end
		if f.server then
			f.server:stop()
		end
	end,
}

local function fixture(handler, config)
	next_port = next_port + 1
	local server = fakeredis.new(next_port)
	server:set_handler(handler)
	server:start()
	config = config or {}
	config.addr = server.addr
	local db = redis.new(config)
	return setmetatable({server = server, db = db, clients = {db}}, fixture_mt)
end

local function realclient()
	local db = redis.new {addr = redis_addr, db = 11}
	return setmetatable({db = db, clients = {db}}, fixture_mt)
end

local function failure(ok, err, label)
	eq(ok, false, label .. " fails")
	assert(err ~= nil, label .. " returns an error")
end

local function ping(cmd, args)
	eq(args, {"PING"}, "PING wire arguments")
	return "+PONG\r\n"
end

testaux.case("Test 1: Basic Redis operations", function()
	local f<close> = realclient()
	local db = f.db
	local key = "silly:redis:" .. silly.genid()
	eq(table.pack(db:ping()), {true, "PONG", n = 2}, "PING result")
	eq(table.pack(db:set(key, "hello\0\r\nworld")), {true, "OK", n = 2}, "binary SET")
	eq(table.pack(db:get(key)), {true, "hello\0\r\nworld", n = 2}, "binary GET")
	eq(table.pack(db:exists(key)), {true, 1, n = 2}, "existing key")
	eq(table.pack(db:del(key)), {true, 1, n = 2}, "delete owned key")
	eq(table.pack(db:get(key)), {true, n = 2}, "missing key returns nil")
	eq(table.pack(db:lpush(key, "a", "b")), {true, 2, n = 2}, "list write")
	eq(table.pack(db:lrange(key, 0, -1)), {true, {"b", "a"}, n = 2}, "complete array")
	local ok, err = db:get(key)
	failure(ok, err, "wrong type")
	assert(tostring(err):find("WRONGTYPE", 1, true))
	assert(db:del(key))
	eq(table.pack(db:hmset(key, "name", "alice", "age", 25)), {true, "OK", n = 2}, "hash write")
	eq(table.pack(db:hmget(key, "name", "missing", "age")),
		{true, {[1] = "alice", [3] = "25"}, n = 2}, "nil array positions")
	assert(db:del(key))
end)

testaux.case("Test 2: Concurrent operations", function()
	local f<close> = realclient()
	local db = f.db
	local key = "silly:redis:" .. silly.genid()
	assert(db:set(key, 0))
	local workers = {}
	for i = 1, 1024 do
		workers[i] = fork(function()
			return db:incr(key)
		end)
	end
	local values = {}
	for i = 1, #workers do
		local ok, value = join(workers[i])
		eq(ok, true, "concurrent INCR succeeds")
		assert(not values[value], "duplicate INCR response")
		values[value] = true
	end
	for i = 1, 1024 do
		eq(values[i], true, "every increment is returned once")
	end
	eq(table.pack(db:get(key)), {true, "1024", n = 2}, "all increments executed")
	assert(db:del(key))
end)

testaux.case("Test 3: Pipeline operations", function()
	local f<close> = realclient()
	local db = f.db
	local key = "silly:redis:" .. silly.genid()
	local requests = {{"SET", key, "value"}, {"GET", key}, {"INCR", key}, {"DEL", key}, {"GET", key}}
	local results, err = db:pipeline(requests)
	assert(results, err)
	eq(err, nil, "command errors are not transport errors")
	eq(results[1], true, "SET succeeds")
	eq(results[2], "OK", "SET value")
	eq(results[3], true, "GET succeeds")
	eq(results[4], "value", "GET value")
	eq(results[5], false, "INCR fails on noninteger")
	assert(tostring(results[6]):find("ERR", 1, true))
	eq(results[7], true, "DEL after command error succeeds")
	eq(results[8], 1, "DEL result")
	eq(results[9], true, "missing GET succeeds")
	eq(results[10], nil, "last nil result retains its position")
	eq(table.pack(db:ping()), {true, "PONG", n = 2}, "pipeline drains every reply")
end)

testaux.case("Test 3.1: Empty pipeline", function()
	local f<close> = fixture(ping)
	local results, err = f.db:pipeline({})
	eq(results, {}, "empty results")
	eq(err, nil, "empty pipeline has no error")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "empty pipeline leaves framing intact")
end)

testaux.case("Test 4: Normal operation", function()
	local f<close> = fixture(function(cmd, args)
		eq(cmd, "ECHO", "method uppercases command")
		eq(args, {"ECHO", "binary\0\r\n", "", "123", "false"}, "request encoding")
		return "$9\r\nbinary\0\r\n\r\n"
	end)
	eq(table.pack(f.db:echo("binary\0\r\n", "", 123, false)),
		{true, "binary\0\r\n", n = 2}, "binary-safe reply")
end)

testaux.case("Test 4.1: Table arguments and generic call", function()
	local f<close> = fixture(function(cmd, args)
		eq(args, {"ECHO", "hello", "42"}, "table/call wire arguments")
		return "+OK\r\n"
	end)
	eq(table.pack(f.db:echo({"hello", 42})), {true, "OK", n = 2}, "table parameters")
	eq(table.pack(f.db:call("eChO", "hello", 42)), {true, "OK", n = 2}, "mixed-case call")
end)

testaux.case("Test 5: Disconnect during read", function()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			return false
		end
		return ping(cmd, args)
	end)
	local ok, err = f.db:ping()
	failure(ok, err, "disconnected command")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "next command reconnects")
	eq(f.server.connections, 2, "one replacement connection")
end)

testaux.case("Test 6: Partial response", function()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			assert(client:write("$5\r\nhel"))
			return false
		end
		return ping(cmd, args)
	end)
	local ok, err = f.db:ping()
	failure(ok, err, "truncated bulk string")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "partial response invalidates connection")
end)

testaux.case("Test 7: Concurrent requests with disconnect", function()
	local received = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client)
		eq(args, {"PING"}, "queued request")
		peer = client
		received:push(count)
	end)
	local workers = {}
	for i = 1, 8 do
		workers[i] = fork(function()
			return f.db:ping()
		end)
	end
	for i = 1, 8 do
		eq(await(received, "all requests reached peer"), i, "wire order")
	end
	assert(peer:write("+PONG\r\n+PONG\r\n"))
	peer:close()
	for i = 1, 8 do
		local ok, value = join(workers[i])
		if i <= 2 then
			eq({ok, value}, {true, "PONG"}, "completed response survives EOF")
		else
			failure(ok, value, "pending request " .. i)
		end
	end
end)

testaux.case("Test 8: Pipeline with disconnect", function()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 and count == 2 then
			return false
		end
		return ping(cmd, args)
	end)
	local result, err = f.db:pipeline({{"PING"}, {"PING"}, {"PING"}})
	eq(result, nil, "partial pipeline is discarded")
	assert(err)
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "reconnect after failed pipeline")
end)

testaux.case("Test 9: Server restart", function()
	local f<close> = fixture(ping)
	assert(f.db:ping())
	-- Model restart connection loss without rebinding a queued listener close.
	for peer in pairs(f.server.clients) do
		peer:close()
	end
	local ok, err = f.db:ping()
	failure(ok, err, "old connection")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "new connection")
	eq(f.server.connections, 2, "restart reconnects once")
end)

testaux.case("Test 10: Redis error response", function()
	local f<close> = fixture(function(cmd, args)
		if cmd == "BAD" then
			return "-ERR deliberate error\r\n"
		end
		return ping(cmd, args)
	end)
	eq(table.pack(f.db:bad()), {false, "ERR deliberate error", n = 2}, "Redis error value")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "command error keeps connection")
	eq(f.server.connections, 1, "command error does not reconnect")
end)

testaux.case("Test 11: Auto-reconnect with db selection", function()
	local selected = {}
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if count == 1 then
			eq(args, {"SELECT", "5"}, "SELECT precedes command on every connection")
			selected[connection] = true
			return "+OK\r\n"
		end
		assert(selected[connection])
		if connection == 1 then
			return false
		end
		return ping(cmd, args)
	end, {db = 5})
	local ok, err = f.db:ping()
	failure(ok, err, "first connection")
	assert(f.db:ping())
	eq(selected, {true, true}, "database is reselected")
end)

testaux.case("Test 12: Auto-reconnect with server restart and db selection", function()
	local f<close> = fixture(function(cmd, args, count)
		if count == 1 then
			eq(args, {"AUTH", "secret"}, "AUTH is first")
			return "+OK\r\n"
		elseif count == 2 then
			eq(args, {"SELECT", "11"}, "SELECT follows AUTH")
			return "+OK\r\n"
		end
		return ping(cmd, args)
	end, {auth = "secret", db = 11})
	assert(f.db:ping())
	for peer in pairs(f.server.clients) do
		peer:close()
	end
	local ok, err = f.db:ping()
	failure(ok, err, "restarted connection")
	assert(f.db:ping())
	eq(f.server.connections, 2, "AUTH and SELECT repeated on replacement")
end)

testaux.case("Test 13: Close wakes up blocked coroutine", function()
	local received = channel.new()
	local f<close> = fixture(function()
		received:push(true)
	end)
	local worker = fork(function()
		return f.db:ping()
	end)
	await(received, "peer received blocked request")
	f.db:close()
	local ok, err = join(worker)
	failure(ok, err, "blocked reader after close")
	eq(err, ECLOSED, "explicit close error")
end)

testaux.case("Test 14: Close wakes up readco and waitq", function()
	local received = channel.new()
	local f<close> = fixture(function()
		received:push(true)
	end)
	local workers = {}
	for i = 1, 6 do
		workers[i] = fork(function()
			return f.db:ping()
		end)
	end
	for _ = 1, #workers do
		await(received, "request entered shared connection")
	end
	f.db:close()
	f.db:close()
	for i = 1, #workers do
		local ok, err = join(workers[i])
		failure(ok, err, "reader/waiter after close")
		eq(err, ECLOSED, "close resolves each request once")
	end
end)

testaux.case("Test 15: Concurrent reconnect after disconnection", function()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			return false
		end
		return ping(cmd, args)
	end)
	local ok, err = f.db:ping()
	failure(ok, err, "first connection")
	local workers = {}
	for i = 1, 16 do
		workers[i] = fork(function()
			return f.db:ping()
		end)
	end
	for i = 1, #workers do
		eq(table.pack(join(workers[i])), {true, "PONG", n = 2}, "concurrent reconnect result")
	end
	eq(f.server.connections, 2, "concurrent requests share one reconnect")
end)

testaux.case("Test 16: Operations after close should fail and not reconnect", function()
	local f<close> = fixture(ping)
	assert(f.db:ping())
	f.db:close()
	local ok, err = f.db:ping()
	failure(ok, err, "command after close")
	eq(err, ECLOSED, "closed error")
	local result
	result, err = f.db:pipeline({{"PING"}})
	eq(result, nil, "pipeline after close fails")
	eq(err, ECLOSED, "pipeline closed error")
	eq(f.server.connections, 1, "closed client never reconnects")
end)

testaux.case("Test 17: Concurrent close and reconnect", function()
	local connecting = channel.new()
	local release = channel.new()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			return false
		end
		return ping(cmd, args)
	end)
	local ok, err = f.db:ping()
	failure(ok, err, "initial connection")
	await(f.server.accepted, "first connection accepted")
	local connect = tcp.connect
	tcp.connect = function(...)
		local sock, failure = connect(...)
		connecting:push(true)
		await(release, "release completed TCP connect")
		return sock, failure
	end
	local worker = fork(function()
		return f.db:ping()
	end)
	await(connecting, "reconnect yielded before returning")
	await(f.server.accepted, "replacement connection accepted")
	tcp.connect = connect
	f.db:close()
	release:push(true)
	ok, err = join(worker)
	failure(ok, err, "close during reconnect")
	eq(err, ECLOSED, "reconnect cannot reopen closed client")
end)

testaux.case("Test 18: Close during AUTH rejects queued connectors", function()
	local auth_seen = channel.new()
	local started = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client)
		if cmd == "AUTH" then
			peer = client
			auth_seen:push(true)
			return nil
		end
		return ping(cmd, args)
	end, {auth = "secret"})
	local workers = {fork(function()
		return f.db:ping()
	end)}
	await(auth_seen, "AUTH is pending")
	for i = 2, 5 do
		workers[i] = fork(function()
			started:push(true)
			return f.db:ping()
		end)
	end
	for _ = 2, 5 do
		await(started, "connector entered mutex wait")
	end
	f.db:close()
	-- Completing the handshake must not resurrect a closed client.
	peer:write("+OK\r\n")
	for i = 1, #workers do
		local ok, err = join(workers[i])
		failure(ok, err, "close during AUTH with queued connectors")
		eq(err, ECLOSED, "all connectors see closed")
	end
	eq(f.server.connections, 1, "queued connectors do not reconnect")
end)

local responses = {
	{"simple string", "+OK\r\n", {true, "OK", n = 2}},
	{"integer", ":-123\r\n", {true, -123, n = 2}},
	{"64-bit integer", ":9223372036854775807\r\n", {true, math.maxinteger, n = 2}},
	{"empty bulk", "$0\r\n\r\n", {true, "", n = 2}},
	{"null bulk", "$-1\r\n", {true, n = 2}},
	{"empty array", "*0\r\n", {true, {}, n = 2}},
	{"null array", "*-1\r\n", {true, n = 2}},
	{"nested array", "*3\r\n:1\r\n$-1\r\n*2\r\n+OK\r\n$0\r\n\r\n",
		{true, {[1] = 1, [3] = {"OK", ""}}, n = 2}},
	{"minimum integer", ":-9223372036854775808\r\n", {true, math.mininteger, n = 2}},
	{"explicit positive integer", ":+123\r\n", {true, 123, n = 2}},
}
for i, response in ipairs(responses) do
	testaux.case("Test 19." .. i .. ": RESP2 " .. response[1], function()
		local f<close> = fixture(function()
			return response[2]
		end)
		eq(table.pack(f.db:ping()), response[3], "literal wire fixture")
	end)
end

testaux.case("Test 19.11: Maximum supported array nesting", function()
	local f<close> = fixture(function()
		return string.rep("*1\r\n", 128) .. "+OK\r\n"
	end)
	local ok, result = f.db:ping()
	eq(ok, true, "128 array levels are supported")
	for _ = 1, 128 do
		assert(type(result) == "table" and #result == 1)
		result = result[1]
	end
	eq(result, "OK", "deepest scalar is preserved")
end)

testaux.case("Test 20: Command write failure invalidates connection", function()
	local f<close> = fixture(ping)
	assert(f.db:ping())
	f.db.sock:close()
	local ok, err = f.db:ping()
	failure(ok, err, "transport write failure")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "command reconnects after write failure")
	eq(f.server.connections, 2, "write failure replaces connection")
end)

testaux.case("Test 21: Pipeline write failure invalidates connection", function()
	local f<close> = fixture(ping)
	assert(f.db:ping())
	f.db.sock:close()
	local result, err = f.db:pipeline({{"PING"}})
	eq(result, nil, "failed write has no results")
	assert(err)
	eq(table.pack(f.db:pipeline({{"PING"}})), {{true, "PONG"}, n = 2}, "pipeline reconnects")
	eq(f.server.connections, 2, "failed pipeline replaces connection")
end)

testaux.case("Test 22: Failed write during reader handoff", function()
	local received = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			peer = client
			received:push(true)
			return nil
		end
		return ping(cmd, args)
	end)
	local first = fork(function()
		assert(f.db:ping())
		f.db.sock:close()
		local ok, err = f.db:ping()
		failure(ok, err, "write fails after granting next reader")
		return f.db:ping()
	end)
	await(received, "first request")
	local second = fork(function()
		return f.db:ping()
	end)
	await(received, "queued request")
	assert(peer:write("+PONG\r\n"))
	local ok, err = join(second)
	failure(ok, err, "granted reader observes connection failure")
	eq(table.pack(join(first)), {true, "PONG", n = 2}, "old reader cannot clear replacement")
end)

local malformed = {
	{"unknown type", "?bad\r\n"},
	{"noninteger", ":nope\r\n"},
	{"bad line ending", "+OK\n"},
	{"nonnumeric bulk length", "$nope\r\n"},
	{"negative bulk length", "$-2\r\n"},
	{"fractional bulk length", "$1.5\r\n"},
	{"oversized bulk length", "$2147483647\r\n"},
	{"bulk terminator", "$3\r\nabcXX"},
	{"nonnumeric array length", "*nope\r\n"},
	{"negative array length", "*-2\r\n"},
	{"fractional array length", "*1.5\r\n"},
	{"nesting limit", string.rep("*1\r\n", 129) .. "+OK\r\n"},
	{"integer overflow", ":9223372036854775808\r\n"},
	{"integer underflow", ":-9223372036854775809\r\n"},
	{"simple string interior CR", "+bad\rvalue\r\n"},
	{"error interior CR", "-ERR bad\rvalue\r\n"},
	{"first oversized bulk length", "$2147483646\r\n"},
}
for i, response in ipairs(malformed) do
	testaux.case("Test 23." .. i .. ": Reject " .. response[1], function()
		local received = channel.new()
		local peer
		local f<close> = fixture(function(cmd, args, count, client, connection)
			if connection == 1 then
				peer = client
				received:push(true)
				return nil
			end
			return ping(cmd, args)
		end)
		local first = fork(function()
			return f.db:ping()
		end)
		await(received, "first command")
		local second = fork(function()
			return f.db:ping()
		end)
		await(received, "queued command")
		assert(peer:write(response[2]))
		local ok, err = join(first)
		failure(ok, err, "malformed response")
		ok, err = join(second)
		failure(ok, err, "malformed response releases waiter")
		eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "protocol failure permits reconnect")
	end)
end

local unsupported = {
	{"SUBSCRIBE", "a", "b"}, {"PSUBSCRIBE", "*"}, {"SSUBSCRIBE", "a"},
	{"UNSUBSCRIBE", "a", "b"}, {"PUNSUBSCRIBE"}, {"SUNSUBSCRIBE"},
	{"MONITOR"}, {"HELLO", 3}, {"CLIENT", "REPLY", "OFF"}, {"CLIENT", "REPLY", "SKIP"},
}
for i, request in ipairs(unsupported) do
	testaux.case("Test 24." .. i .. ": Reject unsupported " .. table.concat(request, " "), function()
		local f<close> = fixture(ping)
		local ok, err = f.db:call(request[1], table.unpack(request, 2))
		failure(ok, err, "unsupported connection mode")
		eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "rejected command does not change protocol")
	end)
end

testaux.case("Test 25: Pipeline validates every command before sending", function()
	local f<close> = fixture(ping)
	local result, err = f.db:pipeline({{"SET", "must-not-run", "value"}, {"SUBSCRIBE", "a", "b"}})
	eq(result, nil, "unsupported batch fails")
	assert(err)
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "no command from rejected batch was sent")
end)

testaux.case("Test 26: Mixed commands and pipelines keep response ownership", function()
	local f<close> = fixture(function(cmd, args)
		eq(cmd, "ECHO", "mixed requests use ECHO")
		return "$" .. #args[2] .. "\r\n" .. args[2] .. "\r\n"
	end)
	local workers = {}
	for i = 1, 64 do
		workers[i] = fork(function()
			local value = tostring(i)
			if i % 2 == 0 then
				local results, err = f.db:pipeline({{"ECHO", value}, {"ECHO", value .. "b"}})
				assert(results, err)
				eq(results, {true, value, true, value .. "b"}, "pipeline owns contiguous replies")
			else
				eq(table.pack(f.db:echo(value)), {true, value, n = 2}, "command owns its reply")
			end
		end)
	end
	for i = 1, #workers do
		join(workers[i])
	end
	eq(f.server.connections, 1, "mixed requests share one connection")
end)

for i, command in ipairs({"AUTH", "SELECT"}) do
	testaux.case("Test 27." .. i .. ": Failed " .. command .. " closes handshake socket", function()
		local f<close> = fixture(function(cmd, args)
			eq(cmd, command, "failed handshake sends no business command")
			return "-ERR rejected handshake\r\n"
		end, command == "AUTH" and {auth = "bad"} or {db = 99})
		eq(table.pack(f.db:ping()), {false, "ERR rejected handshake", n = 2}, "handshake error")
		eq(table.pack(f.db:ping()), {false, "ERR rejected handshake", n = 2}, "failed handshake retries cleanly")
		eq(f.server.connections, 2, "each attempt gets a fresh socket")
	end)
end

testaux.case("Test 28: Close during SELECT wakes the handshake", function()
	local received = channel.new()
	local f<close> = fixture(function(cmd, args)
		eq(args, {"SELECT", "7"}, "SELECT is pending")
		received:push(true)
	end, {db = 7})
	local worker = fork(function()
		return f.db:ping()
	end)
	await(received, "SELECT reached peer")
	f.db:close()
	local ok, err = join(worker)
	failure(ok, err, "close cancels SELECT read")
	eq(err, ECLOSED, "SELECT close error")
end)

testaux.case("Test 29: Fragmented bulk reply keeps queued command aligned", function()
	local body_read = channel.new()
	local received = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client)
		peer = client
		received:push(count)
		if count == 1 then
			return "$5\r\nhe"
		end
	end)
	local connect = tcp.connect
	tcp.connect = function(...)
		local sock, err = connect(...)
		assert(sock, err)
		local read = sock.read
		sock.read = function(self, n, ...)
			if n == 7 then
				body_read:push(true)
			end
			return read(self, n, ...)
		end
		return sock
	end
	local first = fork(function()
		return f.db:ping()
	end)
	await(body_read, "reader awaits remaining bulk bytes")
	tcp.connect = connect
	eq(await(received, "first command"), 1, "first request")
	local second = fork(function()
		return f.db:ping()
	end)
	eq(await(received, "queued command"), 2, "second request")
	assert(peer:write("llo\r\n+PONG\r\n"))
	eq(table.pack(join(first)), {true, "hello", n = 2}, "fragmented response")
	eq(table.pack(join(second)), {true, "PONG", n = 2}, "following response")
end)

testaux.case("Test 30: Pipeline preserves nil and error positions", function()
	local replies = {"$-1\r\n", "$1\r\nx\r\n", "-ERR failed\r\n", "+PONG\r\n"}
	local f<close> = fixture(function(cmd, args, count)
		return replies[count] or ping(cmd, args)
	end)
	local requests = {{"GET", "missing"}, {"GET", "present"}, {"BAD"}, {"PING"}}
	local results, err = f.db:pipeline(requests)
	assert(results, err)
	eq(results, {[1] = true, [3] = true, [4] = "x", [5] = false,
		[6] = "ERR failed", [7] = true, [8] = "PONG"}, "flat result positions")
	eq(requests, {{"GET", "missing"}, {"GET", "present"}, {"BAD"}, {"PING"}}, "requests unchanged")
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "all pipeline responses consumed")
end)

testaux.case("Test 31: Malformed pipeline response releases queued command", function()
	local received = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			peer = client
			received:push(count)
			return nil
		end
		return ping(cmd, args)
	end)
	local first = fork(function()
		return f.db:pipeline({{"PING"}, {"PING"}})
	end)
	await(received, "pipeline command one")
	await(received, "pipeline command two")
	local second = fork(function()
		return f.db:ping()
	end)
	await(received, "queued command")
	assert(peer:write("+PONG\r\n$bad\r\n"))
	local result, err = join(first)
	eq(result, nil, "malformed pipeline discards completed prefix")
	assert(err)
	local ok
	ok, err = join(second)
	failure(ok, err, "queued command after protocol error")
	assert(f.db:ping())
end)

testaux.case("Test 32: Write failure releases active reader and waiters", function()
	local received = channel.new()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			received:push(true)
			return nil
		end
		return ping(cmd, args)
	end)
	local workers = {}
	for i = 1, 2 do
		workers[i] = fork(function()
			return f.db:ping()
		end)
		await(received, "pending request")
	end
	f.db.sock:close()
	local ok, err = f.db:ping()
	failure(ok, err, "write failure outside reader")
	for i = 1, 2 do
		ok, err = join(workers[i])
		failure(ok, err, "failed transport releases pending request")
	end
	eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "fresh connection after cleanup")
end)

testaux.case("Test 32.1: Pipeline write failure releases active reader and waiters", function()
	local received = channel.new()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			received:push(true)
			return nil
		end
		return ping(cmd, args)
	end)
	local workers = {}
	for i = 1, 2 do
		workers[i] = fork(function()
			return f.db:ping()
		end)
		await(received, "pending request before pipeline write failure")
	end
	local sock = f.db.sock
	local write = sock.write
	-- Fail before a transport close event can independently release the reader.
	sock.write = function(self)
		self.write = write
		return false, ECLOSED
	end
	local results, err = f.db:pipeline({{"PING"}, {"PING"}})
	eq(results, nil, "failed pipeline write has no results")
	eq(err, ECLOSED, "pipeline reports write failure")
	for i = 1, #workers do
		local ok
		ok, err = join(workers[i])
		failure(ok, err, "pipeline write failure releases pending request")
		eq(err, ECLOSED, "pending request receives connection error")
	end
	eq(table.pack(f.db:pipeline({{"PING"}})), {{true, "PONG"}, n = 2},
		"pipeline reconnects after releasing readers")
	eq(f.server.connections, 2, "failed pipeline replaces the shared connection once")
end)

for i, command in ipairs({"AUTH", "SELECT"}) do
	for j, malformed in ipairs({false, "?invalid\r\n"}) do
		testaux.case("Test 33." .. (2 * i + j - 2) .. ": " .. command ..
			(j == 1 and " EOF" or " protocol error"), function()
			local f<close> = fixture(function(cmd, args, count, client, connection)
				if connection == 1 then
					eq(cmd, command, "handshake is the failing command")
					return malformed
				end
				if count == 1 then
					return "+OK\r\n"
				end
				return ping(cmd, args)
			end, command == "AUTH" and {auth = "secret"} or {db = 7})
			local ok, err = f.db:ping()
			failure(ok, err, "failed handshake")
			eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "handshake retries on a new socket")
		end)
	end
end

testaux.case("Test 34: RESP2 HELLO and CLIENT REPLY ON remain supported", function()
	local f<close> = fixture(function(cmd, args, count)
		if count == 1 then
			eq(args, {"HELLO", "2"}, "HELLO keeps RESP2")
			return "*2\r\n+proto\r\n:2\r\n"
		elseif count == 2 then
			eq(args, {"CLIENT", "REPLY", "ON"}, "reply ON is safe")
			return "+OK\r\n"
		end
		return ping(cmd, args)
	end)
	eq(table.pack(f.db:hello(2)), {true, {"proto", 2}, n = 2}, "RESP2 HELLO")
	eq(table.pack(f.db:pipeline({{"client", "REPLY", "ON"}, {"ping"}})),
		{{true, "OK", true, "PONG"}, n = 2}, "safe mode commands and lowercase batch names")
end)

testaux.case("Test 35: Close before first use rejects command and empty pipeline", function()
	local f<close> = fixture(ping)
	f.db:close()
	local ok, err = f.db:ping()
	failure(ok, err, "unused closed client")
	eq(err, ECLOSED, "unused client closed error")
	local result
	result, err = f.db:pipeline({})
	eq(result, nil, "empty pipeline respects closed state")
	eq(err, ECLOSED, "empty pipeline closed error")
end)

for i, cause in ipairs({"close", "EOF", "protocol error"}) do
	testaux.case("Test 36." .. i .. ": Queued pipeline fails on " .. cause, function()
		local received = channel.new()
		local peer
		local f<close> = fixture(function(cmd, args, count, client, connection)
			if connection == 1 then
				eq(args, {"PING"}, "pending command wire arguments")
				peer = client
				received:push(count)
				return nil
			end
			return ping(cmd, args)
		end)
		local reader = fork(function()
			return f.db:ping()
		end)
		eq(await(received, "active reader request"), 1, "active reader owns first reply")
		local pipeline = fork(function()
			return f.db:pipeline({{"PING"}, {"PING"}})
		end)
		eq(await(received, "queued pipeline command one"), 2, "first pipeline command")
		eq(await(received, "queued pipeline command two"), 3, "second pipeline command")
		if cause == "close" then
			f.db:close()
		elseif cause == "EOF" then
			peer:close()
		else
			assert(peer:write("?invalid\r\n"))
		end
		local ok, err = join(reader)
		failure(ok, err, "active reader after " .. cause)
		local results
		results, err = join(pipeline)
		eq(results, nil, "queued pipeline has no results after " .. cause)
		assert(err, "queued pipeline returns connection failure")
		if cause == "close" then
			eq(err, ECLOSED, "queued pipeline explicit close error")
			ok, err = f.db:ping()
			failure(ok, err, "closed client stays closed")
			eq(f.server.connections, 1, "close does not reconnect")
		else
			eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "reconnect after queued pipeline failure")
			eq(f.server.connections, 2, "failed connection is replaced once")
		end
	end)
end

testaux.case("Test 36.4: Close after granting a queued pipeline the read turn", function()
	local received = channel.new()
	local peer
	local f<close> = fixture(function(cmd, args, count, client)
		peer = client
		received:push(count)
	end)
	local reader = fork(function()
		eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "first reader response")
		f.db:close()
		return true
	end)
	await(received, "active reader request")
	local pipeline = fork(function()
		return f.db:pipeline({{"PING"}, {"PING"}})
	end)
	await(received, "pipeline command one")
	await(received, "pipeline command two")
	assert(peer:write("+PONG\r\n"))
	eq(join(reader), true, "reader closes after handing off the read turn")
	local results, err = join(pipeline)
	eq(results, nil, "granted pipeline returns no results after close")
	eq(err, ECLOSED, "granted pipeline sees close without a duplicate wakeup")
end)

for i, pipeline_first in ipairs({false, true}) do
	testaux.case("Test 37." .. i .. ": Failed TCP connect releases queued callers for " ..
		(pipeline_first and "pipeline" or "command"), function()
		local f<close> = fixture(ping)
		local connecting = channel.new()
		local release = channel.new()
		local queued = channel.new()
		local attempts = 0
		local connect = tcp.connect
		local restore<close> = setmetatable({}, {__close = function()
			tcp.connect = connect
		end})
		tcp.connect = function(addr, ...)
			if addr == f.server.addr then
				attempts = attempts + 1
				if attempts == 1 then
					connecting:push(true)
					await(release, "release failed TCP connect")
					return nil, ECONNREFUSED
				end
			end
			return connect(addr, ...)
		end
		local first = fork(function()
			if pipeline_first then
				return f.db:pipeline({{"PING"}})
			end
			return f.db:ping()
		end)
		await(connecting, "first TCP connect holds connection lock")
		local command = fork(function()
			queued:push(true)
			return f.db:ping()
		end)
		local pipeline = fork(function()
			queued:push(true)
			return f.db:pipeline({{"PING"}})
		end)
		await(queued, "command entered connection wait")
		await(queued, "pipeline entered connection wait")
		release:push(true)
		local result, err = join(first)
		if pipeline_first then
			eq(result, nil, "failed pipeline connect returns no results")
		else
			failure(result, err, "failed command connect")
		end
		eq(err, ECONNREFUSED, "TCP connect error propagates")
		eq(table.pack(join(command)), {true, "PONG", n = 2}, "queued command retries after connect failure")
		eq(table.pack(join(pipeline)), {{true, "PONG"}, n = 2}, "queued pipeline shares replacement")
		eq(attempts, 2, "one failed attempt followed by one shared connection")
		eq(f.server.connections, 1, "only the successful TCP connection reaches the peer")
	end)
end

for i, handshake in ipairs({"AUTH", "SELECT"}) do
	testaux.case("Test 38." .. i .. ": Failed " .. handshake .. " write closes socket before retry", function()
		local f<close> = fixture(function(cmd, args, count, client, connection)
			eq(connection, 2, "failed handshake write sends no command to first peer")
			if count == 1 then
				local argument = handshake == "AUTH" and "secret" or "7"
				eq(args, {handshake, argument}, "retry repeats handshake before business command")
				return "+OK\r\n"
			end
			return ping(cmd, args)
		end, handshake == "AUTH" and {auth = "secret"} or {db = 7})
		local connect = tcp.connect
		local failed = false
		local failed_sock
		local restore<close> = setmetatable({}, {__close = function()
			tcp.connect = connect
		end})
		tcp.connect = function(addr, ...)
			local sock, err = connect(addr, ...)
			if sock and addr == f.server.addr and not failed then
				failed = true
				failed_sock = sock
				local write = sock.write
				sock.write = function(self)
					self.write = write
					return false, ECLOSED
				end
			end
			return sock, err
		end
		local ok, err = f.db:ping()
		failure(ok, err, "handshake write failure")
		eq(err, ECLOSED, "handshake write error propagates")
		await(f.server.accepted, "failed handshake connection accepted")
		await(f.server.done, "peer observes failed handshake socket EOF before fixture cleanup")
		eq(failed_sock.fd, nil, "failed handshake explicitly closes transport before GC")
		eq(f.server.active, 0, "failed handshake leaves no peer reader")
		eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "clean handshake retry")
		eq(f.server.connections, 2, "retry opens a fresh connection")
	end)
end

testaux.case("Test 39: Clients at one endpoint have independent handshake locks", function()
	local auth_seen = channel.new()
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if cmd == "AUTH" then
			eq(args, {"AUTH", "secret"}, "both clients authenticate independently")
			if connection == 1 then
				auth_seen:push(true)
				return nil
			end
			return "+OK\r\n"
		end
		eq(connection, 2, "only independent client sends business commands")
		return ping(cmd, args)
	end, {auth = "secret"})
	local other = redis.new {addr = f.server.addr, auth = "secret"}
	f.clients[#f.clients + 1] = other
	local blocked = fork(function()
		return f.db:ping()
	end)
	await(auth_seen, "first client waits for AUTH reply")
	local independent = fork(function()
		return other:ping()
	end)
	eq(table.pack(join(independent)), {true, "PONG", n = 2}, "other client bypasses blocked handshake")
	f.db:close()
	local ok, err = join(blocked)
	failure(ok, err, "first client closes during AUTH")
	eq(err, ECLOSED, "first client receives close error")
	await(f.server.done, "first client's peer reader completed")
	eq(table.pack(other:pipeline({{"PING"}, {"PING"}})),
		{{true, "PONG", true, "PONG"}, n = 2}, "closing first client preserves second connection")
	eq(f.server.connections, 2, "independent client does not reconnect")
end)

testaux.case("Test 39.1: Closing one client preserves another client's readers", function()
	local received = channel.new()
	local other_received = channel.new()
	local other_peer
	local f<close> = fixture(function(cmd, args, count, client, connection)
		if connection == 1 then
			received:push(true)
			return nil
		end
		if count == 1 then
			other_peer = client
			other_received:push(true)
			return nil
		end
		return ping(cmd, args)
	end)
	local other = redis.new {addr = f.server.addr}
	f.clients[#f.clients + 1] = other
	local pending = {}
	for i = 1, 2 do
		pending[i] = fork(function()
			return f.db:ping()
		end)
		await(received, "first client's pending request")
	end
	local independent = fork(function()
		return other:ping()
	end)
	await(other_received, "second client has a pending reader")
	f.db:close()
	for i = 1, #pending do
		local ok, err = join(pending[i])
		failure(ok, err, "first client's pending request closes")
		eq(err, ECLOSED, "first client's waiters receive close error")
	end
	await(f.server.done, "first client's peer reader completed")
	assert(other_peer:write("+PONG\r\n"))
	eq(table.pack(join(independent)), {true, "PONG", n = 2}, "second client's pending reader survives close")
	eq(table.pack(other:ping()), {true, "PONG", n = 2}, "second client remains usable")
	eq(f.server.connections, 2, "second client keeps its original connection")
end)

for i, warm in ipairs({false, true}) do
	testaux.case("Test 40." .. i .. ": Empty command rejects entire " ..
		(warm and "connected" or "unconnected") .. " pipeline", function()
		local f<close> = fixture(ping)
		if warm then
			assert(f.db:ping())
		end
		local requests = {{"SET", "must-not-run", "value"}, {}}
		local results, err = f.db:pipeline(requests)
		eq(results, nil, "empty command rejects batch")
		assert(err, "empty command returns an error")
		eq(requests, {{"SET", "must-not-run", "value"}, {}}, "invalid batch is unchanged")
		eq(table.pack(f.db:ping()), {true, "PONG", n = 2}, "no preceding SET was sent")
		eq(f.server.connections, 1, "invalid batch does not poison or replace connection")
	end)
end
