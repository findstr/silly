local silly = require "silly"
local task = require "silly.task"
local hive = require "silly.hive"
local time = require "silly.time"
local dns = require "silly.net.dns"
local tls = require "silly.net.tls"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

local is_iocp = silly.multiplexer == "iocp"

local function assert_eof(dat, err, msg_data, msg_err)
	if is_iocp then
		local ok = (dat == "" or dat == nil) and err ~= nil
		testaux.asserteq(ok, true, msg_err)
	else
		testaux.asserteq(dat, "", msg_data)
		testaux.asserteq(err, "end of file", msg_err)
	end
end

-- Test 1: Connect to www.baidu.com
testaux.case("Test 1: Connect to www.baidu.com", function()
	local ip = dns.lookup("www.baidu.com", dns.A)
	local conn = tls.connect(ip..":443")
	conn:write("GET https://www.baidu.com/ HTTP/1.1\r\n" ..
		   "User-Agent: Fiddler\r\n" ..
		   "Host: www.baidu.com\r\n\r\n")
	local d
	while not d do
		d = conn:readline("\n")
		print(d)
	end
	conn:close()
	testaux.success("Test 1 passed")
end)

-- Test 2: Reload certs
testaux.case("Test 2: Reload certs", function()
	local listener = tls.listen {
		addr = "127.0.0.1:10003",
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		accept = function(conn)
			local body = "testssl ok"
			local resp = "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
			conn:write(resp)
			conn:close()
		end
	}
	local bee = hive.spawn [[
		return function()
			local handle = io.popen("curl -v -s https://localhost:10003 --insecure 2>&1")
			assert(handle)
			local result = handle:read("*a")
			handle:close()
			return result
		end
	]]
	local result = hive.invoke(bee)
	local cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost", "Test 2.1: Initial cert CN is localhost")
	tls.reload(listener, {
		certs = {
			{
				cert = testaux.CERT_B,
				key = testaux.KEY_B,
			},
		},
	})
	result = hive.invoke(bee)
	cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost2", "Test 2.2: Reloaded cert CN is localhost2")
	listener:close()
	testaux.success("Test 2 passed")
end)

-- TLS EOF Handling Tests - shared server
local ip = "127.0.0.1"
local port = 10004
local listen_cb

local eof_server = tls.listen {
	addr = ip .. ":" .. port,
	certs = {
		{
			cert = testaux.CERT_A,
			key = testaux.KEY_A,
		},
	},
	accept = function(conn)
		listen_cb(conn)
		listen_cb = nil
	end,
}

local ch = channel.new()

local function waitdone()
	while listen_cb do
		time.sleep(10)
	end
end

-- Test 3.1: TLS read after peer closes
testaux.case("Test 3.1: TLS read after peer closes", function()
	listen_cb = function(conn)
		-- Read initial data
		local dat, err = conn:read(5)
		testaux.asserteq(dat, "hello", "Test 3.1.1: Server read initial data")

		ch:pop()
		-- Subsequent read after client closes should return EOF
		local dat2, err2 = conn:read(1)
		assert_eof(dat2, err2,
			"Test 3.1.2: TLS read after close returns empty string",
			"Test 3.1.3: TLS read after close returns 'end of file'")

		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 3.1.4: Client connected to TLS server")
	local ok, err = cfd:write("hello")
	testaux.asserteq(ok, true, "Test 3.1.5: Client wrote 'hello'")
	cfd:close() -- Close cleanly (with SSL_shutdown)
	ch:push("done")
	testaux.success("Test 3.1 passed")
	waitdone()
end)

-- Test 3.2: TLS readline interrupted by close
testaux.case("Test 3.2: TLS readline interrupted by close", function()
	local waitrl = channel.new()
	listen_cb = function(conn)
		-- Try to readline but client will close before sending newline
		task.fork(function()
			time.sleep(1000)
			waitrl:push("ready")
		end)
		local data, err = conn:readline("\n")
		assert_eof(data, err,
			"Test 3.2.1: TLS readline returns empty data",
			"Test 3.2.2: TLS readline returns `end of file` error")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 3.2.3: Client connected to TLS server")
	local ok, err = cfd:write("incomplete")
	testaux.asserteq(ok, true, "Test 3.2.4: Client wrote incomplete line")
	waitrl:pop() -- Wait until server is in readline
	cfd:close() -- Close before sending newline
	waitdone()
	testaux.success("Test 3.2 passed")
end)

-- Test 3.3: TLS abrupt close
testaux.case("Test 3.3: TLS abrupt close", function()
	listen_cb = function(conn)
		-- Read initial data
		local dat, err = conn:read(5)
		testaux.asserteq(dat, "hello", "Test 3.3.1: Server read initial data")
		-- Try to read after abrupt close
		local dat2, err2 = conn:read(1)
		assert_eof(dat2, err2,
			"Test 3.3.2: TLS read after abrupt close returns empty string",
			"Test 3.3.3: TLS read after abrupt close returns 'end of file'")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 3.3.4: Client connected to TLS server")
	local ok, err = cfd:write("hello")
	testaux.asserteq(ok, true, "Test 3.3.5: Client wrote 'hello'")
	cfd:close()
	testaux.success("Test 3.3 passed")
	waitdone()
end)

-- Test 3.4: Multiple reads after EOF
testaux.case("Test 3.4: Multiple reads after EOF", function()
	listen_cb = function(conn)
		-- First read gets EOF
		local dat1, err1 = conn:read(1)
		assert_eof(dat1, err1,
			"Test 3.4.1: First read returns empty string",
			"Test 3.4.2: First read returns 'end of file'")

		-- Second read should also get EOF
		local dat2, err2 = conn:read(1)
		assert_eof(dat2, err2,
			"Test 3.4.3: Second read returns empty string",
			"Test 3.4.4: Second read returns 'end of file'")

		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 3.4.5: Client connected to TLS server")
	cfd:close() -- Close immediately without sending data
	testaux.success("Test 3.4 passed")
	waitdone()
end)

-- Test 4: Basic read timeout
testaux.case("Test 4: Basic read timeout", function()
	listen_cb = function(conn)
		-- Try to read 10 bytes with 500ms timeout, but don't send anything
		local dat, err = conn:read(10, 500)
		ch:push("ready")
		testaux.asserteq(dat, nil, "Test 4.1: Read should timeout")
		testaux.asserteq(err, "read timeout", "Test 4.2: Should return 'read timeout' error")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 4.3: Connect to server")
	-- Don't send any data, let server timeout
	ch:pop()
	cfd:close()
	testaux.success("Test 4 passed")
	waitdone()
end)

-- Test 5: Partial data then timeout then continue reading
testaux.case("Test 5: Partial data then timeout then continue reading", function()
	listen_cb = function(conn)
		-- Try to read 5 bytes with 500ms timeout, but only 2 bytes available
		local dat, err = conn:read(5, 500)
		ch:push("timeout")
		testaux.asserteq(dat, nil, "Test 5.1: First read should timeout")
		testaux.asserteq(err, "read timeout", "Test 5.2: Should return 'read timeout' error")
		-- This read should succeed immediately with the 5 bytes in buffer
		local dat2, err2 = conn:read(5)
		testaux.asserteq(dat2, "12345", "Test 5.3: Second read should get complete data")
		testaux.asserteq(err2, nil, "Test 5.4: Should have no error")
		-- Try to read 10 bytes with timeout, client will send 8 bytes total
		local dat3, err3 = conn:read(10, 500)
		ch:push("timeout")
		testaux.asserteq(dat3, nil, "Test 5.5: Third read should timeout")
		testaux.asserteq(err3, "read timeout", "Test 5.6: Should return 'read timeout' error")
		-- Read the buffered 8 bytes
		local dat4, err4 = conn:read(8)
		testaux.asserteq(dat4, "abcdefgh", "Test 5.7: Fourth read should get buffered data")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 5.8: Connect to server")

	-- Send 2 bytes, server will timeout waiting for 5
	cfd:write("12")
	ch:pop()
	-- Send 3 more bytes, now server can read 5 bytes
	cfd:write("345")
	-- Send 3 bytes, server will timeout waiting for 10
	cfd:write("abc")
	ch:pop()
	-- Send 5 more bytes (total 8 bytes for server)
	cfd:write("defgh")
	cfd:close()
	testaux.success("Test 5 passed")
	waitdone()
end)

-- Test 6: Readline timeout
testaux.case("Test 6: Readline timeout", function()
	listen_cb = function(conn)
		-- Try to readline with timeout, but no newline sent
		local dat, err = conn:readline("\n", 500)
		testaux.asserteq(dat, nil, "Test 6.1: Readline should timeout")
		testaux.asserteq(err, "read timeout", "Test 6.2: Should return 'read timeout' error")
		ch:push("timeout")
		-- Now complete line is available, should succeed
		local dat2, err2 = conn:readline("\n")
		testaux.asserteq(dat2, "hello world\n", "Test 6.3: Readline should succeed")
		testaux.asserteq(err2, nil, "Test 6.4: Should have no error")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 6.5: Connect to server")

	-- Send partial line without newline
	cfd:write("hello world")
	ch:pop()
	-- Send newline
	cfd:write("\n")
	cfd:close()
	testaux.success("Test 6 passed")
	waitdone()
end)

-- Test 7: Mixed read and readline with timeout
testaux.case("Test 7: Mixed read and readline with timeout", function()
	listen_cb = function(conn)
		-- Try to read 10 bytes with timeout, only 5 available
		local dat, err = conn:read(10, 500)
		testaux.asserteq(dat, nil, "Test 7.1: Read should timeout")
		testaux.asserteq(err, "read timeout", "Test 7.2: Should return 'read timeout' error")
		-- Now read the buffered 5 bytes
		local dat2, err2 = conn:read(5)
		testaux.asserteq(dat2, "HELLO", "Test 7.3: Should read buffered data")
		-- Try readline with timeout, no newline yet
		local dat3, err3 = conn:readline("\n", 500)
		ch:push("ready")
		testaux.asserteq(dat3, nil, "Test 7.4: Readline should timeout")
		testaux.asserteq(err3, "read timeout", "Test 7.5: Should return 'read timeout' error")
		-- Complete the line
		local dat4, err4 = conn:readline("\n")
		testaux.asserteq(dat4, "WORLD\n", "Test 7.6: Readline should succeed")

		-- Mix: read 3 bytes with timeout, only 2 available
		local dat5, err5 = conn:read(3, 500)
		ch:push("ready")
		testaux.asserteq(dat5, nil, "Test 7.7: Read should timeout")
		testaux.asserteq(err5, "read timeout", "Test 7.8: Should return 'read timeout' error")
		-- Readline should get the buffered "ab" plus "c\n"
		local dat6, err6 = conn:readline("\n")
		testaux.asserteq(dat6, "abc\n", "Test 7.9: Readline should get buffered + new data")

		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 7.10: Connect to server")

	-- Send 5 bytes, server expects 10
	cfd:write("HELLO")
	ch:pop()
	-- Send partial line without newline
	cfd:write("WORLD")
	-- Send newline
	cfd:write("\n")

	-- Send 2 bytes, server expects 3
	cfd:write("ab")
	ch:pop()
	-- Send remaining data with newline
	cfd:write("c\n")
	cfd:close()
	testaux.success("Test 7 passed")
	waitdone()
end)

-- Test 8: Connection closed during timeout wait
testaux.case("Test 8: Connection closed during timeout wait", function()
	listen_cb = function(conn)
		-- Try to read with a long timeout, but connection will close
		local dat, err = conn:read(100, 2000)
		assert_eof(dat, err,
			"Test 8.1: Read should return empty string on close",
			"Test 8.2: Should return 'end of file' error")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 8.3: Connect to server")
	cfd:close()
	testaux.success("Test 8 passed")
	waitdone()
end)

-- Test 9: Multiple sequential timeouts
testaux.case("Test 9: Multiple sequential timeouts", function()
	listen_cb = function(conn)
		-- First timeout
		local dat1, err1 = conn:read(5, 300)
		testaux.asserteq(dat1, nil, "Test 9.1: First read should timeout")
		testaux.asserteq(err1, "read timeout", "Test 9.2: Should return 'read timeout'")
		-- Second timeout
		local dat2, err2 = conn:read(5, 300)
		testaux.asserteq(dat2, nil, "Test 9.3: Second read should timeout")
		testaux.asserteq(err2, "read timeout", "Test 9.4: Should return 'read timeout'")
		-- Third timeout
		local dat3, err3 = conn:read(5, 300)
		testaux.asserteq(dat3, nil, "Test 9.5: Third read should timeout")
		testaux.asserteq(err3, "read timeout", "Test 9.6: Should return 'read timeout'")
		ch:push("ready")
		-- Finally succeed
		local dat4, err4 = conn:read(5)
		testaux.asserteq(dat4, "FINAL", "Test 9.7: Final read should succeed")
		conn:close()
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Test 9.8: Connect to server")
	ch:pop()
	-- Finally send data
	cfd:write("FINAL")
	cfd:close()
	testaux.success("Test 9 passed")
	waitdone()
end)

-- Test 10: TLS Connect Timeout (TCP)
testaux.case("Test 10: TLS Connect Timeout (TCP)", function()
	-- 192.0.2.1 is reserved for documentation (TEST-NET-1) and usually not reachable
	local fd, err = tls.connect("192.0.2.1:80", {timeout = 100})
	testaux.asserteq(fd, nil, "Test 10.1: Connect should timeout")
	-- The error message might vary slightly depending on system, but usually "timeout" or similar
	-- silly net returns "connect timeout" or "operation canceled" depending on implementation
	-- Let's just check it failed.
	testaux.success("Test 10 passed")
end)

-- Test 11: TLS Handshake Timeout
testaux.case("Test 11: TLS Handshake Timeout", function()
	local tcp = require "silly.net.tcp"
	local port = 10005
	local ch = channel.new()
	-- Spawn a raw TCP server that accepts but sends nothing
	local listenfd = tcp.listen {
		addr = "127.0.0.1:" .. port,
		accept = function(conn)
			conn:read(1) -- Read something to keep connection alive
			time.sleep(1000)
			conn:close()
			ch:push("done")
		end
	}
	-- Connect with timeout
	local fd, err = tls.connect("127.0.0.1:" .. port, {timeout = 200})
	testaux.asserteq(fd, nil, "Test 11.1: Connect should fail due to handshake timeout")
	testaux.asserteq(err, "read timeout", "Test 11.2: Error should be 'read timeout'")
	ch:pop()
	tcp.close(listenfd)
	testaux.success("Test 11 passed")
end)

-- Test 12: ALPN GC stability
testaux.case("Test 12: ALPN GC stability", function()
	local port = 10006
	local alpn_list = {"h2", "http/1.1"}
	local listener = tls.listen {
		addr = "127.0.0.1:" .. port,
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		alpnprotos = alpn_list,
		accept = function(conn)
			local ap = conn:alpnproto()
			testaux.asserteq(ap, "h2", "Test 12.2: Server ALPN should be h2")
			conn:close()
		end
	}

	-- Force GC and memory churn to stress ALPN userdata lifetime
	for i = 1, 64 do
		local t = {}
		for j = 1, 64 do
			t[j] = string.rep("x", 1024)
		end
	end
	collectgarbage("collect")
	collectgarbage("collect")

	local conn, err = tls.connect("127.0.0.1:" .. port, {alpnprotos = alpn_list})
	testaux.assertneq(conn, nil, "Test 12.1: Client connected for ALPN test")
	local apc = conn:alpnproto()
	testaux.asserteq(apc, "h2", "Test 12.3: Client ALPN should be h2")
	conn:close()
	listener:close()
	testaux.success("Test 12 passed")
end)

-- Test 13: TLS handshake error on plaintext server
testaux.case("Test 13: TLS handshake error", function()
	local tcp = require "silly.net.tcp"
	local port = 10007
	local listener = tcp.listen {
		addr = "127.0.0.1:" .. port,
		accept = function(conn)
			conn:write("HTTP/1.1 200 OK\r\n\r\n")
			conn:close()
		end
	}
	local c, err = tls.connect("127.0.0.1:" .. port, {timeout = 500})
	testaux.asserteq(c, nil, "Test 13.1: TLS connect should fail")
	testaux.assertneq(err, nil, "Test 13.2: TLS connect should return error")
	testaux.assertneq(err, "read timeout", "Test 13.3: handshake error should not be read timeout")
	listener:close()
	testaux.success("Test 13 passed")
end)

-- Cleanup EOF server
eof_server:close()
