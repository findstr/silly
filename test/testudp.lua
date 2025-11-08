local silly = require "silly"
local time = require "silly.time"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"
local channel = require "silly.sync.channel"
local crypto = require "silly.crypto.utils"
local testaux = require "test.testaux"

-- Test 1: Basic UDP echo server
testaux.case("Test 1: Basic UDP echo server", function()
	local server_fd = udp.bind("127.0.0.1:8989")
	testaux.assertneq(server_fd, nil, "Test 1.1: UDP bind")

	local wg = waitgroup.new()

	-- Start echo server
	wg:fork(function()
		for i = 1, 20 do
			local data, addr = server_fd:recvfrom()
			if not data then
				break
			end
			time.sleep(50)
			server_fd:sendto(data, addr)
		end
	end)

	-- Connect client and send data
	local client_fd = udp.connect("127.0.0.1:8989")
	testaux.assertneq(client_fd, nil, "Test 1.2: UDP connect")

	local buf = {}
	for i = 1, 20 do
		local d = crypto.randomkey(8)
		client_fd:sendto(d)
		buf[i] = d
	end

	-- Verify echoed data
	for i = 1, 20 do
		local data = client_fd:recvfrom()
		testaux.asserteq(data, buf[i], "Test 1.3: UDP data validate " .. i)
	end

	client_fd:close()
	server_fd:close()
	wg:wait()

	testaux.success("Test 1 passed")
end)

-- Test 2: UDP send to unreachable address
testaux.case("Test 2: UDP send to unreachable address", function()
	local wg = waitgroup.new()

	wg:fork(function()
		local fd = udp.connect("127.0.0.1:1998")
		testaux.assertneq(fd, nil, "Test 2.1: UDP connect to unreachable address")

		local ok = fd:sendto("Hello, UDP!")
		testaux.asserteq(ok, true, "Test 2.2: Send should succeed even if destination unreachable")

		fd:close()
	end)

	wg:wait()
	testaux.success("Test 2 passed")
end)

-- Test 3: UDP concurrent clients
testaux.case("Test 3: UDP concurrent clients", function()
	local server_fd = udp.bind("127.0.0.1:8990")
	testaux.assertneq(server_fd, nil, "Test 3.1: UDP bind")

	local wg = waitgroup.new()
	local received_count = 0

	-- Server receives from multiple clients
	wg:fork(function()
		for i = 1, 10 do
			local data, addr = server_fd:recvfrom()
			if data then
				received_count = received_count + 1
				server_fd:sendto(data, addr)
			end
		end
	end)

	-- Multiple clients
	for client_id = 1, 5 do
		wg:fork(function()
			local client = udp.connect("127.0.0.1:8990")
			for i = 1, 2 do
				local msg = string.format("client_%d_msg_%d", client_id, i)
				client:sendto(msg)
				local resp = client:recvfrom()
				testaux.asserteq(resp, msg, "Test 3.2: Client " .. client_id .. " message " .. i)
			end
			client:close()
		end)
	end

	wg:wait()
	testaux.asserteq(received_count, 10, "Test 3.3: Server received all messages")
	server_fd:close()

	testaux.success("Test 3 passed")
end)

-- Test 4: Basic recvfrom timeout
testaux.case("Test 4: Basic recvfrom timeout", function()
	local server_fd = udp.bind("127.0.0.1:8991")
	testaux.assertneq(server_fd, nil, "Test 4.1: UDP bind")

	-- Try to receive with timeout, but no data sent
	local dat, err = server_fd:recvfrom(500)
	testaux.asserteq(dat, nil, "Test 4.2: Recvfrom should timeout")
	testaux.asserteq(err, "read timeout", "Test 4.3: Should return 'read timeout' error")

	server_fd:close()
	testaux.success("Test 4 passed")
end)

-- Test 5: Timeout then successful receive
testaux.case("Test 5: Timeout then successful receive", function()
	local server_fd = udp.bind("127.0.0.1:8992")
	testaux.assertneq(server_fd, nil, "Test 5.1: UDP bind")

	local wg = waitgroup.new()
	local ch = channel.new()

	-- Server tries to receive with timeout
	wg:fork(function()
		-- First receive times out
		local dat1, err1 = server_fd:recvfrom(300)
		testaux.asserteq(dat1, nil, "Test 5.2: First recvfrom should timeout")
		testaux.asserteq(err1, "read timeout", "Test 5.3: Should return 'read timeout'")
		ch:push("timeout")

		-- Second receive succeeds
		local dat2, addr2 = server_fd:recvfrom()
		testaux.asserteq(dat2, "Hello", "Test 5.4: Second recvfrom should succeed")

		server_fd:close()
	end)

	-- Client sends data after server times out
	local client_fd = udp.connect("127.0.0.1:8992")
	ch:pop()  -- Wait for server timeout
	client_fd:sendto("Hello")
	client_fd:close()

	wg:wait()
	testaux.success("Test 5 passed")
end)

-- Test 6: Multiple sequential timeouts
testaux.case("Test 6: Multiple sequential timeouts", function()
	local server_fd = udp.bind("127.0.0.1:8993")
	testaux.assertneq(server_fd, nil, "Test 6.1: UDP bind")

	local wg = waitgroup.new()
	local ch = channel.new()

	wg:fork(function()
		-- First timeout
		local dat1, err1 = server_fd:recvfrom(200)
		testaux.asserteq(dat1, nil, "Test 6.2: First recvfrom should timeout")
		testaux.asserteq(err1, "read timeout", "Test 6.3: Should return 'read timeout'")

		-- Second timeout
		local dat2, err2 = server_fd:recvfrom(200)
		testaux.asserteq(dat2, nil, "Test 6.4: Second recvfrom should timeout")
		testaux.asserteq(err2, "read timeout", "Test 6.5: Should return 'read timeout'")

		-- Third timeout
		local dat3, err3 = server_fd:recvfrom(200)
		testaux.asserteq(dat3, nil, "Test 6.6: Third recvfrom should timeout")
		testaux.asserteq(err3, "read timeout", "Test 6.7: Should return 'read timeout'")
		ch:push("ready")

		-- Finally succeed
		local dat4, addr4 = server_fd:recvfrom()
		testaux.asserteq(dat4, "FINAL", "Test 6.8: Final recvfrom should succeed")

		server_fd:close()
	end)

	local client_fd = udp.connect("127.0.0.1:8993")
	ch:pop()  -- Wait for server to timeout three times
	client_fd:sendto("FINAL")
	client_fd:close()

	wg:wait()
	testaux.success("Test 6 passed")
end)

-- Test 7: Receive from stash after timeout
testaux.case("Test 7: Receive from stash after timeout", function()
	local server_fd = udp.bind("127.0.0.1:8994")
	testaux.assertneq(server_fd, nil, "Test 7.1: UDP bind")

	local wg = waitgroup.new()
	local client_fd = udp.connect("127.0.0.1:8994")

	-- Client sends data before server starts receiving
	client_fd:sendto("message1")
	client_fd:sendto("message2")
	client_fd:sendto("message3")

	time.sleep(100)  -- Let packets arrive and be stashed

	wg:fork(function()
		-- Server should receive from stash immediately (no timeout)
		local dat1, addr1 = server_fd:recvfrom(500)
		testaux.asserteq(dat1, "message1", "Test 7.2: Should receive first stashed message")

		local dat2, addr2 = server_fd:recvfrom(500)
		testaux.asserteq(dat2, "message2", "Test 7.3: Should receive second stashed message")

		local dat3, addr3 = server_fd:recvfrom(500)
		testaux.asserteq(dat3, "message3", "Test 7.4: Should receive third stashed message")

		-- Now nothing in stash, should timeout
		local dat4, err4 = server_fd:recvfrom(300)
		testaux.asserteq(dat4, nil, "Test 7.5: Should timeout when stash is empty")
		testaux.asserteq(err4, "read timeout", "Test 7.6: Should return 'read timeout'")

		server_fd:close()
	end)

	client_fd:close()
	wg:wait()
	testaux.success("Test 7 passed")
end)

-- Test 8: Close during timeout wait
testaux.case("Test 8: Close during timeout wait", function()
	local server_fd = udp.bind("127.0.0.1:8995")
	testaux.assertneq(server_fd, nil, "Test 8.1: UDP bind")

	local wg = waitgroup.new()
	local ch = channel.new()

	wg:fork(function()
		ch:push("ready")
		-- Try to receive with long timeout
		local dat, err = server_fd:recvfrom(2000)
		testaux.asserteq(dat, nil, "Test 8.2: Should fail when closed")
		testaux.asserteq(err, "active closed", "Test 8.3: Should return 'active closed' error")
	end)

	-- Close connection after server starts waiting
	ch:pop()
	time.sleep(100)
	server_fd:close()

	wg:wait()
	testaux.success("Test 8 passed")
end)

-- Test 9: Large packet handling
testaux.case("Test 9: Large packet handling", function()
	local server_fd = udp.bind("127.0.0.1:8996")
	testaux.assertneq(server_fd, nil, "Test 9.1: UDP bind")

	local wg = waitgroup.new()

	wg:fork(function()
		local data, addr = server_fd:recvfrom()
		testaux.asserteq(#data, 1024, "Test 9.2: Should receive large packet")
		server_fd:sendto(data, addr)
		server_fd:close()
	end)

	local client_fd = udp.connect("127.0.0.1:8996")
	local large_data = string.rep("A", 1024)
	client_fd:sendto(large_data)

	local resp = client_fd:recvfrom()
	testaux.asserteq(resp, large_data, "Test 9.3: Should receive echoed large packet")

	client_fd:close()
	wg:wait()
	testaux.success("Test 9 passed")
end)

-- Test 10: Unread bytes tracking
testaux.case("Test 10: Unread bytes tracking", function()
	local server_fd = udp.bind("127.0.0.1:8997")
	testaux.assertneq(server_fd, nil, "Test 10.1: UDP bind")

	local client_fd = udp.connect("127.0.0.1:8997")

	-- Send multiple packets
	client_fd:sendto("msg1")
	client_fd:sendto("msg22")
	client_fd:sendto("msg333")

	time.sleep(100)  -- Let packets arrive

	local unread = server_fd:unreadbytes()
	testaux.assertgt(unread, 0, "Test 10.2: Should have unread bytes")

	-- Consume packets
	server_fd:recvfrom()
	server_fd:recvfrom()
	server_fd:recvfrom()

	local unread_after = server_fd:unreadbytes()
	testaux.asserteq(unread_after, 0, "Test 10.3: Should have no unread bytes after consuming all")

	server_fd:close()
	client_fd:close()
	testaux.success("Test 10 passed")
end)

print("\ntestudp all tests passed!")
