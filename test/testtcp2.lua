local core = require "core"
local time = require "core.time"
local tcp = require "core.net.tcp"
local testaux = require "test.testaux"
local listen_cb
local ip = "127.0.0.1"
local port = 20001
local listenaddr = string.format("%s:%d", ip, port)

local largeBlock = ""

do
	local buf = {}
	for i = 1, 2*1024*1024 do
		buf[i] = string.char(i % 256)
	end
	largeBlock = table.concat(buf)
	print(string.format("Large block size: %d bytes", #largeBlock))
end

local listenfd = tcp.listen(listenaddr, function(fd, addr)
	print("Accepted connection from", addr, fd)
	if listen_cb then
		listen_cb(fd, addr)
		listen_cb = nil
	else
		tcp.close(fd)
	end
end)

local function wait_done()
	while listen_cb do
		time.sleep(100)
	end
	time.sleep(1000)
end

-- Test 1: Accept a connection
do
	local localfd
	local remoteaddr = ""
	listen_cb = function(fd, addr)
		print("Accepted connection from", addr)
		remoteaddr = addr
		local localaddr = testaux.getsockname(localfd)
		testaux.asserteq(localaddr, remoteaddr, "Case 1: Local endpoint matches accept address")
		testaux.close(localfd)
		tcp.close(fd)
	end
	localfd = testaux.connect(ip, port)
	testaux.assertneq(localfd, nil, "Case 1: Connect to server")
	wait_done()
end

-- Test 2: Read from a connection
do
	local subblock = largeBlock:sub(1024, 1024 + 1024)
	local cfd
	listen_cb = function(fd, addr)
		local dat = tcp.read(fd, #largeBlock)
		tcp.write(fd, subblock)
		testaux.asserteq(dat, largeBlock, "Case 2: Read large block from connection")
		tcp.close(fd)
		local dat = testaux.recv(cfd, #subblock)
		testaux.asserteq(dat, subblock, "Case 2: Read large block from connection")
		testaux.close(cfd)
	end
	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Case 2: Connect to server for reading")
	testaux.send(cfd, largeBlock)
	wait_done()
end

-- Test 3: Write to a connection
do
	listen_cb = function(fd, addr)
		for i = 1, #largeBlock, 1024 do
			local chunk = largeBlock:sub(i, i + 1023)
			local dat = tcp.write(fd, chunk)
			testaux.asserteq(dat, true, "Case 3: Write chunk from connection")
			if i % 8 == 0 then
				time.sleep(100)  -- Simulate some delay
			end
		end
		tcp.close(fd)
	end
	local fd = testaux.connect(ip, port)
	testaux.assertneq(fd, nil, "Case 3: Connect to server for writing")
	time.sleep(1000)---
	local dat = testaux.recv(fd, #largeBlock)
	testaux.asserteq(dat, largeBlock, "Case 3: Read large block from connection")
	wait_done()
end

-- Test 4: Half-close scenario
-- Tests if server can still write after client performs a write-shutdown.
do
	print("\nTest 4: Half-close scenario")
	listen_cb = function(sfd, addr)
		print("Case 4: Server accepted connection from", addr)
		-- 1. Read the initial data
		local dat, err = tcp.read(sfd, 5)
		testaux.asserteq(dat, "hello", "Case 4: Server read initial data")
		print("Case 4: Server read 'hello'.")

		-- 2. Subsequent read should immediately return nil due to FIN
		local dat2, err2 = tcp.read(sfd, 1)
		testaux.asserteq(dat2, nil, "Case 4: Server read after FIN returns nil")
		print("Case 4: Server read after FIN correctly returned nil.")

		-- 3. Server should still be able to write
		local ok, err3 = tcp.write(sfd, "world")
		testaux.asserteq(ok, true, "Case 4: Server write after half-close succeeds")
		print("Case 4: Server write 'world' after half-close.")

		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.send(cfd, "hello")
	-- Shutdown write-end, this sends a FIN packet to the server.
	print("shutdown")
	testaux.shutdown(cfd, 1) -- 1 for SHUT_WR
	time.sleep(0)
	-- Client should be able to read the response from server
	local response = testaux.recv(cfd, 5)
		testaux.asserteq(response, "world", "Case 4: Client received response after half-close")
	print("Case 4: Client received correct response.")
	testaux.close(cfd)
	time.sleep(100) -- wait for server to finish
	wait_done()
end

-- Test 5: Readline interrupted by close
-- Tests if readline correctly unblocks and returns nil if connection is closed before delimiter is found.
do
	print("\nTest 5: Readline interrupted by close")
	listen_cb = function(sfd, addr)
		print("Case 5: Server accepted connection from", addr)
		local data, err = tcp.readline(sfd, "\n")
		testaux.asserteq(data, nil, "Case 5: Readline returns nil on interrupted read")
		testaux.asserteq(err, "end of file", "Case 5: Readline returns 'closed' error")
		print("Case 5: Readline correctly returned nil and 'closed' error.")
		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Case 5: Connect to server for writing")
	testaux.send(cfd, "partial line")
	testaux.close(cfd) -- Close connection without sending newline
	wait_done()
end

-- Test 6: Double close
-- Tests if closing an already closed socket is handled gracefully.
do
	print("\nTest 6: Double close")
	listen_cb = function(sfd, addr)
		print("Case 6: Server accepted connection from", addr)
		local ok1, err1 = tcp.close(sfd)
		testaux.asserteq(ok1, true, "Case 6: First close succeeds")
		print("Case 6: First close successful.")

		local ok2, err2 = tcp.close(sfd)
		testaux.asserteq(ok2, false, "Case 6: Second close fails")
		testaux.asserteq(err2, "socket closed", "Case 6: Second close returns correct error")
		print("Case 6: Second close correctly failed with 'socket closed'.")
	end

	local cfd = testaux.connect(ip, port)
	time.sleep(100) -- wait for server to close
	testaux.close(cfd)
	wait_done()
end

-- Test 7: Write buffer saturation (wlist activation)
do
	print("\nTest 7: Write buffer saturation")
	local block_size = 64 * 1024 -- 64KB
	local blocks_to_send = 128 -- Total 4MB
	local total_size = block_size * blocks_to_send
	local large_data = string.rep("a", block_size)
	local cfd
	listen_cb = function(sfd, addr)
		print("Case 7: Server accepted connection", sfd)
		-- Write a large amount of data to saturate the buffer
		for i = 1, blocks_to_send do
			tcp.write(sfd, large_data)
		end
		local sendsize = tcp.sendsize(sfd)
		testaux.assertgt(sendsize, 0, "Case 7: tcp.sendsize shows buffered data")
		print("Case 7: Server has " .. sendsize .. " bytes buffered in wlist.")
		local ok, err = tcp.close(sfd)
		testaux.asserteq(ok, true, "Case 7: Server close succeeds")
		testaux.asserteq(err, nil, "Case 7: Server close returns nil error")
		print("Case 7: Client starts reading...")
		local received_data = testaux.recv(cfd, total_size)
		testaux.asserteq(#received_data, total_size, "Case 7: Client received all data")
		print("Case 7: Client received all " .. #received_data .. " bytes.")
		testaux.close(cfd)
	end
	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Case 7: Connect to server for writing")
	wait_done()
end

-- Test 8: Interleaved Read/Write (Echo Server)
do
	print("\nTest 8: Interleaved Read/Write")
	local echo_count = 5
	listen_cb = function(sfd, addr)
		print("Case 8: Echo server accepted connection")
		for i = 1, echo_count do
			local data, err = tcp.readline(sfd, "\n")
			if not data then
		break
		end
			testaux.asserteq(data, "hello" .. i .. "\n", "Case 8: Server received correct data chunk")
			tcp.write(sfd, data)
		end
		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	for i = 1, echo_count do
		local chunk = "hello" .. i .. "\n"
		testaux.send(cfd, chunk)
		local response = testaux.recv(cfd, #chunk)
		testaux.asserteq(response, chunk, "Case 8: Client received correct echo")
	end
	print("Case 8: All echo chunks received correctly.")
	testaux.close(cfd)
	time.sleep(100)
	wait_done()
end

-- Test 9: Connection Failure
do
	print("\nTest 9: Connection Failure")
	local invalid_port = 54321
	local invalid_addr = string.format("%s:%d", ip, invalid_port)

	-- This test checks the async tcp.connect API, so it must be run in a coroutine.
	core.fork(function()
		print("Case 11: Trying to connect to an invalid port", invalid_port)
		local fd, err = tcp.connect(invalid_addr)

		if fd then
			-- Connection succeeded unexpectedly, close it and fail the test.
			tcp.close(fd)
			testaux.error("Case 11: Unexpected successful connection to invalid port")
		else
			-- Connection failed as expected.
			print("Case 11: Connection failed with error:", err)
			testaux.assertneq(err, nil, "Case 11: Connection failure returned an error")
		end
		print("Case 11: Connection failure was correctly reported.")
	end)

	time.sleep(200) -- Allow time for the async connection to fail.
	wait_done()
end

print("testtcp2 passed!")
