local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local redis = require "silly.store.redis"
local testaux = require "test.testaux"
local fakeredis = require "test.fake_redis_server"

local function asserteq(cmd, expect_success, expect_value, success, value)
	if type(value) == "table" then
		value = value[1]
	end
	print(string.format('====%s:%s', cmd, success and "success" or "fail"))
	testaux.asserteq(success, expect_success, cmd)
	if success then	--Redis 3.2 has different error message
		testaux.asserteq(value, expect_value, cmd)
	end
	collectgarbage("collect")
end

-- Create a single fake Redis server instance for all tests
local fake_server = fakeredis.new(16379)
fake_server:start()

-- Test 1: Basic Redis operations (original testbasic)
testaux.case("Test 1: Basic Redis operations", function()
	print("-----Test 1: Basic Redis operations-----")
	local db = redis.new {
		addr = "127.0.0.1:6379",
		db = 11,
	}
	db:flushdb()
	asserteq("PING", true, "PONG", db:ping())
	asserteq("SET foo bar", true, "OK", db:set("foo", "bar"))
	asserteq("GET foo", true, "bar", db:get("foo"))
	asserteq("KEYS fo*", true, "foo", db:keys("fo*"))
	asserteq("EXISTS foo", true, 1, db:exists("foo"))
	asserteq("EXISTS hello", true, 0, db:exists("hello"))
	asserteq("DEL foo", true, 1, db:del("foo"))
	asserteq("EXISTS foo", true, 0, db:exists("foo"))
	asserteq("DEL foo", true, 0, db:del("foo"))
	asserteq("SET foo 1", true, "OK", db:set("foo", 1))
	asserteq("TYPE foo", true, "string", db:type("foo"))
	asserteq("TYPE bar", true, "none", db:type("bar"))
	asserteq("LPUSH bar 1", true, 1, db:lpush("bar", 1))
	asserteq("TYPE bar", true, "list", db:type("bar"))
	asserteq("STRLEN bar", false, "ERR Operation against a key holding the wrong kind of value", db:strlen("bar"))
	asserteq("HMSET hash k1 v1 k2 v2", true, "OK", db:hmset("hash", "k1", "v1", "k2", "v2"))
	asserteq("HGET hash k1", true, "v1", db:hget("hash", "k1"))
	asserteq("HGETALL hash", true, "k1", db:hgetall("hash"))
	db:close()
	testaux.success("Test 1: Basic Redis operations passed")
end)

-- Test 2: Concurrent operations (original concurrent test)
testaux.case("Test 2: Concurrent operations", function()
	print("-----Test 2: Concurrent operations (1024 requests)-----")
	local db = redis.new {
		addr = "127.0.0.1:6379",
		db = 11,
	}
	local testcount = 1024
	local finish = 0
	local idx = 0

	db:del("foo")
	local wg = waitgroup.new()
	for i = 1, testcount do
		wg:fork(function()
			idx = idx + 1
			local id = idx
			local ok, get = db:incr("foo")
			time.sleep(math.random(1, 100))
			testaux.asserteq(ok, true, "INCR foo")
			testaux.asserteq(id, get, "INCR foo")
			finish = finish + 1
		end)
		time.sleep(math.random(0, 10))
	end
	wg:wait()
	db:close()
	testaux.success("Test 2: Concurrent operations passed")
end)

-- Test 3: Pipeline operations with return value validation
testaux.case("Test 3: Pipeline operations", function()
	print("-----Test 3: Pipeline operations-----")
	local db = redis.new {
		addr = "127.0.0.1:6379",
		db = 11,
	}

	-- Test 3.1: Basic pipeline
	db:flushdb()
	local results, err = db:pipeline({
		{"SET", "key1", "value1"},
		{"SET", "key2", "value2"},
		{"GET", "key1"},
		{"GET", "key2"},
	})
	testaux.assertneq(results, nil, "Test 3.1: Pipeline should succeed")
	testaux.asserteq(err, nil, "Test 3.1: Pipeline should not return error")
	assert(results)
	-- Verify pipeline return format: {success1, result1, success2, result2, ...}
	testaux.asserteq(results[1], true, "Test 3.2: First SET should succeed")
	testaux.asserteq(results[2], "OK", "Test 3.2: First SET should return OK")
	testaux.asserteq(results[3], true, "Test 3.3: Second SET should succeed")
	testaux.asserteq(results[4], "OK", "Test 3.3: Second SET should return OK")
	testaux.asserteq(results[5], true, "Test 3.4: First GET should succeed")
	testaux.asserteq(results[6], "value1", "Test 3.4: First GET should return value1")
	testaux.asserteq(results[7], true, "Test 3.5: Second GET should succeed")
	testaux.asserteq(results[8], "value2", "Test 3.5: Second GET should return value2")

	-- Test 3.6: Pipeline with error (wrong type operation)
	db:lpush("list_key", "item1")
	results, err = db:pipeline({
		{"GET", "key1"},
		{"STRLEN", "list_key"},  -- This will fail
		{"GET", "key2"},
	})
	testaux.assertneq(results, nil, "Test 3.6: Pipeline should return even with error")
	assert(results)
	testaux.asserteq(results[1], true, "Test 3.6: First command should succeed")
	testaux.asserteq(results[2], "value1", "Test 3.6: First command should return value")
	testaux.asserteq(results[3], false, "Test 3.6: Second command should fail")
	testaux.assertneq(results[4], nil, "Test 3.6: Error message should exist")
	testaux.asserteq(results[5], true, "Test 3.6: Third command should succeed")
	testaux.asserteq(results[6], "value2", "Test 3.6: Third command should return value")

	-- Test 3.7: Empty pipeline
	results, err = db:pipeline({})
	testaux.assertneq(results, nil, "Test 3.7: Empty pipeline should succeed")
	testaux.asserteq(#results, 0, "Test 3.7: Empty pipeline should return empty results")

	db:close()
	testaux.success("Test 3: Pipeline operations passed")
end)

-- Test 4: Normal operation (resilience)
testaux.case("Test 4: Normal operation", function()
	print("-----Test 4: Normal operation (with fake server)-----")
	-- Reset to default handler (no custom logic needed)
	fake_server:set_handler(nil)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	local ok, val = db:ping()
	testaux.asserteq(ok, true, "Test 4.1: PING should succeed")
	testaux.asserteq(val, "PONG", "Test 4.1: PING response")

	ok, val = db:set("key", "value")
	testaux.asserteq(ok, true, "Test 4.2: SET should succeed")

	ok, val = db:get("key")
	testaux.asserteq(ok, true, "Test 4.3: GET should succeed")

	db:close()
	testaux.success("Test 4: Normal operation passed")
end)

-- Test 5: Disconnect during read
testaux.case("Test 5: Disconnect during read", function()
	print("-----Test 5: Disconnect during read-----")

	-- Disconnect after second command
	local disconnected = false
	fake_server:set_handler(function(cmd, args, command_count)
		if cmd == "PING" then
			return "+PONG\r\n"
		elseif cmd == "SET" and not disconnected then
			disconnected = true
			return false  -- Disconnect on SET
		elseif cmd == "SET" then
			return "+OK\r\n"
		end
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First command should succeed
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 5.1: First PING should succeed")

	-- Second command should fail (server disconnects)
	local ok2, err2 = db:set("key", "value")
	testaux.asserteq(ok2, false, "Test 5.2: Second command should fail after disconnect")
	print("Test 5.2: Error message:", err2)

	-- Third command should reconnect and succeed
	local ok3, val3 = db:ping()
	testaux.asserteq(ok3, true, "Test 5.3: Should reconnect and succeed")

	db:close()
	testaux.success("Test 5: Disconnect during read passed")
end)

-- Test 6: Partial response (connection breaks mid-response)
testaux.case("Test 6: Partial response", function()
	print("-----Test 6: Partial response-----")

	local partial_sent = false
	fake_server:set_handler(function(cmd, args, command_count, client)
		if cmd == "PING" and command_count == 1 then
			return "+PONG\r\n"
		elseif cmd == "PING" and command_count == 2 and not partial_sent then
			-- Send partial response then disconnect
			partial_sent = true
			client:write("+PO")  -- Only send first 3 bytes
			return false  -- Then disconnect
		elseif cmd == "PING" then
			return "+PONG\r\n"
		end
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First command succeeds
	local ok1 = db:ping()
	testaux.asserteq(ok1, true, "Test 6.1: First PING should succeed")

	-- Second command gets partial response and should fail
	local ok2, err2 = db:ping()
	testaux.asserteq(ok2, false, "Test 6.2: Should fail on partial response")
	print("Test 6.2: Partial response error:", err2)

	-- Next command should reconnect
	local ok3, val3 = db:ping()
	testaux.asserteq(ok3, true, "Test 6.3: Should reconnect after partial response")

	db:close()
	testaux.success("Test 6: Partial response passed")
end)

-- Test 7: Concurrent requests with disconnect
testaux.case("Test 7: Concurrent requests with disconnect", function()
	print("-----Test 7: Concurrent requests with disconnect-----")

	local total_commands = 0
	local disconnected = false
	fake_server:set_handler(function(cmd, args, command_count, client)
		total_commands = total_commands + 1
		if total_commands > 5 and not disconnected then
			-- Disconnect after 5 commands (once)
			disconnected = true
			return false
		end
		if cmd == "INCR" then
			return ":" .. total_commands .. "\r\n"
		end
	end)


	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	local results = {}
	local success_count = 0
	local fail_count = 0

	-- Launch 10 concurrent requests
	for i = 1, 10 do
		task.fork(function()
			local ok, val = db:incr("counter")
			results[i] = ok
			if ok then
				success_count = success_count + 1
				print("Test 7: Request " .. i .. " succeeded: " .. val)
			else
				fail_count = fail_count + 1
				print("Test 7: Request " .. i .. " failed: " .. (val or "nil"))
			end
		end)
		time.sleep(10)
	end

	-- Wait for all to complete
	time.sleep(1000)

	print("Test 7: Success:", success_count, "Failed:", fail_count)
	testaux.asserteq(success_count > 0, true, "Test 7.1: Some requests should succeed")
	testaux.asserteq(fail_count > 0, true, "Test 7.2: Some requests should fail after disconnect")

	db:close()
	testaux.success("Test 7: Concurrent disconnect passed")
end)

-- Test 8: Pipeline with disconnect
testaux.case("Test 8: Pipeline with disconnect", function()
	print("-----Test 8: Pipeline with disconnect-----")

	local cmd_count = 0
	local disconnected = false
	fake_server:set_handler(function(cmd, args, count, client)
		cmd_count = cmd_count + 1
		if cmd_count > 3 and not disconnected then
			-- Disconnect after 3 commands (once)
			disconnected = true
			return false
		end
		if cmd == "PING" then return "+PONG\r\n"
		elseif cmd == "SET" then return "+OK\r\n"
		end
	end)


	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- Send 5 commands in pipeline
	local results, err = db:pipeline({
		{"PING"},
		{"SET", "k1", "v1"},
		{"SET", "k2", "v2"},
		{"SET", "k3", "v3"},
		{"SET", "k4", "v4"},
	})

	-- Pipeline should fail
	testaux.asserteq(results, nil, "Test 8.1: Pipeline should fail on disconnect")
	print("Test 8.1: Pipeline error:", err)

	-- Next request should reconnect
	local ok, val = db:ping()
	testaux.asserteq(ok, true, "Test 8.2: Should reconnect after pipeline failure")

	db:close()
	testaux.success("Test 8: Pipeline disconnect passed")
end)

-- Test 9: Server restart
testaux.case("Test 9: Server restart", function()
	print("-----Test 9: Server restart-----")
	-- Use default behavior

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First request succeeds
	local ok1 = db:ping()
	testaux.asserteq(ok1, true, "Test 9.1: Initial PING should succeed")

	-- Simulate server restart
	print("Test 9: Simulating server restart...")
	fake_server:stop()
	time.sleep(200)
	fake_server:start()
	time.sleep(200)

	-- Next request should fail (old connection broken)
	local ok2, err2 = db:ping()
	testaux.asserteq(ok2, false, "Test 9.2: Should fail on broken connection")

	-- Then should reconnect
	local ok3 = db:ping()
	testaux.asserteq(ok3, true, "Test 9.3: Should reconnect after server restart")

	db:close()
	testaux.success("Test 9: Server restart passed")
end)

-- Test 10: Redis error response (-ERR)
testaux.case("Test 10: Redis error response", function()
	print("-----Test 10: Redis error response-----")

	fake_server:set_handler(function(cmd, args, count, client)
		if cmd == "PING" then
			return "+PONG\r\n"
		elseif cmd == "INVALIDCMD" then
			return "-ERR unknown command 'INVALIDCMD'\r\n"
		end
	end)


	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- PING should succeed
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 10.1: PING should succeed")
	testaux.asserteq(val1, "PONG", "Test 10.1: PING response")

	-- Invalid command should return Redis error
	local ok2, err2 = db:call("INVALIDCMD", "arg1")
	testaux.asserteq(ok2, false, "Test 10.2: Invalid command should return error")
	testaux.asserteq(type(err2), "string", "Test 10.2: Error should be a string")
	print("Test 10.2: Redis error message:", err2)

	-- Connection should still work after error
	local ok3, val3 = db:ping()
	testaux.asserteq(ok3, true, "Test 10.3: PING should succeed after error response")
	testaux.asserteq(val3, "PONG", "Test 10.3: PING response after error")

	db:close()
	testaux.success("Test 10: Redis error response passed")
end)

-- Test 11: Auto-reconnect with db selection
testaux.case("Test 11: Auto-reconnect with db selection", function()
	print("-----Test 11: Auto-reconnect with db selection-----")

	local disconnected = false
	fake_server:set_handler(function(cmd, args, count, client)
		if cmd == "SELECT" then return "+OK\r\n"
		elseif cmd == "PING" then return "+PONG\r\n"
		elseif cmd == "SET" and not disconnected then
			disconnected = true
			return false  -- Disconnect on first SET
		elseif cmd == "SET" then return "+OK\r\n"
		end
	end)


	-- Create connection with specific db
	local db = redis.new {
		addr = "127.0.0.1:16379",
		db = 5,
	}

	-- First command should succeed (triggers SELECT 5 on connect)
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 11.1: First PING should succeed")

	-- Second command should fail (server disconnects)
	local ok2, err2 = db:set("key", "value")
	testaux.asserteq(ok2, false, "Test 11.2: Second command should fail after disconnect")

	-- Third command should reconnect and auto-SELECT db 5
	local ok3, val3 = db:ping()
	testaux.asserteq(ok3, true, "Test 11.3: Should reconnect and auto-select db")

	-- Verify that SET command works (confirms we're in the right db context)
	local ok4, val4 = db:set("test_key", "test_value")
	testaux.asserteq(ok4, true, "Test 11.4: SET should work after reconnect")

	db:close()
	testaux.success("Test 11: Auto-reconnect with db selection passed")
end)

-- Test 12: Auto-reconnect with server restart and db selection
testaux.case("Test 12: Auto-reconnect with server restart and db selection", function()
	print("-----Test 12: Auto-reconnect with server restart and db selection-----")

	-- Reset to default handler
	fake_server:set_handler(nil)

	-- Create connection with db=11
	local db = redis.new {
		addr = "127.0.0.1:16379",
		db = 11,
	}

	-- First operation should succeed and auto-SELECT db 11
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 12.1: Initial PING should succeed")

	-- Set a key (verifies db selection worked)
	local ok2, val2 = db:set("test_key", "test_value")
	testaux.asserteq(ok2, true, "Test 12.2: SET should succeed")
	testaux.asserteq(val2, "OK", "Test 12.2: SET should return OK")

	-- Stop the server (simulates server crash/restart)
	print("[Test 12] Stopping fake server to simulate crash...")
	fake_server:stop()

	-- Next command should fail
	local ok3, err3 = db:get("test_key")
	testaux.asserteq(ok3, false, "Test 12.3: GET should fail after server stop")

	-- Restart the server
	print("[Test 12] Restarting fake server...")
	fake_server:start()

	-- Next command should reconnect and auto-SELECT db 11
	local ok4, val4 = db:ping()
	testaux.asserteq(ok4, true, "Test 12.4: PING should succeed after reconnect")

	-- Verify we can still operate (proves db was re-selected)
	local ok5, val5 = db:set("reconnect_key", "reconnect_value")
	testaux.asserteq(ok5, true, "Test 12.5: SET should work after reconnect")

	local ok6, val6 = db:get("reconnect_key")
	testaux.asserteq(ok6, true, "Test 12.6: GET should work after reconnect")
	testaux.asserteq(val6, "bar", "Test 12.6: GET should return fake server value")

	-- Clean up
	db:close()
	testaux.success("Test 12: Server restart with auto-reconnect and db selection passed")
end)

-- Test 13: Close wakes up blocked coroutine
testaux.case("Test 13: Close wakes up blocked coroutine", function()
	print("-----Test 13: Close wakes up blocked coroutine-----")

	fake_server:set_handler(function(cmd, args, command_count, client)
		if cmd == "PING" then
			return "+PONG\r\n"
		elseif cmd == "GET" and command_count == 2 then
			-- Hang on second command (GET)
			return nil  -- Don't respond
		elseif cmd == "GET" then
			return "$3\r\nbar\r\n"
		elseif cmd == "SET" then
			return "+OK\r\n"
		elseif cmd == "SELECT" then
			return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First command succeeds
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 13.1: First PING should succeed")

	-- Track whether the blocked coroutine was woken up
	local blocked_woken = false
	local blocked_error = nil

	local wg = waitgroup.new()

	-- Coroutine 1: Send a command that will hang (server won't respond)
	wg:fork(function()
		local ok, err = db:get("test_key")
		blocked_woken = true
		blocked_error = err
		testaux.asserteq(ok, false, "Test 13.2: Blocked command should fail after close")
	end)

	-- Give time for the command to be sent and block
	time.sleep(200)

	-- Coroutine 2: Close the connection to wake up the blocked coroutine
	wg:fork(function()
		db:close()
	end)

	-- Wait for both coroutines to complete
	wg:wait()

	-- Verify the blocked coroutine was woken up
	testaux.asserteq(blocked_woken, true, "Test 13.3: Blocked coroutine should be woken up by close")
	testaux.asserteq(type(blocked_error), "string", "Test 13.4: Should receive error message")

	testaux.success("Test 13: Close wakes up blocked coroutine passed")
end)

-- Test 14: Close wakes up readco and waitq
testaux.case("Test 14: Close wakes up readco and waitq", function()
	print("-----Test 14: Close wakes up readco and waitq-----")

	local first_hang_seen = false
	fake_server:set_handler(function(cmd, args, command_count, client)
		if cmd == "PING" and not first_hang_seen then
			return "+PONG\r\n"
		elseif cmd == "GET" and not first_hang_seen then
			-- First GET hangs, and after this all commands hang
			first_hang_seen = true
			return nil  -- Hang
		elseif first_hang_seen then
			-- After first hang, all commands hang (server is stuck)
			return nil
		elseif cmd == "GET" then
			return "$3\r\nbar\r\n"
		elseif cmd == "SET" then
			return "+OK\r\n"
		elseif cmd == "SELECT" then
			return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First command succeeds
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 14.1: First PING should succeed")

	-- Track results
	local readco_woken = false
	local readco_error = nil
	local waitco1_woken = false
	local waitco1_error = nil

	local wg = waitgroup.new()

	-- Coroutine 1: Send GET that will hang (becomes readco)
	wg:fork(function()
		local ok, err = db:get("key1")
		readco_woken = true
		readco_error = err
		testaux.asserteq(ok, false, "Test 14.2: Readco should fail after close")
	end)

	-- Give time for GET to be sent and become readco
	time.sleep(200)

	-- Coroutine 2: Send SET (will enter waitq)
	wg:fork(function()
		local ok, err = db:set("key2", "value2")
		waitco1_woken = true
		waitco1_error = err
		testaux.asserteq(ok, false, "Test 14.3: Waitco1 should fail after close")
	end)

	-- Give time for SET to enter waitq
	time.sleep(200)

	-- Coroutine 3: Close the connection
	wg:fork(function()
		db:close()
	end)

	-- Wait for all coroutines to complete
	wg:wait()

	-- Verify all coroutines were woken up
	testaux.asserteq(readco_woken, true, "Test 14.4: Readco should be woken up")
	testaux.asserteq(type(readco_error), "string", "Test 14.5: Readco should receive error")
	testaux.asserteq(waitco1_woken, true, "Test 14.6: Waitco1 should be woken up")
	testaux.asserteq(type(waitco1_error), "string", "Test 14.7: Waitco1 should receive error")

	testaux.success("Test 14: Close wakes up readco and waitq passed")
end)

-- Test 15: Concurrent reconnect after disconnection
testaux.case("Test 15: Concurrent reconnect after disconnection", function()
	print("-----Test 15: Concurrent reconnect after disconnection-----")

	local connect_count = 0
	local clients = {}
	local first_ping_seen = false

	fake_server:set_handler(function(cmd, args, command_count, client)
		-- Track unique connections
		if not clients[client] then
			clients[client] = true
			connect_count = connect_count + 1
		end

		-- First connection's first PING command: disconnect immediately
		if connect_count == 1 and cmd == "PING" and not first_ping_seen then
			first_ping_seen = true
			return false  -- Disconnect without response
		end

		-- Normal command handling
		if cmd == "PING" then
			return "+PONG\r\n"
		elseif cmd == "GET" then
			return "$3\r\nbar\r\n"
		elseif cmd == "SET" then
			return "+OK\r\n"
		elseif cmd == "SELECT" then
			return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	-- redis.new() does NOT establish connection (lazy connection)
	local db = redis.new {
		addr = "127.0.0.1:16379",
	}
	testaux.asserteq(connect_count, 0, "Test 15.1: redis.new() should NOT establish connection")

	-- Send first PING - this will trigger connection, then server will disconnect
	-- This is the synchronization point: client will detect disconnection
	local ok1, err1 = db:ping()
	testaux.asserteq(ok1, false, "Test 15.2: First PING should fail (disconnect)")
	testaux.asserteq(connect_count, 1, "Test 15.3: Should have created first connection")

	-- NOW: sock = false, all coroutines will see disconnected state
	-- Launch concurrent operations - all will race to reconnect
	local wg = waitgroup.new()
	local results = {}

	for i = 1, 5 do
		wg:fork(function()
			local ok, val = db:ping()
			results[i] = {ok = ok, val = val}
		end)
	end

	wg:wait()

	-- Verify all requests succeeded
	for i = 1, 5 do
		testaux.asserteq(results[i].ok, true, string.format("Test 15.%d: PING should succeed", i + 3))
	end

	-- CRITICAL: Should have created exactly 2 connections total (first + one reconnect)
	testaux.asserteq(connect_count, 2, "Test 15.9: Should create exactly 2 connections (first + one reconnect)")

	db:close()
	testaux.success("Test 15: Concurrent reconnect correctly uses mutex")
end)

-- Test 16: Operations after close should fail and not reconnect
testaux.case("Test 16: Operations after close should fail and not reconnect", function()
	print("-----Test 16: Operations after close should not reconnect-----")

	local connect_count = 0
	local clients = {}

	fake_server:set_handler(function(cmd, args, command_count, client)
		-- Track unique connections
		if not clients[client] then
			clients[client] = true
			connect_count = connect_count + 1
		end

		if cmd == "PING" then
			return "+PONG\r\n"
		elseif cmd == "GET" then
			return "$3\r\nbar\r\n"
		elseif cmd == "SET" then
			return "+OK\r\n"
		elseif cmd == "SELECT" then
			return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}

	-- First, establish a connection
	local ok1, val1 = db:ping()
	testaux.asserteq(ok1, true, "Test 16.1: First PING should succeed")
	testaux.asserteq(connect_count, 1, "Test 16.2: Should have created one connection")

	-- Close the connection
	db:close()

	-- Second request should fail (closed state) and NOT reconnect
	local ok2, err2 = db:get("key")
	testaux.asserteq(ok2, false, "Test 16.3: Operation after close should fail")
	testaux.asserteq(err2, "active closed", "Test 16.4: Should return 'active close' error")
	testaux.asserteq(connect_count, 1, "Test 16.5: Should NOT create new connection after close")

	-- Multiple operations after close should all fail
	local ok3, err3 = db:set("key", "value")
	testaux.asserteq(ok3, false, "Test 16.6: SET after close should fail")
	testaux.asserteq(err3, "active closed", "Test 16.7: Should return 'active close' error")

	local ok4, err4 = db:ping()
	testaux.asserteq(ok4, false, "Test 16.8: PING after close should fail")
	testaux.asserteq(err4, "active closed", "Test 16.9: Should return 'active close' error")

	-- Verify no new connections were created
	testaux.asserteq(connect_count, 1, "Test 16.10: Total connections should remain 1")

	testaux.success("Test 16: Operations after close correctly rejected")
end)

-- Test 17: Concurrent close and reconnect
testaux.case("Test 17: Concurrent close and reconnect", function()
	print("-----Test 17: Concurrent close and reconnect-----")

	local connect_count = 0
	local clients = {}
	local first_ping_seen = false

	fake_server:set_handler(function(cmd, args, command_count, client)
		if not clients[client] then
			clients[client] = true
			connect_count = connect_count + 1
		end
		-- First connection's first PING: disconnect
		if connect_count == 1 and cmd == "PING" and not first_ping_seen then
			first_ping_seen = true
			return false
		end
		if cmd == "PING" then return "+PONG\r\n"
		elseif cmd == "GET" then return "$3\r\nbar\r\n"
		elseif cmd == "SET" then return "+OK\r\n"
		elseif cmd == "SELECT" then return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}
	testaux.asserteq(connect_count, 0, "Test 17.1: No connection yet")

	-- Trigger disconnection first
	local ok1, err1 = db:ping()
	testaux.asserteq(ok1, false, "Test 17.2: First PING should fail (disconnect)")
	testaux.asserteq(connect_count, 1, "Test 17.3: Should have created first connection")

	local wg = waitgroup.new()
	local results = {}

	-- Coroutine 1: Try to reconnect via PING, then close
	wg:fork(function()
		local ok, val = db:ping()
		results[1] = {ok = ok, val = val}
		db:close()
	end)

	-- Coroutine 2: Try to reconnect via PING concurrently
	wg:fork(function()
		local ok, val = db:ping()
		results[2] = {ok = ok, val = val}
	end)

	wg:wait()

	-- At least one of the concurrent operations might succeed before close
	-- But after close, all operations should fail with "active closed"
	local ok_final, err_final = db:ping()
	testaux.asserteq(ok_final, false, "Test 17.4: Operation after close should fail")
	testaux.asserteq(err_final, "active closed", "Test 17.5: Should return 'active closed' error")

	-- Verify at most 2 connections were created (initial + one reconnect)
	testaux.assertle(connect_count, 2, "Test 17.6: Should create at most 2 connections")

	testaux.success("Test 17: Concurrent close and reconnect handled correctly")
end)

-- Test 18: First concurrent reconnect succeeds and closes, others get "active closed" from double-check
testaux.case("Test 18: First reconnect closes, queued coroutines get 'active closed'", function()
	print("-----Test 18: First reconnect closes, queued coroutines get 'active closed'-----")

	local connect_count = 0
	local clients = {}
	local first_ping_seen = false
	local close_co = nil  -- Will store the close coroutine

	fake_server:set_handler(function(cmd, args, command_count, client)
		if not clients[client] then
			clients[client] = true
			connect_count = connect_count + 1
		end

		-- First connection's first PING: disconnect
		if connect_count == 1 and cmd == "PING" and not first_ping_seen then
			first_ping_seen = true
			return false
		end

		-- Second connection (reconnect): when GET is received, signal close coroutine
		if connect_count == 2 and cmd == "GET" then
			if close_co then
				task.wakeup(close_co)
			end
			return "$3\r\nbar\r\n"
		end

		if cmd == "PING" then return "+PONG\r\n"
		elseif cmd == "SELECT" then return "+OK\r\n"
		end
		return "-ERR unknown command\r\n"
	end)

	local db = redis.new {
		addr = "127.0.0.1:16379",
	}
	testaux.asserteq(connect_count, 0, "Test 18.1: No connection yet")

	-- Trigger disconnection
	local ok1, err1 = db:ping()
	testaux.asserteq(ok1, false, "Test 18.2: First PING fails")
	testaux.asserteq(connect_count, 1, "Test 18.3: First connection created")

	-- Launch concurrent operations
	local wg = waitgroup.new()
	local results = {}

	-- First coroutine: will successfully reconnect
	wg:fork(function()
		local ok, val = db:get("key1")
		results[1] = {ok = ok, err = val}
	end)

	-- Give first coroutine time to enter connect_to_redis and acquire mutex
	time.sleep(50)

	-- Close coroutine: will wait for signal from server
	wg:fork(function()
		close_co = task.running()
		task.wait()  -- Wait for signal from server handler
		db:close()
	end)

	-- Other coroutines: will queue on mutex, then hit double-check and see closed=true
	for i = 2, 5 do
		time.sleep(10)  -- Small stagger
		wg:fork(function()
			local ok, val = db:get("key" .. i)
			results[i] = {ok = ok, err = val}
		end)
	end

	wg:wait()

	-- Verify results
	local success_count = 0
	local active_close_count = 0

	for i = 1, 5 do
		if results[i].ok then
			success_count = success_count + 1
		elseif results[i].err == "active closed" then
			active_close_count = active_close_count + 1
		end
	end

	-- Only first request should succeed
	testaux.asserteq(success_count, 1, "Test 18.4: Exactly ONE request should succeed")
	-- Others should fail with "active closed" from double-check
	testaux.asserteq(active_close_count, 4, "Test 18.5: Other 4 requests should get 'active closed'")
	-- Only 2 connections total
	testaux.asserteq(connect_count, 2, "Test 18.6: Should create exactly 2 connections")

	testaux.success("Test 18: Double-check correctly detects closed flag")
end)

-- Cleanup: Stop the fake server
fake_server:stop()

print("\n=== All Redis tests passed! ===")
