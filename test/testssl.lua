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
		local native_err = native.readwait(conn.ssl)
		testaux.asserteq(native_err, errno.TLS, label .. "2.1: Native reads report the saved TLS error")
		testaux.asserteq(conn.err, errno.TLS, label .. "2.2: TLS failure preserves its error in Lua")
		testaux.asserteq(native.dbg_error(conn.ssl), errno.TLS,
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
			local err = native.push(state, ptr, size)
			if not ready then
				if err and err ~= errno.EOF then
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
				received:push({data = data, err = not data and err or nil})
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
	{id = 21, err = errno.CLOSED, name = "CLOSED writes leave reader termination to owner close"},
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
		local net = require "silly.net"
		local transport_closed = channel.new()
		local connect = net.tcpconnect
		net.tcpconnect = function(addr, event, ...)
			return connect(addr, {
				data = event.data,
				close = function(fd, err)
					event.close(fd, err)
					transport_closed:push(true)
				end,
			}, ...)
		end
		local connected, peer_result = pcall(tls.connect, address)
		net.tcpconnect = connect
		assert(connected, peer_result)
		local peer<close> = assert(peer_result)
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
		local saved = conn.err
		local stale_fd = conn.fd
		local closed, close_err
		if spec.err == errno.CLOSED then
			closed, close_err = conn:close()
		end
		local label = "Test " .. spec.id .. "."
		testaux.asserteq(ok, false, label .. "1: Write reports failure")
		testaux.asserteq(err, spec.err, label .. "2: Write preserves its error")
		testaux.asserteq(native.dbg_error(conn.ssl), spec.err, label .. "2.1: Native TLS retains the write error")
		local expected = spec.err == errno.TLS and errno.TLS or nil
		testaux.asserteq(saved, expected, label .. "2.2: Only a TLS write error terminates the waiting read")
		if spec.err == errno.TLS then
			testaux.assertneq(conn.fd, nil, label .. "8: Fatal write retains the socket ID until owner close")
		else
			testaux.asserteq(conn.fd, nil, label .. "8: Explicit owner close detaches the socket ID")
		end
		local result = testaux.await(finished, "fatal write releases pending read")
		testaux.asserteq(result.data, nil, label .. "3: Reader receives no data")
		testaux.asserteq(result.err, spec.err, label .. "4: Reader receives the write failure without timing out")
		testaux.asserteq(not not conn:isalive(), false, label .. "5: Fatal write disables connection reuse")
		if spec.err == errno.TLS then
			closed, close_err = conn:close()
		end
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
		-- A TLS alert or close_notify can precede actual socket release.
		testaux.await(transport_closed, "owner close reaches the peer transport")
		local ctx = require "silly.tls.ctx"
		local state = native.open(ctx.client(), stale_fd)
		local ok, err = native.write(state, "closed transport")
		testaux.asserteq(ok, true, label .. "13: Native writes leave transport closure to the socket owner")
		testaux.asserteq(err, nil, label .. "14: Failed handshake output does not become a TLS write error")
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
	testaux.asserteq(pushes, 0, "Test 23.3: Lua frees queued input after the read side ends")
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
			local err = push(ssl, ptr, size)
			if ssl == conn.ssl and not observed then
				local ret = native.handshake(ssl)
				if ret < 0 then
					observed = true
					started:push(true)
				end
			end
			return err
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
			local data = native.read(state, "\n")
			testaux.asserteq(data, nil, label .. "19: A closed native TLS state has no buffered data")
			testaux.asserteq(native.readwait(state), errno.CLOSED, label .. "20: Native readwait reports owner close")
			testaux.asserteq(native.sendsize(state), 0, label .. "21: Closed TLS has no send queue")
			local err = native.push(state, c.new("input after owner close"))
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
	testaux.asserteq(native.dbg_error(conn.ssl), nil, "Test 30.3: Socket events do not replace native TLS state")
	local data, err = conn:read(4)
	testaux.asserteq(data, "ello", "Test 30.5: Buffered plaintext precedes the socket error")
	testaux.asserteq(err, nil, "Test 30.6: Buffered reads succeed after socket close")
	local _, read_err = conn:read(1)
	local written, write_err = conn:write("after read closure")
	testaux.asserteq(read_err, errno.CONNRESET, "Test 30.7: Unfulfilled reads return the socket error")
	testaux.asserteq(written, true, "Test 30.8: A read-side notification does not invent a write failure")
	testaux.asserteq(write_err, nil, "Test 30.8.1: Writes report their own native result")
	testaux.asserteq(peer:read(18, 1000), "after read closure", "Test 30.8.2: The peer receives the write")
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
	local tls_err = native.dbg_error(state)
	local close_err = native.close(state)
	testaux.asserteq(ok, true, "Test 35.1: SSL accepts the write independently of transport submission")
	testaux.asserteq(err, nil, "Test 35.2: Native writes do not return socket errors")
	testaux.asserteq(tls_err, nil, "Test 35.3: A failed send does not invent an OpenSSL error")
	testaux.asserteq(close_err, nil, "Test 35.4: Native close does not replay a transport error")
	testaux.asserteq(native.dbg_error(state), errno.CLOSED, "Test 35.5: Owner close releases the TLS object")
end)

for _, spec in ipairs({
	{id = 37, client = true, name = "Transport close interrupts a pending client handshake"},
	{id = 38, client = false, name = "Transport close interrupts a pending server handshake"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local tcp = require "silly.net.tcp"
		local native = require "silly.tls.tls"
		local open, close = native.open, native.close
		local initialized = channel.new()
		local finalized = channel.new()
		local drained = channel.new()
		local target, listener
		local accepted, closed = false, false
		native.open = function(ctx, fd, hostname, alpn)
			local state, err = open(ctx, fd, hostname, alpn)
			if state then
				target = state
				initialized:push(true)
			end
			return state, err
		end
		native.close = function(state)
			local err = close(state)
			if state == target and not closed then
				closed = true
				finalized:push(true)
			end
			return err
		end
		local protected, result = pcall(function()
			local address = "127.0.0.1:" .. (10000 + spec.id)
			if spec.client then
				listener = assert(tcp.listen {
					addr = address,
					accept = function(peer)
						local header, err = peer:read(5, 1000)
						local body
						if header then
							local length = (header:byte(4) << 8) | header:byte(5)
							body, err = peer:read(length, 1000)
						end
						peer:close()
						drained:push({header = header, body = body, err = err})
					end,
				})
				local conn, err = tls.connect(address, {hostname = "localhost", timeout = 1000})
				if conn then
					conn:close()
				end
				local input = testaux.await(drained, "raw peer consumes ClientHello before FIN")
				assert(input.header and input.header:byte(1) == 22 and input.body and #input.body > 0,
					"raw peer did not receive ClientHello")
				assert(input.err == nil, input.err)
				testaux.await(finalized, "failed client handshake releases TLS state")
				return {conn = conn, err = err}
			end
			listener = assert(tls.listen {
				addr = address,
				certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
				accept = function(conn)
					accepted = true
					conn:close()
				end,
			})
			local peer<close> = assert(tcp.connect(address))
			testaux.await(initialized, "server registers its pending handshake")
			peer:close()
			testaux.await(finalized, "transport close releases pending server TLS state")
			return {}
		end)
		native.open, native.close = open, close
		if listener then
			listener:close()
		end
		assert(protected, result)
		local label = "Test " .. spec.id .. "."
		testaux.assertneq(target, nil, label .. "1: Native TLS state was created")
		if spec.client then
			testaux.asserteq(result.conn, nil, label .. "2: A closed transport cannot finish client setup")
			testaux.asserteq(result.err, errno.EOF, label .. "3: Client setup receives the transport EOF")
		else
			testaux.asserteq(accepted, false, label .. "2: A pending server handshake never reaches accept")
		end
	end)
end

testaux.case("Test 39: TLS buffer sizes remain intact above INT_MAX", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local state = native.open(ctx.client(), -1)
	-- Change only metadata, and restore it before any buffer access.
	local oldsize = native.dbg_readsize(state, 0x80000000)
	local size = native.size(state)
	native.dbg_readsize(state, oldsize)
	native.close(state)
	testaux.asserteq(size, 0x80000000, "Test 39.1: Buffered size is not narrowed to int")
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
						paused = not native.limit(target.ssl, 0)
					end
					event.data(fd, ptr, size)
					if paused ~= nil then
						processed:push({paused = paused, co = target.co, err = native.dbg_error(target.ssl)})
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
			assert(native.close(peer.ssl) == nil)
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
	local paused = native.limit(conn.ssl, 0)
	local _, _, _, after_pause = metrics.netstat()
	local paused_again = native.limit(conn.ssl, 0)
	local _, _, _, after_repeat = metrics.netstat()
	local resumed = native.limit(conn.ssl, nil)
	local _, _, _, after_resume = metrics.netstat()
	local resumed_again = native.limit(conn.ssl, nil)
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
	local enabled = native.limit(conn.ssl, nil)
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
			local err = push(ssl, ptr, size)
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
			return err
		end
		local protected, result = pcall(function()
			c.send(control, "r")
			testaux.await(started, "TLS renegotiation starts before applying the receive limit")
			conn:limit(0)
			c.send(control, "w")
			testaux.await(negotiated, "TLS renegotiation finishes without an application read or write", 1000)
			local metrics = require "silly.metrics.c"
			local _, _, _, before = metrics.netstat()
			local enabled = native.limit(conn.ssl, 0)
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

testaux.case("Test 47: Zero-length TLS reads match TCP", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local state = native.open(ctx.client(), -1)
	local data, err = native.read(state, 0)
	native.close(state)
	testaux.asserteq(data, "", "Test 47.1.1: An empty native TLS buffer satisfies a zero-length read")
	testaux.asserteq(err, nil, "Test 47.1.2: A zero-length native read has no error")

	local metrics = require "silly.metrics.c"
	for index, transport in ipairs({require "silly.net.tcp", tls}) do
		local label = "Test 47." .. (index + 1) .. "."
		local accepted = channel.new()
		local opts = {
			addr = "127.0.0.1:0",
			accept = function(conn)
				accepted:push(conn)
			end,
		}
		if transport == tls then
			opts.certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}}
		end
		local listener = assert(transport.listen(opts))
		local address = metrics.socketstat(listener.fd).localaddr
		local conn<close> = assert(transport.connect(address))
		local peer<close> = testaux.await(accepted, "zero-length read fixture accepts its peer")
		data, err = conn:read(0, 1000)
		testaux.asserteq(data, "", label .. "1: An idle connection returns an empty string")
		testaux.asserteq(err, nil, label .. "2: An idle zero-length read does not time out")

		assert(peer:write("abc"))
		assert(conn:read(1, 1000) == "a")
		local buffered = conn:unreadbytes()
		data, err = conn:read(0, 1000)
		testaux.asserteq(data, "", label .. "3: A zero-length read leaves the payload untouched")
		testaux.asserteq(err, nil, label .. "4: Buffered data does not change zero-length success")
		testaux.asserteq(conn:unreadbytes(), buffered, label .. "5: Buffered byte count is unchanged")
		testaux.asserteq(conn:read(2, 1000), "bc", label .. "6: The remaining payload is intact")

		peer:close()
		data, err = conn:read(1, 1000)
		assert_eof(data, err, label .. "7: Peer closure returns no data", label .. "8: Peer closure reports EOF")
		data, err = conn:read(0, 1000)
		testaux.asserteq(data, "", label .. "9: A zero-length read succeeds after peer EOF")
		testaux.asserteq(err, nil, label .. "10: Peer EOF does not replace zero-length success")

		conn:close()
		data, err = conn:read(0)
		testaux.asserteq(data, nil, label .. "11: Owner close still rejects reads")
		testaux.assertneq(err, nil, label .. "12: Owner close preserves its error")
		listener:close()
	end
end)

testaux.case("Test 48: Transport send errors preserve the TLS receive pause", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local address = metrics.socketstat(listener.fd).localaddr
	local peer<close> = assert(tls.connect(address))
	local conn<close> = testaux.await(accepted, "TLS receive pause fixture accepts its peer")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	local paused = native.limit(conn.ssl, 0)
	assert(net.close(conn.fd))
	local data, peer_err = peer:read(1, 1000)
	local ok, err = native.write(conn.ssl, "closed transport")
	local saved_err = native.dbg_error(conn.ssl)
	local enabled = native.dbg_readenabled(conn.ssl)
	conn:close()
	peer:close()
	listener:close()
	assert_eof(data, peer_err, "Test 48.1: The closed transport delivers no data",
		"Test 48.2: The peer observes transport EOF before the failed write")
	testaux.asserteq(paused, false, "Test 48.3: An established TLS connection can pause receiving")
	testaux.asserteq(ok, true, "Test 48.4: SSL accepts the data despite the closed transport")
	testaux.asserteq(err, nil, "Test 48.5: Transport submission does not affect the SSL result")
	testaux.asserteq(saved_err, nil, "Test 48.6: The transport failure does not become a TLS error")
	testaux.asserteq(enabled, false, "Test 48.7: The transport failure does not resume TLS receiving")
end)


testaux.case("Test 49: Saved transport errors survive queued TLS input", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local ondata, onclose
	local listen = net.tcplisten
	net.tcplisten = function(addr, event, backlog)
		ondata, onclose = event.data, event.close
		return listen(addr, event, backlog)
	end
	local protected, listener = pcall(tls.listen, {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	net.tcplisten = listen
	assert(protected, listener)
	assert(listener)
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "queued error fixture accepts its peer")
	assert(peer:write("hello"))
	assert(conn:read(1, 1000) == "h")
	onclose(conn.fd, errno.CONNRESET)
	-- Input queued before the close notification can still be delivered afterward.
	ondata(conn.fd, c.new("\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
	local saved = conn.err
	local sslerr = native.dbg_error(conn.ssl)
	local buffered = conn:read(4)
	local data, readerr = conn:read(1)
	local written, writeerr = conn:write("again")
	local response
	if written then
		response = peer:read(5, 1000)
	end
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(saved, errno.CONNRESET, "Test 49.1: The read-side error belongs to the transport")
	testaux.asserteq(sslerr, nil, "Test 49.3: Discarded input does not change native SSL state")
	testaux.asserteq(saved, errno.CONNRESET, "Test 49.4: Queued input preserves the first read error")
	testaux.asserteq(buffered, "ello", "Test 49.5: Saved errors still allow buffered plaintext to drain")
	testaux.asserteq(data, nil, "Test 49.6: No plaintext remains")
	testaux.asserteq(readerr, errno.CONNRESET, "Test 49.7: Reads preserve the first read error")
	testaux.asserteq(written, true, "Test 49.8: Discarded read input does not reject writes")
	testaux.asserteq(writeerr, nil, "Test 49.9: Writes return the independent native SSL result")
	testaux.asserteq(response, "again", "Test 49.10: The peer still receives the write")
end)

testaux.case("Test 50: Buffered TLS reads respect the registered reader", function()
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local registered = channel.new()
	local finished = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "reader ownership fixture accepts its peer")
	assert(peer:write("hello"))
	assert(conn:read(1, 1000) == "h")
	task.fork(function()
		registered:push(true)
		local data, err = conn:read(5, 1000)
		finished:push({data = data, err = err})
	end)
	testaux.await(registered, "the first reader registers without yielding before read")
	local empty_ok = pcall(conn.read, conn, 0)
	local ok = pcall(conn.read, conn, 4)
	local remaining = conn:unreadbytes()
	assert(peer:write("!"))
	local result = testaux.await(finished, "the registered reader finishes", 2000)
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(empty_ok, false, "Test 50.1: A second reader is rejected even for zero bytes")
	testaux.asserteq(ok, false, "Test 50.2: A second consuming reader is rejected")
	testaux.asserteq(remaining, 4, "Test 50.3: Rejected readers leave buffered bytes untouched")
	testaux.asserteq(result.data, "ello!", "Test 50.4: The registered reader receives all its bytes")
	testaux.asserteq(result.err, nil, "Test 50.5: The registered read succeeds")
end)

testaux.case("Test 51: Native TLS retains its callback context until close", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local function open()
		local context = assert(ctx.server({{cert = testaux.CERT_A, key = testaux.KEY_A}},
			nil, "\x02h2"))
		local weak = setmetatable({context}, {__mode = "v"})
		return native.open(context, -1), weak
	end
	local state, weak = open()
	collectgarbage("collect")
	collectgarbage("collect")
	local retained = weak[1] ~= nil
	native.close(state)
	collectgarbage("collect")
	collectgarbage("collect")
	local released = weak[1] == nil
	testaux.asserteq(retained, true, "Test 51.1: SNI and ALPN callback context remains alive")
	testaux.asserteq(released, true, "Test 51.2: Closing TLS releases its context reference")
end)

testaux.case("Test 52: Invalid TLS listener configuration allocates no socket", function()
	local net = require "silly.net"
	local listen = net.tcplisten
	local opened
	net.tcplisten = function(...)
		local fd, err = listen(...)
		opened = fd
		return fd, err
	end
	local ok, result = pcall(tls.listen, {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A}},
		accept = function(conn)
			conn:close()
		end,
	})
	net.tcplisten = listen
	if ok and result then
		result:close()
	elseif opened then
		net.close(opened)
	end
	collectgarbage("collect")
	testaux.asserteq(ok, false, "Test 52.1: Missing private keys raise a configuration error")
	testaux.asserteq(opened, nil, "Test 52.2: Invalid configuration cannot orphan a listener")
end)

testaux.case("Test 53: TLS connection setup failures release the transport", function()
	local net = require "silly.net"
	local tcp = require "silly.net.tcp"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local finished = channel.new()
	local listener = assert(tcp.listen {
		addr = "127.0.0.1:0",
		accept = function(conn)
			local data, err = conn:read(1, 1000)
			conn:close()
			finished:push({data = data, err = err})
		end,
	})
	local address = metrics.socketstat(listener.fd).localaddr
	local connect = net.tcpconnect
	local opened
	net.tcpconnect = function(...)
		local fd, err = connect(...)
		opened = fd
		return fd, err
	end
	local valid_alpn = pcall(tls.connect, address, {alpnprotos = {string.rep("x", 256)}})
	local invalid_fd = opened
	if opened then
		net.close(opened)
		testaux.await(finished, "invalid ALPN fixture releases its peer")
	end
	opened = nil
	local open = native.open
	native.open = function()
		return nil, errno.TLS
	end
	local valid_open, failed, openerr = pcall(tls.connect, address)
	native.open = open
	net.tcpconnect = connect
	if opened and not valid_open then
		net.close(opened)
	end
	local result = testaux.await(finished, "native setup failure closes its peer", 2000)
	listener:close()
	testaux.asserteq(valid_alpn, false, "Test 53.1: Invalid ALPN configuration raises an error")
	testaux.asserteq(invalid_fd, nil, "Test 53.2: ALPN validation happens before connecting")
	testaux.asserteq(valid_open, true, "Test 53.3: Expected native setup failures do not throw")
	testaux.asserteq(failed, nil, "Test 53.3.1: Failed setup returns no connection")
	testaux.asserteq(openerr, errno.TLS, "Test 53.3.2: Setup preserves the returned errno")
	testaux.asserteq(result.data, nil, "Test 53.4: Failed setup sends no application data")
	testaux.asserteq(result.err, errno.EOF, "Test 53.5: Failed native setup closes its transport")
end)

testaux.case("Test 54: Failed TLS reload preserves the active configuration", function()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			conn:close()
		end,
	})
	local context = listener.ctx
	local invalid = pcall(listener.reload, listener, {ciphers = "not-a-cipher"})
	local unchanged = listener.ctx == context and listener.conf.ciphers == nil
	local valid, result = pcall(listener.reload, listener)
	listener:close()
	testaux.asserteq(invalid, false, "Test 54.1: Invalid reload configuration raises an error")
	testaux.asserteq(unchanged, true, "Test 54.2: Failed reload changes neither context nor configuration")
	testaux.asserteq(valid, true, "Test 54.3: A later reload can reuse the saved valid configuration")
	testaux.asserteq(result, true, "Test 54.4: Reloading the preserved configuration succeeds")
end)

testaux.case("Test 55: Native TLS certificate counts are checked before narrowing", function()
	local ctx = require "silly.tls.ctx"
	local empty = pcall(ctx.server, {}, nil, nil)

	local certs = setmetatable({{cert = testaux.CERT_A, key = testaux.KEY_A}}, {
		__len = function()
			return 0x100000001
		end,
	})
	local huge = pcall(ctx.server, certs, nil, nil)
	local valid = pcall(function()
		assert(ctx.server({{cert = testaux.CERT_A, key = testaux.KEY_A}}))
	end)
	collectgarbage("collect")

	testaux.asserteq(empty, false, "Test 55.1: Server contexts require at least one certificate")
	testaux.asserteq(huge, false, "Test 55.2: Certificate counts cannot wrap into a valid native count")
	testaux.asserteq(valid, true, "Test 55.3: Optional cipher and ALPN arguments can be omitted")
end)


testaux.case("Test 56: TLS output flushes at the threshold while small fragments stay batched", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "threshold fixture accepts TLS")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	local small, fragments = {}, {}
	for i = 1, 8 do
		small[i] = string.rep(string.char(64 + i), 512)
	end
	for i = 1, 96 do
		fragments[i] = string.rep(string.char(64 + i % 26), 32 * 1024)
	end
	for i, spec in ipairs({
		{data = small, expected = table.concat(small), small = true},
		{data = fragments, expected = table.concat(fragments)},
		{data = string.rep("large string", 286000)},
	}) do
		local expected = spec.expected or spec.data
		local _, _, _, before = metrics.netstat()
		local ok, err = native.write(conn.ssl, spec.data)
		local _, _, _, after = metrics.netstat()
		local commands = after - before
		local data, readerr = peer:read(#expected, 1000)
		local label = "Test 56." .. i .. "."
		testaux.asserteq(ok, true, label .. "1: TLS accepts the complete write")
		testaux.asserteq(err, nil, label .. "2: Threshold flushing succeeds")
		testaux.asserteq(data == expected, true, label .. "3: The peer receives every byte in order")
		testaux.asserteq(readerr, nil, label .. "4: The peer reads without an error")
		if spec.small then
			testaux.asserteq(commands, 1, label .. "5: Small fragments share one transport submission")
		else
			testaux.asserteq(commands > 1 and commands <= 4, true,
				label .. "5: Large output uses bounded batches rather than one send per fragment")
		end
	end
	listener:close()
end)

testaux.case("Test 57: Queued TLS writes retain retry lengths across threshold flushes", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local metrics = require "silly.metrics.c"
	local payload = string.rep("queued", 524288)
	local suffix = {"tail one", string.rep("t", 70000), "tail two"}
	local expected = payload .. table.concat(suffix)
	local handshaken = channel.new()
	local received = channel.new()
	local finished = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			local data, err = conn:read(#expected, 1000)
			local ok, writeerr = conn:write("ack")
			conn:close()
			finished:push({data = data, err = err, ok = ok, writeerr = writeerr})
		end,
	})
	local state, ready, replied
	local max_commands = 0
	local fd = assert(net.tcpconnect(metrics.socketstat(listener.fd).localaddr, {
		data = function(_, ptr, size)
			local _, _, _, before = metrics.netstat()
			local err = native.push(state, ptr, size)
			local _, _, _, after = metrics.netstat()
			max_commands = math.max(max_commands, after - before)
			if not ready then
				local ret, detail
				if not err or err == errno.EOF then
					ret, detail = native.handshake(state)
				end
				if (err and err ~= errno.EOF) or ret >= 0 then
					ready = true
					handshaken:push({ret = ret, err = err, detail = detail})
				end
			end
			if not replied then
				local data = native.read(state, 3)
				if data or err then
					replied = true
					received:push({data = data, err = not data and err or nil})
				end
			end
		end,
		close = function(_, err)
			if not ready then
				ready = true
				handshaken:push({err = err})
			end
			if not replied then
				replied = true
				received:push({err = err})
			end
		end,
	}))
	state = native.open(ctx.client(), fd)
	assert(native.write(state, payload))
	assert(native.write(state, suffix))
	local handshake = testaux.await(handshaken, "queued threshold handshake completes")
	local response = testaux.await(received, "queued threshold peer acknowledges the payload")
	local result = testaux.await(finished, "queued threshold peer finishes")
	native.close(state)
	net.close(fd)
	listener:close()
	testaux.asserteq(handshake.ret, 1, "Test 57.1: A write retry finishes the real handshake")
	testaux.asserteq(handshake.err, nil, "Test 57.2: Retrying does not invent an I/O error")
	testaux.asserteq(response.data, "ack", "Test 57.3: The native client receives the acknowledgement")
	testaux.asserteq(response.err, nil, "Test 57.4: The acknowledgement succeeds")
	testaux.asserteq(result.data == expected, true, "Test 57.5: Retried and appended bytes arrive exactly once")
	testaux.asserteq(result.err, nil, "Test 57.6: Appending does not change the unfinished write length")
	testaux.asserteq(result.ok, true, "Test 57.7: The peer sends its acknowledgement")
	testaux.asserteq(result.writeerr, nil, "Test 57.8: The acknowledgement has no write error")
	testaux.asserteq(max_commands > 1 and max_commands <= 5, true,
		"Test 57.9: Retrying drains large queued writes through threshold batches")
end)

testaux.case("Test 58: Threshold send failures do not affect SSL writes", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "threshold failure fixture accepts TLS")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	assert(native.limit(conn.ssl, 0) == false)
	assert(net.close(conn.fd))
	local data, peererr = peer:read(1, 1000)
	local accessed = 0
	local fragment = string.rep("x", 32 * 1024)
	local parts = setmetatable({}, {
		__len = function()
			return 128
		end,
		__index = function()
			accessed = accessed + 1
			return fragment
		end,
	})
	local ok, err = native.write(conn.ssl, parts)
	local sslerr = native.dbg_error(conn.ssl)
	local enabled = native.dbg_readenabled(conn.ssl)
	conn:close()
	peer:close()
	listener:close()
	assert_eof(data, peererr, "Test 58.1: The closed transport sends no data",
		"Test 58.2: The peer observes closure before the failed write")
	testaux.asserteq(ok, true, "Test 58.3: SSL accepts every fragment despite transport failure")
	testaux.asserteq(err, nil, "Test 58.4: Threshold flushing does not return socket errors")
	testaux.asserteq(sslerr, nil, "Test 58.5: The transport failure does not become a saved SSL error")
	testaux.asserteq(enabled, false, "Test 58.6: The transport failure does not lift the receive pause")
	testaux.asserteq(accessed, 128,
		"Test 58.7: Transport errors do not interrupt SSL processing of later fragments")
end)



testaux.case("Test 59: Zombie sends preserve the fatal transport reason before the TLS close callback", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local closed = channel.new()
	local target, pending
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local connect = net.tcpconnect
	net.tcpconnect = function(addr, event, ...)
		return connect(addr, {
			data = event.data,
			close = function(fd, err)
				if target and fd == target.fd then
					pending = {callback = event.close, fd = fd, err = err}
					closed:push({err = err})
				else
					event.close(fd, err)
				end
			end,
		}, ...)
	end
	local protected, conn = pcall(tls.connect, metrics.socketstat(listener.fd).localaddr)
	net.tcpconnect = connect
	assert(protected, conn)
	assert(conn)
	local peer<close> = testaux.await(accepted, "reset fixture accepts TLS")
	target = conn
	assert(peer:write("ready"))
	assert(conn:read(5, 1000) == "ready")
	local reading = channel.new()
	local finished = channel.new()
	task.fork(function()
		reading:push(true)
		local data, err = conn:read(1, 1000)
		finished:push({data = data, err = err})
	end)
	testaux.await(reading, "a TLS reader waits before the reset")
	c.setlinger(metrics.socketstat(peer.fd).os_fd, 0)
	assert(net.close(peer.fd))
	local observed = testaux.await(closed, "the fatal close event arrives before TLS sees it")
	-- LISTEN executes on the socket thread after publishing the reset socket's zombie state.
	local barrier = assert(net.tcplisten("127.0.0.1:0", {
		data = function(_, ptr)
			net.free(ptr)
		end,
		close = function()
		end,
	}))
	local fd = conn.fd
	local raw_ok, raw_err = net.tcpsend(fd, "raw send after reset")
	local shared, size = net.multipack("multicast after reset", 1)
	local multi_ok, multi_err = net.tcpmulticast(fd, shared, size)
	local ok, err = conn:write("TLS write after reset")
	local saved = conn.err
	local sslerr = native.dbg_error(conn.ssl)
	pending.callback(pending.fd, pending.err)
	local result = testaux.await(finished, "close notification wakes the reader after the failed send")
	local after_close = conn.err
	conn:close()
	peer:close()
	local stale_ok, stale_err = net.tcpsend(fd, "send after owner close")
	net.close(barrier)
	listener:close()
	testaux.asserteq(observed.err == errno.CONNRESET or observed.err == errno.CONNABORTED, true,
		"Test 59.1: Reset produces a specific fatal transport cause")
	testaux.asserteq(raw_ok, false, "Test 59.2: Raw send rejects a zombie socket")
	testaux.asserteq(raw_err, observed.err, "Test 59.3: Raw send returns the fatal transport cause")
	testaux.asserteq(multi_ok, false, "Test 59.4: Multicast rejects a zombie socket")
	testaux.asserteq(multi_err, observed.err, "Test 59.5: Multicast preserves the fatal transport cause")
	testaux.asserteq(ok, true, "Test 59.6: SSL accepts the write before the delayed close notification")
	testaux.asserteq(err, nil, "Test 59.7: TLS write leaves the transport cause to the close event")
	testaux.asserteq(sslerr, nil, "Test 59.8: A reset is not saved as an SSL protocol failure")
	testaux.asserteq(saved, nil, "Test 59.9: A write error does not become the saved read error")
	testaux.asserteq(after_close, observed.err, "Test 59.10: Delayed fatal close saves the actual transport cause")
	testaux.asserteq(stale_ok, false, "Test 59.11: Owner close rejects the obsolete socket ID")
	testaux.asserteq(stale_err, errno.CLOSED, "Test 59.12: Released sockets have no retained zombie cause")
	testaux.asserteq(result.data, nil, "Test 59.13: The waiting reader receives no data")
	testaux.asserteq(result.err, observed.err, "Test 59.14: Close notification wakes the reader with the transport cause")
end)

testaux.case("Test 60: Read EOF does not replace a later zombie write error", function()
	local net = require "silly.net"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local ended = channel.new()
	local barrier_accepted = channel.new()
	local close_count = 0
	local event = {
		accept = function(fd)
			accepted:push(fd)
		end,
		data = function(_, ptr)
			net.free(ptr)
		end,
		close = function(_, err)
			close_count = close_count + 1
			ended:push({err = err})
		end,
	}
	local listener = assert(net.tcplisten("127.0.0.1:0", event))
	local address = metrics.socketstat(listener).localaddr
	local host, port = address:match("^([^:]+):(%d+)$")
	local peer = c.connect(host, tonumber(port))
	local fd = testaux.await(accepted, "half-close fixture accepts TCP")
	c.shutdown(peer, 1)
	local read_end = testaux.await(ended, "peer FIN ends only the read direction")
	local wrote, writeerr = net.tcpsend(fd, "world")
	local response = c.recv(peer, 5)
	local barrier_event = {
		accept = function(id)
			barrier_accepted:push(id)
		end,
		data = event.data,
		close = function()
		end,
	}
	local barrier_listener = assert(net.tcplisten("127.0.0.1:0", barrier_event))
	-- The socket remains owned by the engine; only its write half is shut down here.
	c.shutdown(metrics.socketstat(fd).os_fd, 1)
	local queued = net.tcpsend(fd, "write after local shutdown")
	local barrier_client = assert(net.tcpconnect(metrics.socketstat(barrier_listener).localaddr,
		barrier_event))
	-- Accept runs after the operation batch has attempted the failed write.
	local barrier_peer = testaux.await(barrier_accepted, "the socket thread completes the failed write")
	local ok, err = net.tcpsend(fd, "send after becoming zombie")
	local again, againerr = net.tcpsend(fd, "repeat zombie send")
	local shared, size = net.multipack("zombie multicast", 1)
	local multi, multierr = net.tcpmulticast(fd, shared, size)
	net.close(fd)
	c.close(peer)
	net.close(barrier_client)
	net.close(barrier_peer)
	net.close(barrier_listener)
	net.close(listener)
	testaux.asserteq(read_end.err, errno.EOF, "Test 60.1: The read direction reports EOF")
	testaux.asserteq(wrote, true, "Test 60.2: Read EOF still permits writing")
	testaux.asserteq(writeerr, nil, "Test 60.3: Half-close does not invent a write error")
	testaux.asserteq(response, "world", "Test 60.4: The peer receives data after its FIN")
	testaux.asserteq(queued, true, "Test 60.5: The operation is queued before the write failure")
	testaux.asserteq(ok, false, "Test 60.6: The failed write makes the socket a zombie")
	testaux.assertneq(err, nil, "Test 60.7: Zombie sends return a write failure")
	testaux.assertneq(err, errno.EOF, "Test 60.8: Zombie cause does not reuse the earlier read EOF")
	testaux.assertneq(err, errno.CLOSED, "Test 60.9: Zombie cause retains the actual write failure")
	testaux.asserteq(again, false, "Test 60.10: Repeated zombie sends fail")
	testaux.asserteq(againerr, err, "Test 60.11: Repeated sends preserve the zombie cause")
	testaux.asserteq(multi, false, "Test 60.12: Zombie multicast fails")
	testaux.asserteq(multierr, err, "Test 60.13: Multicast preserves the write failure")
	testaux.asserteq(close_count, 1, "Test 60.14: The earlier read EOF remains the only close notification")
end)


testaux.case("Test 61: Invalid socket IDs cannot refer to unused pool slots", function()
	local net = require "silly.net"
	local ok, err = net.tcpsend(-1, "invalid TCP socket ID")
	local udp_ok, udp_err = net.udpsend(-1, "invalid UDP socket ID")
	local shared, size = net.multipack("invalid multicast socket ID", 1)
	local multi_ok, multi_err = net.tcpmulticast(-1, shared, size)
	testaux.asserteq(ok, false, "Test 61.1: Invalid TCP IDs reject sends")
	testaux.asserteq(err, errno.CLOSED, "Test 61.2: Invalid TCP IDs report CLOSED")
	testaux.asserteq(udp_ok, false, "Test 61.3: Invalid UDP IDs reject sends")
	testaux.asserteq(udp_err, errno.CLOSED, "Test 61.4: Invalid UDP IDs report CLOSED")
	testaux.asserteq(multi_ok, false, "Test 61.5: Invalid multicast IDs reject sends")
	testaux.asserteq(multi_err, errno.CLOSED, "Test 61.6: Invalid multicast IDs report CLOSED")
end)

-- Cleanup EOF server
eof_server:close()

testaux.case("Test 62: Native TLS read waits own the receive-limit exemption", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "native read-limit fixture accepts TLS")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	testaux.asserteq(native.limit(conn.ssl, 0), false, "Test 62.1: A zero limit pauses receiving")
	testaux.asserteq(native.readwait(conn.ssl), nil, "Test 62.2: A healthy SSL state may wait")
	testaux.asserteq(native.dbg_readenabled(conn.ssl), true, "Test 62.3: Waiting bypasses the limit")
	local data, err = native.read(conn.ssl, 1)
	testaux.asserteq(data, nil, "Test 62.4: An incomplete read has no data")
	testaux.asserteq(err, nil, "Test 62.5: An incomplete read remains healthy")
	testaux.asserteq(native.limit(conn.ssl, 0), true, "Test 62.6: Limit changes preserve an active wait")
	native.readcancel(conn.ssl)
	testaux.asserteq(native.dbg_readenabled(conn.ssl), false, "Test 62.7: Cancellation restores the limit")
	assert(native.readwait(conn.ssl) == nil)
	testaux.asserteq(native.read(conn.ssl, 0), "", "Test 62.8: A zero-byte read succeeds")
	testaux.asserteq(native.dbg_readenabled(conn.ssl), false, "Test 62.9: Every successful read ends the exemption")
	assert(peer:write("abc"))
	testaux.asserteq(conn:read(1, 1000), "a", "Test 62.10: A public read resumes receiving")
	testaux.asserteq(native.dbg_readenabled(conn.ssl), false, "Test 62.11: A completed read restores the limit")
	testaux.asserteq(conn:read(2), "bc", "Test 62.12: Buffered reads preserve the remaining plaintext")
	for _, value in ipairs({-1, 2147483648, 1.5}) do
		testaux.asserteq(pcall(native.limit, conn.ssl, value), false,
			"Test 62.13: Invalid limits are rejected before narrowing")
	end
	testaux.asserteq(native.dbg_readenabled(conn.ssl), false, "Test 62.14: Invalid limits leave receiving unchanged")
	testaux.asserteq(native.limit(conn.ssl, nil), true, "Test 62.15: Removing the limit resumes receiving")
	conn:close()
	peer:close()
	listener:close()
end)

testaux.case("Test 63: Native TLS cannot wait after a cached terminal error", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local c = require "test.aux.c"
	local state = assert(native.open(ctx.server({{cert = testaux.CERT_A, key = testaux.KEY_A}}), -1))
	local inputerr = native.push(state, c.new("GET / HTTP/1.1\r\n\r\n"))
	local waiterr = native.readwait(state)
	local _, readerr = native.read(state, 1)
	native.close(state)
	testaux.asserteq(inputerr, errno.TLS, "Test 63.1: Invalid input records a native SSL error")
	testaux.asserteq(waiterr, errno.TLS, "Test 63.2: Waiting returns the cached SSL error")
	testaux.asserteq(readerr, nil, "Test 63.3: Buffer reads do not return native errors")
	state = assert(native.open(ctx.client(), -1))
	native.close(state)
	testaux.asserteq(native.readwait(state), errno.CLOSED, "Test 63.4: Released SSL state cannot register a wait")
end)

testaux.case("Test 64: Native TLS setup returns errors and releases partial resources", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local context = ctx.client()
	for _, spec in ipairs({
		{alpn = "\x02h", label = "truncated ALPN"},
		{hostname = string.rep("x", 256), label = "oversized SNI"},
	}) do
		local state, err = native.open(context, -1, spec.hostname, spec.alpn)
		if state then
			native.close(state)
		end
		testaux.asserteq(state, nil, "Test 64.1: Invalid " .. spec.label .. " does not create TLS state")
		testaux.asserteq(err, errno.TLS, "Test 64.2: OpenSSL setup failures return a TLS errno")
	end
end)

testaux.case("Test 65: TLS transport read EOF still permits a response", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "TLS half-close fixture accepts TLS")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	c.shutdown(metrics.socketstat(peer.fd).os_fd, 1)
	local data, readerr = conn:read(1, 1000)
	local sslerr = native.dbg_error(conn.ssl)
	local ok, writeerr = conn:write("world")
	local response
	if ok then
		response = peer:read(5, 1000)
	end
	local _, repeated = conn:read(1)
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(data, nil, "Test 65.1: FIN ends the read direction")
	testaux.asserteq(readerr, errno.EOF, "Test 65.2: Transport FIN reports EOF")
	testaux.asserteq(sslerr, nil, "Test 65.3: Transport EOF does not poison native SSL state")
	testaux.asserteq(ok, true, "Test 65.4: Read EOF does not reject writes")
	testaux.asserteq(writeerr, nil, "Test 65.5: The response has no write error")
	testaux.asserteq(response, "world", "Test 65.6: The half-closed peer receives the TLS response")
	testaux.asserteq(repeated, errno.EOF, "Test 65.7: Writing preserves the saved read EOF")
end)

testaux.case("Test 66: TLS setup returns native errors and closes the connected transport", function()
	local tcp = require "silly.net.tcp"
	local metrics = require "silly.metrics.c"
	local finished = channel.new()
	local listener = assert(tcp.listen {
		addr = "127.0.0.1:0",
		accept = function(conn)
			local data, err = conn:read(1, 1000)
			conn:close()
			finished:push({data = data, err = err})
		end,
	})
	local address = metrics.socketstat(listener.fd).localaddr
	-- An empty ALPN name encodes a zero-length entry, rejected by SSL_set_alpn_protos.
	local connected, conn, err = pcall(tls.connect, address, {alpnprotos = {""}, timeout = 1000})
	if conn and type(conn) == "table" then
		conn:close()
	end
	local result = testaux.await(finished, "failed native setup releases the connected TCP peer")
	listener:close()
	testaux.asserteq(connected, true, "Test 66.1: Expected setup failure does not throw")
	testaux.asserteq(conn, nil, "Test 66.2: Expected setup failure returns no connection")
	testaux.asserteq(err, errno.TLS, "Test 66.3: Expected setup failure preserves the native errno")
	testaux.asserteq(result.data, nil, "Test 66.4: Failed setup sends no handshake or application data")
	testaux.asserteq(result.err, errno.EOF, "Test 66.5: Failed setup closes the borrowed transport")
end)

testaux.case("Test 67: TLS client context failure is reported before accepting connections", function()
	local ctx = require "silly.tls.ctx"
	local client = ctx.client
	ctx.client = function()
		return nil, "forced client context failure"
	end
	local ok, err = pcall(dofile, "lualib/silly/net/tls.lua")
	ctx.client = client
	testaux.asserteq(ok, false, "Test 67.1: An unusable default context cannot create a TLS module")
	testaux.asserteq(type(err) == "string" and err:find("forced client context failure", 1, true) ~= nil,
		true, "Test 67.2: Module initialization preserves the context failure")
end)

testaux.case("Test 68: Native TLS reads only return buffered data", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local state = assert(native.open(ctx.client(), -1))
	native.close(state)
	local result = table.pack(native.read(state, 1))
	testaux.asserteq(result.n, 1, "Test 68.1: Buffer reads return exactly one result")
	testaux.asserteq(result[1], nil, "Test 68.2: An empty buffer returns nil even after close")
	testaux.asserteq(native.readwait(state), errno.CLOSED, "Test 68.3: Waiting observes the native terminal state")
end)

testaux.case("Test 69: Native TLS push reports EOF without discarding plaintext", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "TLS EOF buffer fixture accepts TLS")
	assert(peer:write("abc"))
	assert(conn:read(1, 1000) == "a")
	assert(native.close(peer.ssl) == nil)
	local data, err = conn:read(3, 1000)
	local pushed = native.push(conn.ssl, c.new("input after read EOF"))
	local buffered = native.read(conn.ssl, 2)
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(data, nil, "Test 69.1: The incomplete read ends at close_notify")
	testaux.asserteq(err, errno.EOF, "Test 69.2: The pending reader observes EOF")
	testaux.asserteq(pushed, errno.EOF, "Test 69.3: Push returns the cached SSL read termination")
	testaux.asserteq(buffered, "bc", "Test 69.4: Read termination leaves existing plaintext readable")
end)

testaux.case("Test 70: Native TLS push leaves transport errors to the socket owner", function()
	local native = require "silly.tls.tls"
	local ctx = require "silly.tls.ctx"
	local c = require "test.aux.c"
	local state = assert(native.open(ctx.client(), -1))
	-- SSL_read generates ClientHello, whose transport submission rejects this obsolete ID.
	local result = table.pack(native.push(state, c.new("")))
	local err = result[1]
	local size = native.size(state)
	local sslerr = native.dbg_error(state)
	native.close(state)
	testaux.asserteq(size, 0, "Test 70.1: No plaintext was received")
	testaux.asserteq(err, nil, "Test 70.2: A failed send is not a push read error")
	testaux.asserteq(sslerr, nil, "Test 70.3: Failed transport output does not poison native SSL state")
	testaux.asserteq(result.n, 1, "Test 70.4: Push returns only the SSL error")
end)

local function queued_tls_input(id, pending_write)
	local label = "Test " .. id .. "."
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local buffer = require "silly.adt.buffer"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local held = channel.new()
	local finished = channel.new()
	local queued = buffer.new()
	local target, header, pending, ondata
	local listen = net.tcplisten
	net.tcplisten = function(addr, event, backlog)
		ondata = event.data
		return listen(addr, {
			accept = event.accept,
			close = event.close,
			data = function(fd, ptr, size)
				if not target or fd ~= target.fd then
					event.data(fd, ptr, size)
					return
				end
				buffer.append(queued, ptr, size)
				header = header or buffer.read(queued, 5)
				if not header then
					return
				end
				local length = (header:byte(4) << 8) | header:byte(5)
				local body = buffer.read(queued, length)
				if body then
					local data, len = c.new(header .. body .. buffer.readall(queued))
					pending = {data = data, size = len}
					held:push(true)
				end
			end,
		}, backlog)
	end
	local protected, listener = pcall(tls.listen, {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
			local data, err = conn:read(5, 1000)
			finished:push({data = data, err = err})
		end,
	})
	net.tcplisten = listen
	assert(protected, listener)
	assert(listener)
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "reader waits before transport write failure")
	assert(conn:write("ready"))
	assert(peer:read(5, 1000) == "ready")
	target = conn
	assert(peer:write("hello"))
	testaux.await(held, "a complete TLS record is queued before closing the transport")
	assert(net.close(conn.fd))
	-- The peer observing FIN proves the socket thread has released the original ID.
	local _, peererr = peer:read(1, 1000)
	local ok, err = conn:write("write after transport release")
	local saved = conn.err
	local sslerr = native.dbg_error(conn.ssl)
	if pending_write then
		native.dbg_writebuf(conn.ssl, string.rep("w", 2 * 1024 * 1024))
	end
	ondata(conn.fd, pending.data, pending.size)
	pending = nil
	local result = testaux.await(finished, "queued ciphertext still completes the waiting read")
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(peererr, errno.EOF, label .. "1: Transport closure is observed before the failed write")
	testaux.asserteq(ok, true, label .. "2: SSL accepts the write through the released socket")
	testaux.asserteq(err, nil, label .. "3: The write leaves transport errors to the close event")
	testaux.asserteq(saved, nil, label .. "4: A transport write error does not terminate the reader")
	testaux.asserteq(sslerr, nil, label .. "5: Native SSL state remains usable for queued input")
	testaux.asserteq(result.data, "hello", label .. "6: Valid queued input satisfies the pending read")
	testaux.asserteq(result.err, nil, label .. "7: The pending read succeeds")
end

testaux.case("Test 71: A failed transport write does not discard queued valid TLS input", function()
	queued_tls_input(71, false)
end)

testaux.case("Test 72: A failed threshold drain still decodes queued valid TLS input", function()
	queued_tls_input(72, true)
end)

testaux.case("Test 73: Negative TLS fragment counts are rejected before writing a prefix", function()
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "negative fragment-count fixture accepts TLS")
	local fragments = setmetatable({}, {
		__len = function()
			return -1
		end,
		__index = function(_, index)
			if index == 1 then
				return "bad"
			end
		end,
	})
	local valid = pcall(conn.write, conn, fragments)
	assert(conn:write("ok"))
	local data = peer:read(2, 1000)
	conn:close()
	peer:close()
	listener:close()
	testaux.asserteq(valid, false, "Test 73.1: Negative fragment counts reject the argument")
	testaux.asserteq(data, "ok", "Test 73.2: Rejected lengths cannot leave an encrypted prefix to flush")
end)

testaux.case("Test 74: Fatal TLS writes preserve the first read error without a waiting reader", function()
	local net = require "silly.net"
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	for i, prior in ipairs({false, errno.EOF}) do
		local accepted = channel.new()
		local closed = channel.new()
		local target, onclose
		local listen = net.tcplisten
		net.tcplisten = function(addr, event, backlog)
			onclose = event.close
			return listen(addr, {
				accept = event.accept,
				data = event.data,
				close = function(fd, err)
					event.close(fd, err)
					if fd == target then
						closed:push({err = err})
					end
				end,
			}, backlog)
		end
		local protected, listener = pcall(tls.listen, {
			addr = "127.0.0.1:0",
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				accepted:push(conn)
			end,
		})
		net.tcplisten = listen
		assert(protected, listener)
		assert(listener)
		local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
		local conn<close> = testaux.await(accepted, "fatal-write fixture accepts TLS")
		target = conn.fd
		assert(peer:write("good"))
		assert(conn:read(1, 1000) == "g")
		local healthy = conn:isalive()
		if prior then
			onclose(conn.fd, prior)
		end
		-- Seed an actual SSL failure without going through the Lua input handler.
		local inputerr = native.push(conn.ssl,
			c.new("\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
		local ok, err = conn:write("probe")
		local saved = conn.err
		local alive = conn:isalive()
		c.setlinger(metrics.socketstat(peer.fd).os_fd, 0)
		assert(net.close(peer.fd))
		local transport = testaux.await(closed, "transport closure follows the failed TLS write")
		local buffered, buffererr = conn:read(3)
		local data, readerr = conn:read(1, 1000)
		conn:close()
		peer:close()
		listener:close()
		local label = "Test 74." .. i .. "."
		local expected = prior or errno.TLS
		testaux.asserteq(inputerr, errno.TLS, label .. "1: Invalid ciphertext poisons the SSL engine")
		testaux.asserteq(ok, false, label .. "2: The native write reports failure")
		testaux.asserteq(err, errno.TLS, label .. "3: Writing returns the SSL error")
		testaux.asserteq(buffered, "ood", label .. "4: Fatal writes leave buffered plaintext readable")
		testaux.asserteq(buffererr, nil, label .. "5: Buffered plaintext still succeeds")
		testaux.asserteq(data, nil, label .. "6: No more plaintext is available")
		testaux.asserteq(readerr, expected, label .. "7: A later transport error cannot replace the first read error")
		testaux.asserteq(saved, expected, label .. "8: A fatal write saves its error even without a reader")
		testaux.assertneq(transport.err, nil, label .. "9: The real socket close notification was delivered")
		testaux.asserteq(healthy, true, label .. "10: A healthy connection is alive")
		testaux.asserteq(alive, false, label .. "11: The saved read error marks the connection as ended")
	end
end)

testaux.case("Test 75: Idle TLS input stays buffered without attempting a read", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local accepted = channel.new()
	local pushed = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "idle-input fixture accepts TLS")
	local push, read = native.push, native.read
	local reads = 0
	native.push = function(state, ...)
		local err = push(state, ...)
		if state == conn.ssl then
			pushed:push(true)
		end
		return err
	end
	native.read = function(state, ...)
		if state == conn.ssl then
			reads = reads + 1
		end
		return read(state, ...)
	end
	local ok, err = pcall(function()
		assert(peer:write("idle"))
		testaux.await(pushed, "idle connection decodes the received TLS input")
	end)
	native.push = push
	native.read = read
	local data = conn:read(4, 1000)
	conn:close()
	peer:close()
	listener:close()
	assert(ok, err)
	testaux.asserteq(reads, 0, "Test 75.1: Input without a waiting reader does not call native read")
	testaux.asserteq(data, "idle", "Test 75.2: The next read consumes the buffered plaintext")
end)

testaux.case("Test 76: TLS write buffers keep capacity until close", function()
	local native = require "silly.tls.tls"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local listener = assert(tls.listen {
		addr = "127.0.0.1:0",
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local peer<close> = assert(tls.connect(metrics.socketstat(listener.fd).localaddr))
	local conn<close> = testaux.await(accepted, "write-capacity fixture accepts TLS")
	local capacities, data = {}, {}
	for i, size in ipairs({4096, 2048}) do
		local payload = string.rep(string.char(64 + i), size)
		native.dbg_writebuf(conn.ssl, payload)
		local before = native.dbg_writecap(conn.ssl)
		assert(native.push(conn.ssl, c.new("")) == nil)
		capacities[i] = {before = before, after = native.dbg_writecap(conn.ssl)}
		data[i] = peer:read(size, 1000)
	end
	local failure = native.push(conn.ssl,
		c.new("\x17\x03\x03\x00\x20" .. string.rep("\x00", 32)))
	local failed_capacity = native.dbg_writecap(conn.ssl)
	conn:close()
	local closed_capacity = native.dbg_writecap(conn.ssl)
	peer:close()
	listener:close()
	for i, size in ipairs({4096, 2048}) do
		testaux.asserteq(data[i], string.rep(string.char(64 + i), size),
			"Test 76." .. i .. ".1: Draining preserves all queued data")
		testaux.asserteq(capacities[i].after, capacities[i].before,
			"Test 76." .. i .. ".2: Draining retains the write buffer allocation")
	end
	testaux.asserteq(capacities[2].before, capacities[1].before,
		"Test 76.3: The next queued write reuses the retained capacity")
	testaux.asserteq(failure, errno.TLS, "Test 76.4: Invalid input records a fatal TLS error")
	testaux.asserteq(failed_capacity, capacities[2].before,
		"Test 76.5: A fatal error leaves allocation ownership with the connection")
	testaux.asserteq(closed_capacity, 0, "Test 76.6: Closing releases the write buffer allocation")
end)
