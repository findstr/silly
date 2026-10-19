local silly = require "silly"
local task = require "silly.task"
local hive = require "silly.hive"
local time = require "silly.time"
local dns = require "silly.net.dns"
local tls = require "silly.net.tls"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"
local errno = require "silly.errno"
local pcall = silly.pcall
local ETIMEDOUT<const> = errno.TIMEDOUT
local EEOF<const> = errno.EOF
local EPIPE<const> = errno.PIPE
local ECONNRESET<const> = errno.CONNRESET
local ECONNABORTED<const> = errno.CONNABORTED

local is_iocp = silly.multiplexer == "iocp"

local function assert_eof(dat, err, msg_data, msg_err)
	-- Abrupt close (no close_notify) races: clean FIN -> EOF,
	-- RST -> CONNRESET, Windows transport abort -> CONNABORTED,
	-- RST with undrained server writes (TLS 1.3
	-- NewSessionTicket) -> EPIPE. All mean the peer is gone.
	local gone = err == EEOF or err == EPIPE or err == ECONNRESET or err == ECONNABORTED
	if dat ~= nil or not gone then
		local detail = string.format(" (dat=%q, err=%s)", dat, tostring(err))
		msg_data = msg_data .. detail
		msg_err = msg_err .. detail
	end
	if is_iocp then
		local ok = (dat == nil) and gone
		testaux.asserteq(ok, true, msg_err)
	else
		testaux.asserteq(gone, true, msg_err)
		testaux.asserteq(dat, nil, msg_data)
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
		print("--------err2", err2)
		assert_eof(dat2, err2,
			"Test 3.1.2: TLS read after close returns nil",
			"Test 3.1.3: TLS read after close returns EOF")

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
			"Test 3.2.1: TLS readline returns nil data",
			"Test 3.2.2: TLS readline returns EOF error")
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
			"Test 3.3.3: TLS read after abrupt close returns EOF")
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
			"Test 3.4.2: First read returns EOF")

		-- Second read should also get EOF
		local dat2, err2 = conn:read(1)
		assert_eof(dat2, err2,
			"Test 3.4.3: Second read returns empty string",
			"Test 3.4.4: Second read returns EOF")

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
		testaux.asserteq(err, ETIMEDOUT, "Test 4.2: Should return 'read timeout' error")
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
		testaux.asserteq(err, ETIMEDOUT, "Test 5.2: Should return 'read timeout' error")
		-- This read should succeed immediately with the 5 bytes in buffer
		local dat2, err2 = conn:read(5)
		testaux.asserteq(dat2, "12345", "Test 5.3: Second read should get complete data")
		testaux.asserteq(err2, nil, "Test 5.4: Should have no error")
		-- Try to read 10 bytes with timeout, client will send 8 bytes total
		local dat3, err3 = conn:read(10, 500)
		ch:push("timeout")
		testaux.asserteq(dat3, nil, "Test 5.5: Third read should timeout")
		testaux.asserteq(err3, ETIMEDOUT, "Test 5.6: Should return 'read timeout' error")
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
		testaux.asserteq(err, ETIMEDOUT, "Test 6.2: Should return 'read timeout' error")
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
		testaux.asserteq(err, ETIMEDOUT, "Test 7.2: Should return 'read timeout' error")
		-- Now read the buffered 5 bytes
		local dat2, err2 = conn:read(5)
		testaux.asserteq(dat2, "HELLO", "Test 7.3: Should read buffered data")
		-- Try readline with timeout, no newline yet
		local dat3, err3 = conn:readline("\n", 500)
		ch:push("ready")
		testaux.asserteq(dat3, nil, "Test 7.4: Readline should timeout")
		testaux.asserteq(err3, ETIMEDOUT, "Test 7.5: Should return 'read timeout' error")
		-- Complete the line
		local dat4, err4 = conn:readline("\n")
		testaux.asserteq(dat4, "WORLD\n", "Test 7.6: Readline should succeed")

		-- Mix: read 3 bytes with timeout, only 2 available
		local dat5, err5 = conn:read(3, 500)
		ch:push("ready")
		testaux.asserteq(dat5, nil, "Test 7.7: Read should timeout")
		testaux.asserteq(err5, ETIMEDOUT, "Test 7.8: Should return 'read timeout' error")
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
			"Test 8.2: Should return EOF error")
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
		testaux.asserteq(err1, ETIMEDOUT, "Test 9.2: Should return 'read timeout'")
		-- Second timeout
		local dat2, err2 = conn:read(5, 300)
		testaux.asserteq(dat2, nil, "Test 9.3: Second read should timeout")
		testaux.asserteq(err2, ETIMEDOUT, "Test 9.4: Should return 'read timeout'")
		-- Third timeout
		local dat3, err3 = conn:read(5, 300)
		testaux.asserteq(dat3, nil, "Test 9.5: Third read should timeout")
		testaux.asserteq(err3, ETIMEDOUT, "Test 9.6: Should return 'read timeout'")
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
	testaux.asserteq(err, ETIMEDOUT, "Test 11.2: Error should be 'read timeout'")
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
	testaux.assertneq(err, ETIMEDOUT, "Test 13.3: handshake error should not be read timeout")
	listener:close()
	testaux.success("Test 13 passed")
end)

-- Test 14: Write empty string should not error
testaux.case("Test 14: Write empty string", function()
	local port = 10008
	local ch = channel.new()
	local listener = tls.listen {
		addr = "127.0.0.1:" .. port,
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		accept = function(conn)
			local dat = conn:read(5)
			testaux.asserteq(dat, "hello", "Test 14.1: Server read data")
			conn:close()
			ch:push("done")
		end
	}

	local conn = tls.connect("127.0.0.1:" .. port)
	testaux.assertneq(conn, nil, "Test 14.2: Client connected")
	-- Write empty string should succeed
	local ok, err = conn:write("")
	testaux.asserteq(ok, true, "Test 14.3: Write empty string should succeed")
	-- Write real data after empty string
	ok, err = conn:write("hello")
	testaux.asserteq(ok, true, "Test 14.4: Write after empty should succeed")
	ch:pop()
	conn:close()
	listener:close()
	testaux.success("Test 14 passed")
end)

-- Test 15: Write table with empty strings
testaux.case("Test 15: Write table with empty strings", function()
	local port = 10009
	local ch = channel.new()
	local listener = tls.listen {
		addr = "127.0.0.1:" .. port,
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		accept = function(conn)
			local dat = conn:read(11)
			testaux.asserteq(dat, "hello world", "Test 15.1: Server read data")
			conn:close()
			ch:push("done")
		end
	}

	local conn = tls.connect("127.0.0.1:" .. port)
	testaux.assertneq(conn, nil, "Test 15.2: Client connected")
	-- Write table with empty strings mixed in
	local ok, err = conn:write({"", "hello", "", " world", ""})
	testaux.asserteq(ok, true, "Test 15.3: Write table with empty strings should succeed")
	ch:pop()
	conn:close()
	listener:close()
	testaux.success("Test 15 passed")
end)

-- Test 16: Write table of only empty strings
testaux.case("Test 16: Write table of only empty strings", function()
	local port = 10010
	local ch = channel.new()
	local listener = tls.listen {
		addr = "127.0.0.1:" .. port,
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		accept = function(conn)
			-- Client sends only empty strings, then real data
			local dat = conn:read(2)
			testaux.asserteq(dat, "ok", "Test 16.1: Server read data after empty writes")
			conn:close()
			ch:push("done")
		end
	}

	local conn = tls.connect("127.0.0.1:" .. port)
	testaux.assertneq(conn, nil, "Test 16.2: Client connected")
	-- Write table of only empty strings
	local ok, err = conn:write({"", "", ""})
	testaux.asserteq(ok, true, "Test 16.3: Write table of only empty strings should succeed")
	-- Verify connection still works
	ok, err = conn:write("ok")
	testaux.asserteq(ok, true, "Test 16.4: Write after empty table should succeed")
	ch:pop()
	conn:close()
	listener:close()
	testaux.success("Test 16 passed")
end)

-- Send invalid ciphertext after a real TLS handshake, keeping the peer open.
-- The read deadline detects swallowed errors; it must never satisfy the case.
for _, spec in ipairs({
	{id = 17, port = 10011, buffered = "", name = "Fatal TLS input wakes readers and rejects writes"},
	{id = 18, port = 10012, buffered = string.rep("good", 8192),
		name = "Fatal TLS input preserves buffered plaintext"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local net = require "silly.net"
		local accepted = channel.new()
		local finished = channel.new()
		local listener = assert(tls.listen {
			addr = "127.0.0.1:" .. spec.port,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				accepted:push(conn)
				local data, err = conn:read(#spec.buffered + 1, 1000)
				finished:push({data = data, err = err})
			end,
		})
		local peer<close> = assert(tls.connect("127.0.0.1:" .. spec.port))
		local conn<close> = testaux.await(accepted, "TLS reader registered")
		if #spec.buffered > 0 then
			assert(peer:write(spec.buffered))
		end
		-- Bypass TLS encryption to inject an unauthenticatable record.
		assert(net.tcpsend(peer.fd, "\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
		local result = testaux.await(finished, "fatal TLS error reaches reader")
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(result.data, nil, label .. "1: Incomplete read returns no data")
		testaux.asserteq(result.err, errno.TLS, label .. "2: TLS error is not swallowed or timed out")
		local native = require "silly.tls.tls"
		local _, native_err = native.read(conn.ssl, #spec.buffered + 1)
		testaux.asserteq(native_err, errno.TLS, label .. "2.1: Native reads report the saved TLS error")
		testaux.asserteq(conn.err, errno.TLS, label .. "2.2: TLS failure preserves its error in Lua")
		testaux.asserteq(native.error(conn.ssl), errno.TLS,
			label .. "3.1: Native error queries preserve the fatal reason")
		testaux.asserteq(not not conn:isalive(), false, label .. "3: Failed connection is not reusable")
		testaux.assertneq(conn.fd, nil, label .. "9: Fatal TLS input retains the socket ID until owner close")
		if #spec.buffered > 0 then
			testaux.asserteq(native.size(conn.ssl), #spec.buffered,
				label .. "3.2: Error queries leave authenticated plaintext untouched")
			local offset = 1
			for i, length in ipairs({1, 4095, 16384, 12288}) do
				local data, err = conn:read(length)
				testaux.asserteq(data, spec.buffered:sub(offset, offset + length - 1),
					label .. "4." .. i .. ": Previously authenticated bytes remain readable")
				testaux.asserteq(err, nil, label .. "4." .. i .. ".1: Buffered read succeeds")
				offset = offset + length
			end
		end
		local data, err = conn:read(1, 1000)
		testaux.asserteq(data, nil, label .. "5: Later read fails without waiting")
		testaux.asserteq(err, errno.TLS, label .. "6: Later read preserves the original TLS error")
		local ok, write_err = conn:write("after failure")
		testaux.asserteq(ok, false, label .. "7: Later writes are rejected")
		testaux.asserteq(write_err, errno.TLS, label .. "8: Later write preserves the TLS error")
		local closed, close_err = conn:close()
		testaux.asserteq(closed, true, label .. "10: Owner releases the socket")
		testaux.asserteq(close_err, nil, label .. "11: Owner close succeeds")
		testaux.asserteq(conn.fd, nil, label .. "11.1: Owner close detaches the socket ID")
		local _, saved_err = conn:read(1)
		testaux.asserteq(saved_err, errno.TLS, label .. "12: Owner close preserves the fatal reason")
		testaux.asserteq(conn.err, errno.TLS, label .. "12.2: Owner close preserves the saved Lua error")
		local _, native_err = native.handshake(conn.ssl)
		testaux.asserteq(native_err, errno.TLS, label .. "13: Native handshake preserves the fatal reason after close")
		local _, native_err = native.write(conn.ssl, "native write after close")
		testaux.asserteq(native_err, errno.TLS, label .. "14: Native writes preserve the fatal reason after close")
		listener:close()
	end)
end

testaux.case("Test 19: TLS write before handshake is buffered until input arrives", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local payload = "needs handshake"
	local handshaken = channel.new()
	local received = channel.new()
	local finished = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:10013",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			local data, err = conn:read(#payload + 1, 1000)
			conn:write("ack")
			finished:push({data = data, err = err})
			conn:close()
		end,
	})
	local state, ready
	local fd = assert(net.tcpconnect("127.0.0.1:10013", {
		data = function(_, ptr, size)
			local _, err = native.push(state, ptr, size)
			if not ready then
				if err then
					ready = true
					handshaken:push({err = err})
					return
				end
				local ret, detail = native.handshake(state)
				if ret >= 0 then
					ready = true
					handshaken:push({ret = ret, detail = detail})
				end
			end
			local data = native.read(state, 3)
			if data or err then
				received:push({data = data, err = err})
			end
		end,
		close = function(_, err)
			if not ready then
				ready = true
				handshaken:push({err = err})
			end
			received:push({err = err})
		end,
	}))
	state = native.open(ctx.client(), fd)
	local ok, err = native.write(state, payload)
	testaux.asserteq(ok, true, "Test 19.1: Write is accepted before handshake input")
	testaux.asserteq(err, nil, "Test 19.2: Buffered write does not expose AGAIN")
	local result = testaux.await(handshaken, "retryable write handshake completes")
	testaux.asserteq(result.ret, 1, "Test 19.3: Retryable write flushes its handshake output")
	assert(native.write(state, "!"))
	result = testaux.await(received, "native TLS write retry response")
	testaux.asserteq(result.data, "ack", "Test 19.5: Retried connection receives a response")
	result = testaux.await(finished, "native TLS peer received retry")
	testaux.asserteq(result.data, payload .. "!", "Test 19.6: Retry sends the payload exactly once")
	testaux.asserteq(result.err, nil, "Test 19.7: Peer receives complete retry data")
	net.close(fd)
	listener:close()
end)

for _, spec in ipairs({
	{id = 20, err = errno.TLS, name = "Fatal TLS writes release pending reads"},
	{id = 21, err = errno.CLOSED, name = "Closed TLS writes release pending reads"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local native = require "silly.tls.tls"
		local accepted = channel.new()
		local finished = channel.new()
		local address = "127.0.0.1:" .. (10000 + spec.id)
		local listener = assert(tls.listen {
			addr = address,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				accepted:push(conn)
				local data, err = conn:read(1, 1000)
				finished:push({data = data, err = err})
			end,
		})
		local peer<close> = assert(tls.connect(address))
		local conn<close> = testaux.await(accepted, "TLS reader registered before write failure")
		-- Change native state without dispatching an input event to the Lua reader.
		local write = native.write
		native.write = function(ssl, data)
			if ssl == conn.ssl then
				if spec.err == errno.TLS then
					local c = require "test.aux.c"
					native.push(ssl, c.new("\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
				else
					native.close(ssl)
				end
			end
			return write(ssl, data)
		end
		local protected, ok, err = pcall(conn.write, conn, "probe")
		native.write = write
		assert(protected, ok)
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(ok, false, label .. "1: Write reports failure")
		testaux.asserteq(err, spec.err, label .. "2: Write preserves its error")
		testaux.asserteq(native.error(conn.ssl), spec.err, label .. "2.1: Native TLS retains the write error")
		testaux.asserteq(conn.err, spec.err, label .. "2.2: Lua retains the native write error")
		testaux.assertneq(conn.fd, nil, label .. "8: Fatal write retains the socket ID until owner close")
		local result = testaux.await(finished, "fatal write releases pending read")
		testaux.asserteq(result.data, nil, label .. "3: Reader receives no data")
		testaux.asserteq(result.err, spec.err, label .. "4: Reader receives the write failure without timing out")
		testaux.asserteq(not not conn:isalive(), false, label .. "5: Fatal write disables connection reuse")
		local stale_fd = conn.fd
		local closed, close_err = conn:close()
		testaux.asserteq(closed, true, label .. "11: Owner releases the socket after fatal write")
		testaux.asserteq(close_err, nil, label .. "12: Owner close succeeds")
		local _, read_err = conn:read(1)
		local _, write_err = conn:write("after owner close")
		testaux.asserteq(read_err, spec.err, label .. "9: Owner close preserves the fatal read reason")
		testaux.asserteq(write_err, spec.err, label .. "10: Owner close preserves the fatal write reason")
		local data, err = peer:read(1, 1000)
		if err == errno.TLS then
			testaux.asserteq(data, nil, label .. "6: Peer receives the fatal TLS alert")
		else
			assert_eof(data, err, label .. "6: Peer receives no data", label .. "7: Fatal write closes the transport")
		end
		local ctx = require "silly.tls.ctx"
		local state = native.open(ctx.client(), stale_fd)
		local ok, err = native.write(state, "closed transport")
		testaux.asserteq(ok, false, label .. "13: Native handshake output cannot use the released socket")
		testaux.asserteq(err, errno.CLOSED, label .. "14: Native flush error replaces the retryable result")
		listener:close()
	end)
end

testaux.case("Test 22: Reading beyond a paused TLS buffer resumes receiving", function()
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:10022",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect("127.0.0.1:10022"))
	local conn<close> = testaux.await(accepted, "TLS buffer limit peer accepted")
	conn:limit(1)
	assert(peer:write("hello"))
	testaux.asserteq(conn:read(1, 1000), "h", "Test 22.1: Initial read leaves buffered data above the limit")
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local function requests()
		local _, _, _, count = metrics.netstat()
		return count
	end
	local reading = channel.new()
	local finished = channel.new()
	task.fork(function()
		reading:push(true)
		local data, err = conn:read(5, 1000)
		finished:push({data = data, err = err})
	end)
	testaux.await(reading, "TLS read resumes receiving before the limit changes")
	local before = requests()
	local data, err = native.read(conn.ssl, 5)
	testaux.asserteq(data, nil, "Test 22.1.1: Partial input cannot satisfy the byte read")
	testaux.asserteq(err, nil, "Test 22.1.2: Partial input remains pending without an error")
	data, err = native.read(conn.ssl, "\n")
	testaux.asserteq(data, nil, "Test 22.1.3: Missing delimiters leave the line read pending")
	testaux.asserteq(err, nil, "Test 22.1.4: An incomplete line is not an error")
	conn:limit(0)
	testaux.asserteq(requests(), before, "Test 22.1.5: Limit changes preserve the waiting exemption")
	assert(peer:write("!"))
	local result = testaux.await(finished, "TLS read completes after the limit changes")
	testaux.asserteq(result.err, nil, "Test 22.2: Paused connection resumes without timing out")
	testaux.asserteq(result.data, "ello!", "Test 22.3: Larger read receives the missing bytes")
	data, err = conn:read(1, 10)
	testaux.asserteq(data, nil, "Test 22.5: A pending read can time out under a zero limit")
	testaux.asserteq(err, errno.TIMEDOUT, "Test 22.6: The read deadline reports timeout")
	before = requests()
	conn:limit(nil)
	testaux.asserteq(requests() - before, 1, "Test 22.8: Timeout restores the limit; removing it resumes receiving")
	assert(peer:write("ok"))
	testaux.asserteq(conn:read(2, 1000), "ok", "Test 22.9: Receiving continues after removing the limit")
	listener:close()
end)

testaux.case("Test 23: Queued TLS input is discarded after a fatal write", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local accepted = channel.new()
	local finished = channel.new()
	local target
	local onclose
	local listen = net.tcplisten
	net.tcplisten = function(addr, event, backlog)
		onclose = event.close
		return listen(addr, {
			accept = event.accept,
			close = event.close,
			data = function(fd, ptr, size)
				if target and fd == target.fd then
					-- Fail just before handing an already delivered socket message to TLS.
					target:write("probe")
				end
				event.data(fd, ptr, size)
			end,
		}, backlog)
	end
	local protected, listener = pcall(tls.listen, {
		addr = "127.0.0.1:10023",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
			local data, err = conn:read(1, 1000)
			finished:push({data = data, err = err})
		end,
	})
	net.tcplisten = listen
	assert(protected, listener)
	assert(listener)
	local peer<close> = assert(tls.connect("127.0.0.1:10023"))
	local conn<close> = testaux.await(accepted, "TLS queued input peer accepted")
	target = conn
	local write, push = native.write, native.push
	local pushes = 0
	native.write = function(ssl, data)
		if ssl == conn.ssl then
			local c = require "test.aux.c"
			push(ssl, c.new("\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
		end
		return write(ssl, data)
	end
	native.push = function(ssl, ptr, size)
		if ssl == conn.ssl then
			pushes = pushes + 1
		end
		return push(ssl, ptr, size)
	end
	local protected, result = pcall(function()
		assert(peer:write("p"))
		return testaux.await(finished, "queued input discarded after fatal write")
	end)
	native.write = write
	native.push = push
	assert(protected, result)
	testaux.asserteq(result.data, nil, "Test 23.1: Failed connection does not deliver the queued input")
	testaux.asserteq(result.err, errno.TLS, "Test 23.2: Waiting read receives the fatal write error")
	testaux.asserteq(pushes, 1, "Test 23.3: Native TLS owns discarding input after a fatal error")
	testaux.asserteq(conn:unreadbytes(), 0, "Test 23.4: Queued input does not enter the plaintext buffer")
	-- A later socket error must not replace the original TLS failure.
	onclose(conn.fd, errno.CONNRESET)
	testaux.asserteq(conn.err, errno.TLS, "Test 23.5.1: Later socket close preserves the TLS error in Lua")
	local _, read_err = conn:read(1)
	local _, write_err = conn:write("after socket close")
	testaux.asserteq(read_err, errno.TLS, "Test 23.5: Later socket close preserves the original read error")
	testaux.asserteq(write_err, errno.TLS, "Test 23.6: Later socket close preserves the original write error")
	listener:close()
end)

for _, spec in ipairs({
	{id = 24, command = "w", name = "TLS renegotiation buffers writes without exposing AGAIN"},
	{id = 25, command = "f", name = "Fatal TLS input discards writes queued during renegotiation"},
	{id = 26, command = "w", limit = 0, name = "TLS renegotiation resumes paused receiving to complete writes"},
	{id = 27, command = "t", close = true, name = "Closing TLS abandons writes blocked on renegotiation"},
	{id = 29, command = "t", close = true, gc = true, name = "TLS finalization releases blocked writes"},
	{id = 36, command = "e", name = "TLS EOF interrupts writes blocked on renegotiation"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local c = require "test.aux.c"
		local native = require "silly.tls.tls"
		local started = channel.new()
		local finished = channel.new()
		local expected = string.rep("a", 513) .. string.rep("b", 32768) .. "tail!"
		local port = 10000 + spec.id
		local listener = c.listen("127.0.0.1", port, 8)
		local control_listener = c.listen("127.0.0.1", port + 100, 8)
		local bee = hive.spawn [[
			local c = require "test.aux.c"
			return function(listener, control_listener, cert, key, size)
				local control = c.accept(control_listener)
				local fd = c.accept(listener)
				c.close(listener)
				c.close(control_listener)
				local data, err = c.tlsreneg(fd, control, cert, key, size)
				c.close(fd)
				c.close(control)
				return {data = data, err = err}
			end
		]]
		task.fork(function()
			finished:push(hive.invoke(bee, listener, control_listener,
				testaux.CERT_A, testaux.KEY_A, #expected))
		end)
		local control = c.connect("127.0.0.1", port + 100)
		local conn = assert(tls.connect("127.0.0.1:" .. port))
		local cleanup<close> = setmetatable({conn}, {__close = function(self)
			local s = self[1]
			if s then
				s:close()
			end
		end})
		local state = conn.ssl
		local push = native.push
		local observed = false
		native.push = function(ssl, ptr, size)
			local total, err = push(ssl, ptr, size)
			if ssl == conn.ssl and not observed then
				local ret = native.handshake(ssl)
				if ret < 0 then
					observed = true
					started:push(true)
				end
			end
			return total, err
		end
		c.send(control, "r")
		local protected, failure = pcall(testaux.await, started, "TLS renegotiation started")
		native.push = push
		if not protected then
			c.close(control)
			error(failure)
		end
		if spec.limit then
			conn:limit(spec.limit)
		end
		local first_ok, first_err = conn:write(string.rep("a", 513))
		local first_pending = native.sendsize(state)
		local second_ok, second_err = conn:write({"", string.rep("b", 32768), "tail", ""})
		local second_pending = native.sendsize(state)
		local third_ok, third_err = conn:write("!")
		local third_pending = native.sendsize(state)
		if spec.limit then
			-- Reapplying the limit must still allow input to complete pending TLS writes.
			conn:limit(1)
			conn:limit(spec.limit)
		end
		collectgarbage("collect")
		local pending = conn:unsentbytes()
		local accepted = first_ok and second_ok and third_ok
		local read_result
		if accepted and (spec.command == "f" or spec.command == "e" or spec.close and not spec.gc) then
			local reading = channel.new()
			read_result = channel.new()
			task.fork(function()
				reading:push(true)
				local data, err = conn:read(2, 1000)
				read_result:push({data = data, err = err})
			end)
			testaux.await(reading, "TLS reader registered before failure or owner close")
		end
		local closed, close_err
		if accepted and spec.close then
			if spec.gc then
				cleanup[1] = nil
				conn = nil
				collectgarbage("collect")
			else
				closed, close_err = conn:close()
			end
		end
		c.send(control, accepted and spec.command or "a")
		local data, err
		local completed
		if accepted then
			if spec.command == "f" or spec.command == "e" then
				local result = testaux.await(read_result, "TLS fatal input wakes reader")
				data, err = result.data, result.err
			else
				completed = testaux.recv(control, 1)
				if not spec.close then
					data, err = conn:read(2, 1000)
					conn:close()
				end
			end
		end
		local result = testaux.await(finished, "TLS renegotiation peer finished", 10000)
		c.close(control)
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(first_ok, true, label .. "1: Initial write is accepted during renegotiation")
		testaux.asserteq(first_err, nil, label .. "2: Initial write does not expose AGAIN")
		testaux.assertle(513, first_pending, label .. "2.1: Unsent bytes include the initial buffered write")
		testaux.asserteq(second_ok, true, label .. "3: Array write is queued behind the initial write")
		testaux.asserteq(second_err, nil, label .. "4: Queued array has no error")
		testaux.assertle(33285, second_pending, label .. "4.1: Unsent bytes include appended plaintext")
		testaux.asserteq(third_ok, true, label .. "5: Further writes remain ordered")
		testaux.asserteq(third_err, nil, label .. "6: Further write has no error")
		testaux.assertle(33286, third_pending, label .. "6.1: Unsent bytes include the final append")
		testaux.assertle(#expected, pending, label .. "7: Unsent bytes include buffered plaintext")
		testaux.asserteq(result.err, nil, label .. "8: OpenSSL peer completes without error")
		if spec.command == "w" then
			testaux.asserteq(completed, "d", label .. "8.1: Peer receives queued writes before caller reads")
			testaux.asserteq(data, "ok", label .. "9: Buffered writes complete without caller retry")
			testaux.asserteq(err, nil, label .. "10: Response read succeeds")
			testaux.asserteq(result.data, expected, label .. "11: Peer receives all writes exactly once and in order")
		elseif spec.command == "f" then
			testaux.asserteq(data, nil, label .. "9: Fatal input wakes the pending reader")
			testaux.asserteq(err, errno.TLS, label .. "10: Pending reader receives the TLS error")
			local ok, write_err = conn:write("after failure")
			testaux.asserteq(ok, false, label .. "11: Further writes are rejected")
			testaux.asserteq(write_err, errno.TLS, label .. "12: Further write preserves the fatal error")
		elseif spec.command == "e" then
			testaux.asserteq(data, nil, label .. "9: Peer EOF wakes the pending reader")
			testaux.asserteq(err, errno.EOF, label .. "10: Incomplete renegotiation reports EOF")
			testaux.asserteq(result.data, "", label .. "11: Interrupted writes are not partially delivered")
		elseif spec.gc then
			testaux.asserteq(completed, "d", label .. "9: Peer observes close without completing renegotiation")
			testaux.asserteq(result.data, "", label .. "10: Finalization abandons blocked plaintext")
		else
			testaux.asserteq(closed, true, label .. "9: Owner closes the connection with writes pending")
			local stopped = testaux.await(read_result, "owner close wakes the reader")
			testaux.asserteq(stopped.data, nil, label .. "9.1: Owner close interrupts the pending reader")
			testaux.asserteq(stopped.err, errno.CLOSED, label .. "9.2: Pending reader receives owner close")
			testaux.asserteq(close_err, nil, label .. "10: Owner close succeeds")
			local ok, write_err = conn:write("after close")
			testaux.asserteq(ok, false, label .. "11: Further writes are rejected")
			testaux.asserteq(write_err, errno.CLOSED, label .. "12: Further write reports owner close")
			testaux.asserteq(completed, "d", label .. "14: Peer observes close without completing renegotiation")
			testaux.asserteq(result.data, "", label .. "14.1: Owner close abandons blocked plaintext")
		end
		if spec.close and not spec.gc then
			testaux.asserteq(conn:unsentbytes(), 0, label .. "13: Closed connection has no active send queue")
		else
			-- A fatal alert can still be queued on the underlying socket.
			local net = require "silly.net"
			local pending = conn and conn.fd and net.sendsize(conn.fd) or 0
			testaux.assertle(native.sendsize(state), pending, label .. "13: Only transport output remains queued")
		end
		if spec.close then
			local ok, err = native.write(state, "native write after close")
			testaux.asserteq(ok, false, label .. "15: Native writes reject the closed TLS state")
			testaux.asserteq(err, errno.CLOSED, label .. "16: Native writes report owner close")
			local status, err = native.handshake(state)
			testaux.asserteq(status, 0, label .. "17: Closed TLS state cannot restart its handshake")
			testaux.asserteq(err, errno.CLOSED, label .. "18: Native handshake reports owner close")
			local data, err = native.read(state, "\n")
			testaux.asserteq(data, nil, label .. "19: Native reads reject the closed TLS state")
			testaux.asserteq(err, errno.CLOSED, label .. "20: Native reads report owner close")
			testaux.asserteq(native.sendsize(state), 0, label .. "21: Closed TLS has no send queue")
			local _, err = native.push(state, c.new("input after owner close"))
			testaux.asserteq(err, errno.CLOSED, label .. "22: Closed TLS discards late input safely")
			testaux.asserteq(native.close(state), nil, label .. "23: Repeated native close is harmless")
		end
	end)
end

testaux.case("Test 30: Socket errors preserve buffered TLS data and survive owner close", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local accepted = channel.new()
	local received = channel.new()
	local onclose
	local listen = net.tcplisten
	net.tcplisten = function(addr, event, backlog)
		onclose = event.close
		return listen(addr, event, backlog)
	end
	local protected, listener = pcall(tls.listen, {
		addr = "127.0.0.1:10030",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
			local data, err = conn:read(1, 1000)
			received:push({data = data, err = err})
		end,
	})
	net.tcplisten = listen
	assert(protected, listener)
	assert(listener)
	local peer<close> = assert(tls.connect("127.0.0.1:10030"))
	local conn<close> = testaux.await(accepted, "TLS socket error peer accepted")
	assert(peer:write("hello"))
	local result = testaux.await(received, "TLS input buffered before socket close")
	testaux.asserteq(result.data, "h", "Test 30.1: Initial read leaves buffered plaintext")
	onclose(conn.fd, errno.CONNRESET)
	testaux.asserteq(conn.err, errno.CONNRESET, "Test 30.2: Lua retains the socket error")
	testaux.asserteq(native.error(conn.ssl), nil, "Test 30.3: Socket events do not replace native TLS state")
	local data, err = conn:read(4)
	testaux.asserteq(data, "ello", "Test 30.5: Buffered plaintext precedes the socket error")
	testaux.asserteq(err, nil, "Test 30.6: Buffered reads succeed after socket close")
	local _, read_err = conn:read(1)
	local _, write_err = conn:write("after socket close")
	testaux.asserteq(read_err, errno.CONNRESET, "Test 30.7: Unfulfilled reads return the socket error")
	testaux.asserteq(write_err, errno.CONNRESET, "Test 30.8: Writes return the socket error")
	conn:close()
	local _, read_err = conn:read("\n")
	local _, write_err = conn:write("after owner close")
	testaux.asserteq(read_err, errno.CONNRESET, "Test 30.9: Owner close preserves the socket read error")
	testaux.asserteq(write_err, errno.CONNRESET, "Test 30.10: Owner close preserves the socket write error")
	local peer2<close> = assert(tls.connect("127.0.0.1:10030"))
	local conn2<close> = testaux.await(accepted, "TLS reader registered before socket and owner close")
	onclose(conn2.fd, errno.CONNRESET)
	conn2:close()
	local stopped = testaux.await(received, "TLS reader resumes after both close operations")
	testaux.asserteq(stopped.data, nil, "Test 30.11: Closing the socket interrupts the pending reader")
	testaux.asserteq(stopped.err, errno.CONNRESET,
		"Test 30.12: Owner close before resumption preserves the original socket error")
	listener:close()
end)

for _, spec in ipairs({
	{id = 31, delim = 5, name = "Peer close wakes a byte read beyond the TLS buffer limit"},
	{id = 32, delim = "\n", name = "Peer close wakes a line read beyond the TLS buffer limit"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local accepted = channel.new()
		local reading = channel.new()
		local finished = channel.new()
		local address = "127.0.0.1:" .. (10000 + spec.id)
		local listener = assert(tls.listen {
			addr = address,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				accepted:push(conn)
			end,
		})
		local peer<close> = assert(tls.connect(address))
		local conn<close> = testaux.await(accepted, "TLS close test peer accepted")
		conn:limit(1)
		assert(peer:write("hello"))
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(conn:read(1, 1000), "h", label .. "1: Initial read leaves buffered plaintext")
		task.fork(function()
			reading:push(true)
			local data, err = conn:read(spec.delim, 1000)
			finished:push({data = data, err = err})
		end)
		testaux.await(reading, "TLS read registered while receiving was paused")
		conn:limit(0)
		peer:close()
		local result = testaux.await(finished, "peer close wakes the TLS reader")
		assert_eof(result.data, result.err, label .. "2: Incomplete read returns no data",
			label .. "3: Peer close wakes the reader without timing out")
		local data, err = conn:read(4)
		testaux.asserteq(data, "ello", label .. "4: Peer close preserves buffered plaintext")
		testaux.asserteq(err, nil, label .. "5: Buffered read succeeds after peer close")
		listener:close()
	end)
end

testaux.case("Test 33: Native TLS write rejects pointer arguments even after close", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local c = require "test.aux.c"
	local net = require "silly.net"
	local state = native.open(ctx.client(), -1)
	for _, closed in ipairs({false, true}) do
		if closed then
			native.close(state)
		end
		local ptr = c.new("owned by caller")
		local ok = pcall(native.write, state, ptr)
		net.free(ptr)
		testaux.asserteq(ok, false, "Test 33.1: Invalid write types are never silently accepted")
	end
end)

testaux.case("Test 34: Native TLS push validates input before taking ownership", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local c = require "test.aux.c"
	local net = require "silly.net"
	local state = native.open(ctx.client(), -1)
	native.close(state)
	local invalid_type = pcall(native.push, state, "not a pointer", 0)
	local ptr = c.new("owned by caller until validation succeeds")
	local invalid_size = pcall(native.push, state, ptr, -1)
	if not invalid_size then
		net.free(ptr)
	end
	testaux.asserteq(invalid_type, false, "Test 34.1: Closed TLS still rejects an invalid pointer type")
	testaux.asserteq(invalid_size, false, "Test 34.2: Negative input sizes do not transfer ownership")
end)

testaux.case("Test 35: Transport send failures do not become TLS protocol errors", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local tcp = require "silly.net.tcp"
	local finished = channel.new()
	local listener = assert(tcp.listen {
		addr = "127.0.0.1:10035",
		accept = function(conn)
			conn:read(1, 1000)
			conn:close()
			finished:push(true)
		end,
	})
	local peer = assert(tcp.connect("127.0.0.1:10035"))
	local fd = peer.fd
	peer:close()
	testaux.await(finished, "transport has closed before native TLS attempts to send")
	listener:close()
	local state = native.open(ctx.client(), fd)
	local ok, err = native.write(state, "closed transport")
	local tls_err = native.error(state)
	local close_err = native.close(state)
	testaux.asserteq(ok, false, "Test 35.1: Native writes report the failed transport submission")
	testaux.asserteq(err, errno.CLOSED, "Test 35.2: The transport error is preserved")
	testaux.asserteq(tls_err, nil, "Test 35.3: A failed send does not invent an OpenSSL error")
	testaux.asserteq(close_err, nil, "Test 35.4: Native close does not replay a transport error")
	testaux.asserteq(native.error(state), errno.CLOSED, "Test 35.5: Owner close releases the TLS object")
end)

for _, spec in ipairs({
	{id = 37, client = true, name = "Transport errors reject a completed client handshake"},
	{id = 38, client = false, name = "Transport errors reject a completed server handshake"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local native = require "silly.tls.tls"
		local open, push, close = native.open, native.push, native.close
		local finalized = channel.new()
		local target, listener
		local injected, accepted, closed = false, false, false
		native.open = function(ctx, fd, hostname, alpn)
			local state = open(ctx, fd, hostname, alpn)
			if (hostname ~= nil) == spec.client then
				target = state
			end
			return state
		end
		native.push = function(state, ptr, size)
			local total, err = push(state, ptr, size)
			if state == target and not err and not injected and native.handshake(state) == 1 then
				injected = true
				return total, errno.CLOSED
			end
			return total, err
		end
		native.close = function(state, notify)
			local err = close(state, notify)
			if state == target and not closed then
				closed = true
				finalized:push(true)
			end
			return err
		end
		local protected, result = pcall(function()
			local address = "127.0.0.1:" .. (10000 + spec.id)
			listener = assert(tls.listen {
				addr = address,
				certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
				accept = function(conn)
					accepted = true
					conn:close()
				end,
			})
			local conn, err = tls.connect(address, {hostname = "localhost", timeout = 1000})
			if conn then
				conn:close()
			end
			testaux.await(finalized, "failed handshake releases its TLS state")
			return {conn = conn, err = err}
		end)
		native.open, native.push, native.close = open, push, close
		if listener then
			listener:close()
		end
		assert(protected, result)
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(injected, true, label .. "1: The real handshake reaches the failing I/O boundary")
		if spec.client then
			testaux.asserteq(result.conn, nil, label .. "2: Client setup does not return a failed connection")
			testaux.asserteq(result.err, errno.CLOSED, label .. "3: Client setup returns the transport error")
		else
			testaux.asserteq(accepted, false, label .. "2: Server does not accept a failed connection")
		end
	end)
end

testaux.case("Test 39: TLS receive growth rejects sizes beyond the native buffer range", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local c = require "test.aux.c"
	local state = native.open(ctx.client(), -1)
	-- Only metadata grows; no multi-gigabyte allocation is needed.
	local oldsize = native.dbg_readsize(state, 0x7fffffff - 15)
	local _, err = native.push(state, c.new(""))
	native.dbg_readsize(state, oldsize)
	local pending = native.sendsize(state)
	native.close(state)
	testaux.asserteq(err, errno.TLS, "Test 39.1: Receive overflow is reported without wrapping the size")
	testaux.asserteq(pending, 0, "Test 39.2: Receive failure leaves no plaintext write queued")
end)

testaux.case("Test 40: Native TLS reads reject lengths before narrowing to int", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local state = native.open(ctx.client(), -1)
	local wrapped = pcall(native.read, state, 0x100000001)
	local negative = pcall(native.read, state, -1)
	local maximum = pcall(native.read, state, 0x7fffffff)
	native.close(state)
	testaux.asserteq(wrapped, false, "Test 40.1: Oversized read counts cannot wrap to a shorter read")
	testaux.asserteq(negative, false, "Test 40.2: Negative read counts are rejected")
	testaux.asserteq(maximum, true, "Test 40.3: The largest representable count remains valid")
end)

testaux.case("Test 41: TLS buffer compaction reuses existing capacity", function()
	local native = require "silly.tls.tls"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:10041",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect("127.0.0.1:10041"))
	local conn<close> = testaux.await(accepted, "TLS compaction peer accepted")
	assert(conn:write(string.rep("a", 64)))
	local first = peer:read(48, 1000)
	local capacity = native.dbg_readcap(peer.ssl)
	assert(conn:write(string.rep("b", 48)))
	local data, err = peer:read(64, 1000)
	local after = native.dbg_readcap(peer.ssl)
	listener:close()
	testaux.asserteq(first, string.rep("a", 48), "Test 41.1: Initial read leaves a consumed prefix")
	testaux.asserteq(data, string.rep("a", 16) .. string.rep("b", 48),
		"Test 41.2: Compaction preserves unread bytes and appended data")
	testaux.asserteq(err, nil, "Test 41.3: Compacted input remains readable")
	testaux.asserteq(after, capacity, "Test 41.4: Reclaimed prefix space avoids buffer growth")
end)

for _, spec in ipairs({
	{id = 42, fatal = true, name = "Queued fatal TLS input resumes receiving without a reader"},
	{id = 43, name = "Queued TLS close_notify resumes receiving without a reader"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local net = require "silly.net"
		local native = require "silly.tls.tls"
		local buffer = require "silly.adt.buffer"
		local c = require "test.aux.c"
		local accepted = channel.new()
		local processed = channel.new()
		local closed = channel.new()
		local fragmented = channel.new()
		local queued = buffer.new()
		local target, intercepted, header
		local listen = net.tcplisten
		net.tcplisten = function(addr, event, backlog)
			return listen(addr, {
				accept = event.accept,
				close = function(fd, err)
					event.close(fd, err)
					if target and target.fd == fd then
						closed:push({err = err})
					end
				end,
				data = function(fd, ptr, size)
					local paused
					if target and target.fd == fd and not intercepted then
						buffer.append(queued, ptr, size)
						header = header or buffer.read(queued, 5)
						if not header then
							return
						end
						local length = (header:byte(4) << 8) | header:byte(5)
						local body = buffer.read(queued, length)
						if not body then
							fragmented:push(true)
							return
						end
						ptr, size = c.new(header .. body .. buffer.readall(queued))
						intercepted = true
						-- This message was delivered before the pause reached the socket thread.
						target:limit(0)
						paused = not native.readenable(target.ssl, false)
					end
					event.data(fd, ptr, size)
					if paused ~= nil then
						processed:push({paused = paused, co = target.co, err = native.error(target.ssl)})
					end
				end,
			}, backlog)
		end
		local address = "127.0.0.1:" .. (10000 + spec.id)
		local protected, listener = pcall(tls.listen, {
			addr = address,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				accepted:push(conn)
			end,
		})
		net.tcplisten = listen
		assert(protected, listener)
		assert(listener)
		local peer<close> = assert(tls.connect(address))
		local conn<close> = testaux.await(accepted, "TLS peer accepted without starting a read")
		-- Drain handshake output before close so the peer sends FIN rather than a reset.
		assert(conn:write("ready"))
		assert(peer:read(5, 1000) == "ready")
		target = conn
		if spec.fatal then
			assert(net.tcpsend(peer.fd, "\x17\x03\x03\x00\x20"))
			testaux.await(fragmented, "partial TLS record received before its payload")
			assert(net.tcpsend(peer.fd, string.rep("\x00", 32)))
		else
			-- Keep TCP open until the queued close_notify has been processed.
			assert(native.close(peer.ssl, true) == nil)
		end
		local result = testaux.await(processed, "queued TLS input processed after pausing")
		local data, peer_err
		if spec.fatal then
			data, peer_err = peer:read(1, 1000)
		end
		peer:close()
		local observed, detail = pcall(testaux.await, closed, "FIN after queued TLS input", 1000)
		conn:close()
		listener:close()
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(result.paused, true, label .. "1: Receiving pauses before processing queued input")
		testaux.asserteq(result.co, nil, label .. "2: No reader can resume receiving")
		testaux.asserteq(result.err, spec.fatal and errno.TLS or errno.EOF,
			label .. "3: Queued input records the expected TLS result")
		testaux.asserteq(observed, true, label .. "4: FIN arrives without starting a read")
		testaux.asserteq(detail.err, errno.EOF, label .. "5: Peer closes the transport cleanly")
		if spec.fatal then
			testaux.asserteq(data, nil, label .. "6: Fatal TLS alert contains no application data")
			testaux.asserteq(peer_err, errno.TLS, label .. "7: Peer consumes the fatal TLS alert before close")
		end
	end)
end

testaux.case("Test 44: Native TLS receive control reports its effective state", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:10044",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect("127.0.0.1:10044"))
	local conn<close> = testaux.await(accepted, "TLS receive control peer accepted")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	local _, _, _, before = metrics.netstat()
	local paused = native.readenable(conn.ssl, false)
	local _, _, _, after_pause = metrics.netstat()
	local paused_again = native.readenable(conn.ssl, false)
	local _, _, _, after_repeat = metrics.netstat()
	local resumed = native.readenable(conn.ssl, true)
	local _, _, _, after_resume = metrics.netstat()
	local resumed_again = native.readenable(conn.ssl, true)
	local _, _, _, after_enabled = metrics.netstat()
	testaux.asserteq(paused, false, "Test 44.1: Pausing returns the effective disabled state")
	testaux.asserteq(after_pause - before, 1, "Test 44.2: Pausing sends one socket command")
	testaux.asserteq(paused_again, false, "Test 44.3: Repeated pause remains disabled")
	testaux.asserteq(after_repeat, after_pause, "Test 44.4: Repeated pause sends no socket command")
	testaux.asserteq(resumed, true, "Test 44.5: Resuming returns the effective enabled state")
	testaux.asserteq(after_resume - after_repeat, 1, "Test 44.6: Resuming sends one socket command")
	testaux.asserteq(resumed_again, true, "Test 44.7: Repeated resume remains enabled")
	testaux.asserteq(after_enabled, after_resume, "Test 44.8: Repeated resume sends no socket command")
	assert(peer:write("ok"))
	testaux.asserteq(conn:read(2, 1000), "ok", "Test 44.9: Resumed transport delivers application data")
	conn:close()
	local _, _, _, before_closed = metrics.netstat()
	local enabled = native.readenable(conn.ssl, true)
	local _, _, _, after_closed = metrics.netstat()
	testaux.asserteq(enabled, false, "Test 44.10: Closed TLS state cannot enable receiving")
	testaux.asserteq(after_closed, before_closed,
		"Test 44.11: Closed TLS state sends no command with its old socket ID")
	listener:close()
end)

for _, spec in ipairs({
	{id = 45, name = "TLS renegotiation bypasses the receive limit before any application write"},
	{id = 46, prefix = true, name = "TLS renegotiation bypasses the receive limit after application writes"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local c = require "test.aux.c"
		local native = require "silly.tls.tls"
		local started = channel.new()
		local negotiated = channel.new()
		local finished = channel.new()
		local port = 10000 + spec.id
		local listener = c.listen("127.0.0.1", port, 8)
		local control_listener = c.listen("127.0.0.1", port + 100, 8)
		local bee = hive.spawn [[
			local c = require "test.aux.c"
			return function(listener, control_listener, cert, key, prefix)
				local control = c.accept(control_listener)
				local fd = c.accept(listener)
				c.close(listener)
				c.close(control_listener)
				local data, err = c.tlsreneg(fd, control, cert, key, 1, prefix)
				c.close(fd)
				c.close(control)
				return {data = data, err = err}
			end
		]]
		task.fork(function()
			finished:push(hive.invoke(bee, listener, control_listener,
				testaux.CERT_A, testaux.KEY_A, spec.prefix))
		end)
		local control = c.connect("127.0.0.1", port + 100)
		local conn<close> = assert(tls.connect("127.0.0.1:" .. port))
		if spec.prefix then
			assert(conn:write("p"))
			assert(conn:read(1, 1000) == "p")
		end
		local push = native.push
		local phase = 0
		native.push = function(ssl, ptr, size)
			local total, err = push(ssl, ptr, size)
			if ssl == conn.ssl and phase < 2 then
				local pending = native.dbg_ininit(ssl)
				if phase == 0 and pending then
					phase = 1
					started:push(true)
				elseif phase == 1 and not pending then
					phase = 2
					negotiated:push(true)
				end
			end
			return total, err
		end
		local protected, result = pcall(function()
			c.send(control, "r")
			testaux.await(started, "TLS renegotiation starts before applying the receive limit")
			conn:limit(0)
			c.send(control, "w")
			testaux.await(negotiated, "TLS renegotiation finishes without an application read or write", 1000)
			local metrics = require "silly.metrics.c"
			local _, _, _, before = metrics.netstat()
			local enabled = native.readenable(conn.ssl, false)
			local _, _, _, after = metrics.netstat()
			assert(conn:write("q"))
			local data, err = conn:read(2, 1000)
			local completed = testaux.recv(control, 1)
			conn:close()
			local peer = testaux.await(finished, "TLS renegotiation peer finishes")
			return {enabled = enabled, commands = after - before,
				data = data, err = err, completed = completed, peer = peer}
		end)
		native.push = push
		c.close(control)
		assert(protected, result)
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(result.enabled, false, label .. "1: Receiving can pause after renegotiation completes")
		testaux.asserteq(result.commands, 0,
			label .. "1.1: Input processing already restored the receive limit")
		testaux.asserteq(result.data, "ok", label .. "2: A later application read resumes receiving")
		testaux.asserteq(result.err, nil, label .. "3: Application data succeeds after renegotiation")
		testaux.asserteq(result.completed, "d", label .. "4: Peer receives the application write")
		testaux.asserteq(result.peer.data, "q", label .. "5: Peer receives the exact application data")
		testaux.asserteq(result.peer.err, nil, label .. "6: Peer completes without a TLS error")
	end)
end

-- Cleanup EOF server
eof_server:close()
