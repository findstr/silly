local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
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

local listenfd = tcp.listen {
	addr = listenaddr,
	accept = function(conn)
		if listen_cb then
			listen_cb(conn)
			listen_cb = nil
		else
			tcp.close(conn)
		end
	end
}

local function wait_done()
	while listen_cb do
		time.sleep(100)
	end
	time.sleep(1000)
end

-- Test 1: Accept a connection
testaux.case("Test 1: Accept a connection", function()
	local localfd
	local remoteaddr = ""
	listen_cb = function(fd)
		local addr = fd:remoteaddr()
		remoteaddr = addr
		local localaddr = testaux.getsockname(localfd)
		testaux.asserteq(localaddr, remoteaddr, "Test 1.1: Local endpoint matches accept address")
		testaux.close(localfd)
		tcp.close(fd)
	end
	localfd = testaux.connect(ip, port)
	testaux.assertneq(localfd, nil, "Test 1.2: Connect to server")
	wait_done()
	testaux.success("Test 1 passed")
end)

-- Test 2: Read from a connection
testaux.case("Test 2: Read from a connection", function()
	local subblock = largeBlock:sub(1024, 1024 + 1024)
	local cfd
	listen_cb = function(fd)
		local dat = tcp.read(fd, #largeBlock)
		tcp.write(fd, subblock)
		testaux.asserteq(dat, largeBlock, "Test 2.1: Read large block from connection")
		tcp.close(fd)
		local dat = testaux.recv(cfd, #subblock)
		testaux.asserteq(dat, subblock, "Test 2.2: Read large block from connection")
		testaux.close(cfd)
	end
	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 2.3: Connect to server for reading")
	testaux.send(cfd, largeBlock)
	wait_done()
	testaux.success("Test 2 passed")
end)

-- Test 3: Write to a connection
testaux.case("Test 3: Write to a connection", function()
	listen_cb = function(fd)
		for i = 1, #largeBlock, 1024 do
			local chunk = largeBlock:sub(i, i + 1023)
			local dat = tcp.write(fd, chunk)
			testaux.asserteq(dat, true, "Test 3.1: Write chunk from connection")
			if i % 8 == 0 then
				time.sleep(100)  -- Simulate some delay
			end
		end
		tcp.close(fd)
	end
	local fd = testaux.connect(ip, port)
	testaux.assertneq(fd, nil, "Test 3.2: Connect to server for writing")
	time.sleep(1000)---
	local dat = testaux.recv(fd, #largeBlock)
	testaux.asserteq(dat, largeBlock, "Test 3.3: Read large block from connection")
	wait_done()
	testaux.success("Test 3 passed")
end)

-- Test 4: Half-close scenario
testaux.case("Test 4: Half-close scenario", function()
	listen_cb = function(sfd)
		local addr = sfd:remoteaddr()
		-- 1. Read the initial data
		local dat, err = tcp.read(sfd, 5)
		testaux.asserteq(dat, "hello", "Test 4.1: Server read initial data")

		-- 2. Subsequent read should immediately return ("", "end of file") due to FIN
		local dat2, err2 = tcp.read(sfd, 1)
		testaux.asserteq(dat2, "", "Test 4.2: Server read after FIN returns empty string")
		testaux.asserteq(err2, "end of file", "Test 4.3: Server read after FIN returns 'end of file'")

		-- 3. Server should still be able to write
		local ok, err3 = tcp.write(sfd, "world")
		testaux.asserteq(ok, true, "Test 4.4: Server write after half-close succeeds")

		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.send(cfd, "hello")
	-- Shutdown write-end, this sends a FIN packet to the server.
	testaux.shutdown(cfd, 1) -- 1 for SHUT_WR
	time.sleep(0)
	-- Client should be able to read the response from server
	local response = testaux.recv(cfd, 5)
		testaux.asserteq(response, "world", "Test 4.5: Client received response after half-close")
	testaux.close(cfd)
	time.sleep(100) -- wait for server to finish
	wait_done()
	testaux.success("Test 4 passed")
end)

-- Test 5: Readline interrupted by close
testaux.case("Test 5: Readline interrupted by close", function()
	listen_cb = function(sfd)
		local addr = sfd:remoteaddr()
		local data, err = tcp.readline(sfd, "\n")
		testaux.asserteq(data, "", "Test 5.1: Readline returns empty string on interrupted read")
		testaux.asserteq(err, "end of file", "Test 5.2: Readline returns 'end of file' error")
		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 5.3: Connect to server for writing")
	testaux.send(cfd, "partial line")
	testaux.close(cfd) -- Close connection without sending newline
	wait_done()
	testaux.success("Test 5 passed")
end)

-- Test 6: Double close
testaux.case("Test 6: Double close", function()
	listen_cb = function(sfd)
		local addr = sfd:remoteaddr()
		local ok1, err1 = tcp.close(sfd)
		testaux.asserteq(ok1, true, "Test 6.1: First close succeeds")

		local ok2, err2 = tcp.close(sfd)
		testaux.asserteq(ok2, false, "Test 6.2: Second close fails")
		testaux.asserteq(err2, "socket closed", "Test 6.3: Second close returns correct error")
	end

	local cfd = testaux.connect(ip, port)
	time.sleep(100) -- wait for server to close
	testaux.close(cfd)
	wait_done()
	testaux.success("Test 6 passed")
end)

-- Test 7: Write buffer saturation (wlist activation)
testaux.case("Test 7: Write buffer saturation", function()
	local block_size = 64 * 1024 -- 64KB
	local blocks_to_send = 128 -- Total 4MB
	local total_size = block_size * blocks_to_send
	local large_data = string.rep("a", block_size)
	local cfd
	listen_cb = function(sfd)
		-- Write a large amount of data to saturate the buffer
		for i = 1, blocks_to_send do
			tcp.write(sfd, large_data)
		end
		local sendsize = tcp.sendsize(sfd)
		testaux.assertgt(sendsize, 0, "Test 7.1: tcp.sendsize shows buffered data")
		local ok, err = tcp.close(sfd)
		testaux.asserteq(ok, true, "Test 7.2: Server close succeeds")
		testaux.asserteq(err, nil, "Test 7.3: Server close returns nil error")
		local received_data = testaux.recv(cfd, total_size)
		testaux.asserteq(#received_data, total_size, "Test 7.4: Client received all data")
		testaux.close(cfd)
	end
	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 7.5: Connect to server for writing")
	wait_done()
	testaux.success("Test 7 passed")
end)

-- Test 8: Interleaved Read/Write (Echo Server)
testaux.case("Test 8: Interleaved Read/Write", function()
	local echo_count = 5
	listen_cb = function(sfd)
		for i = 1, echo_count do
			local data, err = tcp.readline(sfd, "\n")
			if not data then
		break
	end
			testaux.asserteq(data, "hello" .. i .. "\n", "Test 8.1: Server received correct data chunk")
			tcp.write(sfd, data)
		end
		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	for i = 1, echo_count do
		local chunk = "hello" .. i .. "\n"
		testaux.send(cfd, chunk)
		local response = testaux.recv(cfd, #chunk)
		testaux.asserteq(response, chunk, "Test 8.2: Client received correct echo")
	end
	testaux.close(cfd)
	time.sleep(100)
	wait_done()
	testaux.success("Test 8 passed")
end)

-- Test 9: Connection Failure
testaux.case("Test 9: Connection Failure", function()
	local invalid_port = 54321
	local invalid_addr = string.format("%s:%d", ip, invalid_port)

	-- This test checks the async tcp.connect API, so it must be run in a coroutine.
	task.fork(function()
		local fd, err = tcp.connect(invalid_addr)

		if fd then
			-- Connection succeeded unexpectedly, close it and fail the test.
			tcp.close(fd)
			testaux.error("Test 9.1: Unexpected successful connection to invalid port")
		else
			-- Connection failed as expected.
			testaux.assertneq(err, nil, "Test 9.1: Connection failure returned an error")
		end
	end)

	time.sleep(200) -- Allow time for the async connection to fail.
	wait_done()
	testaux.success("Test 9 passed")
end)

-- Test 10: Basic read timeout
testaux.case("Test 10: Basic read timeout", function()
	listen_cb = function(sfd)
		-- Try to read 10 bytes with 500ms timeout, but don't send anything
		local dat, err = tcp.read(sfd, 10, 500)
		testaux.asserteq(dat, nil, "Test 10.1: Read should timeout")
		testaux.asserteq(err, "read timeout", "Test 10.2: Should return 'read timeout' error")
		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 10.3: Connect to server")
	-- Don't send any data, let server timeout
	time.sleep(1000)
	testaux.close(cfd)
	wait_done()
	testaux.success("Test 10 passed")
end)

-- Test 11: Partial data then timeout then continue reading
testaux.case("Test 11: Partial data then timeout then continue reading", function()
	local cfd
	listen_cb = function(sfd)
		-- Try to read 5 bytes with 500ms timeout, but only 2 bytes available
		local dat, err = tcp.read(sfd, 5, 500)
		testaux.asserteq(dat, nil, "Test 11.1: First read should timeout")
		testaux.asserteq(err, "read timeout", "Test 11.2: Should return 'read timeout' error")

		-- Now client will send 3 more bytes, total 5 bytes available
		time.sleep(200)

		-- This read should succeed immediately with the 5 bytes in buffer
		local dat2, err2 = tcp.read(sfd, 5)
		testaux.asserteq(dat2, "12345", "Test 11.3: Second read should get complete data")
		testaux.asserteq(err2, nil, "Test 11.4: Should have no error")

		-- Send more data in chunks
		time.sleep(100)

		-- Try to read 10 bytes with timeout, client will send 8 bytes total
		local dat3, err3 = tcp.read(sfd, 10, 500)
		testaux.asserteq(dat3, nil, "Test 11.5: Third read should timeout")
		testaux.asserteq(err3, "read timeout", "Test 11.6: Should return 'read timeout' error")

		time.sleep(100)
		-- Read the buffered 8 bytes
		local dat4, err4 = tcp.read(sfd, 8)
		testaux.asserteq(dat4, "abcdefgh", "Test 11.7: Fourth read should get buffered data")

		tcp.close(sfd)
	end

	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 11.8: Connect to server")

	-- Send 2 bytes, server will timeout waiting for 5
	testaux.send(cfd, "12")
	time.sleep(700)

	-- Send 3 more bytes, now server can read 5 bytes
	testaux.send(cfd, "345")
	time.sleep(400)

	-- Send 3 bytes, server will timeout waiting for 10
	testaux.send(cfd, "abc")
	time.sleep(200)

	-- Send 5 more bytes (total 8 bytes for server)
	testaux.send(cfd, "defgh")
	time.sleep(300)

	testaux.close(cfd)
	wait_done()
	testaux.success("Test 11 passed")
end)

-- Test 12: Readline timeout
testaux.case("Test 12: Readline timeout", function()
	local cfd
	listen_cb = function(sfd)
		-- Try to readline with timeout, but no newline sent
		local dat, err = tcp.readline(sfd, "\n", 500)
		testaux.asserteq(dat, nil, "Test 12.1: Readline should timeout")
		testaux.asserteq(err, "read timeout", "Test 12.2: Should return 'read timeout' error")

		time.sleep(200)

		-- Now complete line is available, should succeed
		local dat2, err2 = tcp.readline(sfd, "\n")
		testaux.asserteq(dat2, "hello world\n", "Test 12.3: Readline should succeed")
		testaux.asserteq(err2, nil, "Test 12.4: Should have no error")

		tcp.close(sfd)
	end

	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 12.5: Connect to server")

	-- Send partial line without newline
	testaux.send(cfd, "hello world")
	time.sleep(700)

	-- Send newline
	testaux.send(cfd, "\n")
	time.sleep(300)

	testaux.close(cfd)
	wait_done()
	testaux.success("Test 12 passed")
end)

-- Test 13: Mixed read and readline with timeout
testaux.case("Test 13: Mixed read and readline with timeout", function()
	local cfd
	listen_cb = function(sfd)

		-- Try to read 10 bytes with timeout, only 5 available
		local dat, err = tcp.read(sfd, 10, 500)
		testaux.asserteq(dat, nil, "Test 13.1: Read should timeout")
		testaux.asserteq(err, "read timeout", "Test 13.2: Should return 'read timeout' error")

		-- Now read the buffered 5 bytes
		local dat2, err2 = tcp.read(sfd, 5)
		testaux.asserteq(dat2, "HELLO", "Test 13.3: Should read buffered data")

		time.sleep(100)

		-- Try readline with timeout, no newline yet
		local dat3, err3 = tcp.readline(sfd, "\n", 500)
		testaux.asserteq(dat3, nil, "Test 13.4: Readline should timeout")
		testaux.asserteq(err3, "read timeout", "Test 13.5: Should return 'read timeout' error")

		time.sleep(100)

		-- Complete the line
		local dat4, err4 = tcp.readline(sfd, "\n")
		testaux.asserteq(dat4, "WORLD\n", "Test 13.6: Readline should succeed")

		time.sleep(100)

		-- Mix: read 3 bytes with timeout, only 2 available
		local dat5, err5 = tcp.read(sfd, 3, 500)
		testaux.asserteq(dat5, nil, "Test 13.7: Read should timeout")
		testaux.asserteq(err5, "read timeout", "Test 13.8: Should return 'read timeout' error")

		-- Readline should get the buffered "ab" plus "c\n"
		local dat6, err6 = tcp.readline(sfd, "\n")
		testaux.asserteq(dat6, "abc\n", "Test 13.9: Readline should get buffered + new data")

		tcp.close(sfd)
	end

	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 13.10: Connect to server")

	-- Send 5 bytes, server expects 10
	testaux.send(cfd, "HELLO")
	time.sleep(700)

	-- Send partial line without newline
	testaux.send(cfd, "WORLD")
	time.sleep(700)

	-- Send newline
	testaux.send(cfd, "\n")
	time.sleep(300)

	-- Send 2 bytes, server expects 3
	testaux.send(cfd, "ab")
	time.sleep(700)

	-- Send remaining data with newline
	testaux.send(cfd, "c\n")
	time.sleep(300)

	testaux.close(cfd)
	wait_done()
	testaux.success("Test 13 passed")
end)

-- Test 14: Connection closed during timeout wait
testaux.case("Test 14: Connection closed during timeout wait", function()
	listen_cb = function(sfd)
		-- Try to read with a long timeout, but connection will close
		local dat, err = tcp.read(sfd, 100, 2000)
		testaux.asserteq(dat, "", "Test 14.1: Read should return empty string on close")
		testaux.asserteq(err, "end of file", "Test 14.2: Should return 'end of file' error")

		tcp.close(sfd)
	end

	local cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 14.3: Connect to server")

	-- Close connection after a short delay
	time.sleep(500)
	testaux.close(cfd)

	wait_done()
	testaux.success("Test 14 passed")
end)

-- Test 15: Multiple sequential timeouts
testaux.case("Test 15: Multiple sequential timeouts", function()
	local cfd
	listen_cb = function(sfd)
		-- First timeout
		local dat1, err1 = tcp.read(sfd, 5, 300)
		testaux.asserteq(dat1, nil, "Test 15.1: First read should timeout")
		testaux.asserteq(err1, "read timeout", "Test 15.2: Should return 'read timeout'")

		-- Second timeout
		local dat2, err2 = tcp.read(sfd, 5, 300)
		testaux.asserteq(dat2, nil, "Test 15.3: Second read should timeout")
		testaux.asserteq(err2, "read timeout", "Test 15.4: Should return 'read timeout'")

		-- Third timeout
		local dat3, err3 = tcp.read(sfd, 5, 300)
		testaux.asserteq(dat3, nil, "Test 15.5: Third read should timeout")
		testaux.asserteq(err3, "read timeout", "Test 15.6: Should return 'read timeout'")

		time.sleep(100)

		-- Finally succeed
		local dat4, err4 = tcp.read(sfd, 5)
		testaux.asserteq(dat4, "FINAL", "Test 15.7: Final read should succeed")

		tcp.close(sfd)
	end

	cfd = testaux.connect(ip, port)
	testaux.assertneq(cfd, nil, "Test 15.8: Connect to server")

	-- Don't send data for multiple timeouts
	time.sleep(1200)

	-- Finally send data
	testaux.send(cfd, "FINAL")
	time.sleep(300)

	testaux.close(cfd)
	wait_done()
	testaux.success("Test 15 passed")
end)

local metrics = require "silly.metrics.c"
-- Test 16: Connect Timeout FD Leak
testaux.case("Test 16: Connect Timeout FD Leak", function()
	local initial_fds = metrics.openfds()

	-- Case A: Immediate Failure (Connection Refused)
	-- Assuming port 54321 is closed (used in Test 9)
	local fd, err = tcp.connect("127.0.0.1:54321")
	testaux.asserteq(fd, nil, "Test 16.1: Connect should fail")
	testaux.asserteq(metrics.openfds(), initial_fds, "Test 16.2: FD count should be restored after immediate failure")

	-- Case B: Timeout Failure
	-- 192.0.2.1 is reserved for documentation (TEST-NET-1) and usually not reachable
	local fd2, err2 = tcp.connect("192.0.2.1:80", {timeout = 100})
	testaux.asserteq(fd2, nil, "Test 16.3: Connect should timeout")
	time.sleep(1000) -- Wait for any delayed cleanup
	testaux.asserteq(metrics.openfds(), initial_fds, "Test 16.4: FD count should be restored after timeout")

	testaux.success("Test 16 passed")
end)

-- Test 17: Listen Failure FD Leak
testaux.case("Test 17: Listen Failure FD Leak", function()
	if metrics.pollapi() == "iocp" then
		-- Skip this test on Windows/iocp as binding to used port may not fail immediately
		testaux.success("Test 17 skipped on iocp")
		return
	end
	local initial_fds = metrics.openfds()

	-- Try to bind to the same address as the main listener
	local fd, err = tcp.listen({addr = listenaddr, accept = function() end})
	testaux.asserteq(fd, nil, "Test 17.1: Listen should fail on used port")
	testaux.asserteq(metrics.openfds(), initial_fds, "Test 17.2: FD count should be restored after listen failure")

	testaux.success("Test 17 passed")
end)

print("testtcp2 all tests passed!")
