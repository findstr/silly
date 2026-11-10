local silly = require "silly"
local task = require "silly.task"
local logger = require "silly.logger"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local waitgroup = require "silly.sync.waitgroup"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"
local errno = require "silly.errno"
local pcall = silly.pcall
local ETIMEDOUT<const> = errno.TIMEDOUT

-- Global test configuration
local TEST_PORT = 10005
local TLS_PORT = 10006
local TEST_HOST = "127.0.0.1"
local STRESS_TEST_CLIENTS = 50

local function nop(sock) end
---@async
local server_handler = nop
---@async
local tls_server_handler = nop

local server, err = http.listen {
	addr = TEST_HOST .. ":" .. TEST_PORT,
	handler = function(stream)
		local sock, err = websocket.upgrade(stream)
		if not sock then
			logger.error("websocket upgrade failed: %s", err)
			return
		end
		server_handler(sock)
		server_handler = nop
	end,
}
testaux.asserteq(not not server, true, "start websocket server")

local tls_server, err = http.listen {
	tls = true,
	addr = TEST_HOST .. ":" .. TLS_PORT,
	certs = {
		{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}
	},
	handler = function(stream)
		local sock, err = websocket.upgrade(stream)
		if not sock then
			logger.error("websocket upgrade failed: %s", err)
			return
		end
		tls_server_handler(sock)
		tls_server_handler = nop
	end,
}
testaux.asserteq(not not tls_server, true, "start tls websocket server")

local function wait_done()
	while server_handler ~= nop do
		time.sleep(100)
	end
	while tls_server_handler ~= nop do
		time.sleep(100)
	end
end

testaux.case("Test 1: Basic connection establishment", function()
	---@param sock silly.net.websocket.socket
	server_handler = function(sock)
		sock:close()
	end
	local sock, err = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	print("connect:", sock, err)
	testaux.asserteq(not not sock, true, "Basic connection succeeds")
	testaux.asserteq(err, nil, "No connection error")
	assert(sock)
	print("-----------1")
	sock:close()
	print("-----------2")
	wait_done()
end)

-- Test 2: Frame validation - server read
local test_vectors = {
	-- Basic types
	{data = "", type = "text", desc = "Empty text frame"},
	{data = "Hello", type = "text", desc = "text frame"},
	{data = "", type = "binary", desc = "Empty binary frame"},
	{data = "World", type = "binary", desc = "Binary frame"},

	-- RFC 6455 length boundaries
	{data = string.rep("A", 125), type = "text", desc = "Small payload (125B)"},
	{data = string.rep("B", 126), type = "binary", desc = "16bit length header (126B)"},
	{data = string.rep("C", 65535), type = "binary", desc = "Max 16bit length (65535B)"},
	{data = string.rep("D", 65536), type = "binary", desc = "64bit length header (65536B)"},
	{data = string.rep("E", 1024*1024), type = "binary", desc = "1MB payload"},

	-- Special payloads
	{data = string.char(0x00, 0xFF, 0x7F), type = "binary", desc = "Binary boundaries"},
	{data = "utf8-test-中文", type = "text", desc = "UTF8 validation"}
}

for i, vec in ipairs(test_vectors) do
	testaux.case(string.format("Test 2.%d: Server read - %s", i, vec.desc), function()
		server_handler = function(sock)
			local received = {}
			while true do
				local data, typ = sock:read()
				testaux.assertneq(data, nil, "read frame succeeds")
				if not data or typ == "close" then
					break
				end
				testaux.asserteq(typ, vec.type, "frame type matches")
				if #data > 0 then
					received[#received + 1] = data
				end
			end
			local final_data = table.concat(received)
			testaux.asserteq(#final_data, #vec.data, "Length matches")
			testaux.asserteq(final_data, vec.data, "Content matches")
			sock:close()
		end

		local sock = websocket.connect("ws://"..TEST_HOST..":"..TEST_PORT)
		testaux.assertneq(sock, nil, "Client connected")
		assert(sock)
		local ok = sock:write(vec.data, vec.type)
		testaux.asserteq(ok, true, "Write succeeds")
		sock:close()
		wait_done()
	end)
end

-- Test 2: Frame validation - client read
for i, vec in ipairs(test_vectors) do
	testaux.case(string.format("Test 2.%d: Client read - %s", i + #test_vectors, vec.desc), function()
		server_handler = function(sock)
			sock:write(vec.data, vec.type)
			sock:close()
		end

		local sock = websocket.connect("ws://"..TEST_HOST..":"..TEST_PORT)
		testaux.assertneq(sock, nil, "Client connected")
		assert(sock)
		local data, typ = sock:read()
		testaux.asserteq(data, vec.data, "Read data matches")
		testaux.asserteq(typ, vec.type, "Read type matches")
		sock:close()
		wait_done()
	end)
end

testaux.case("Test 3: Control frames - ping/pong handling", function()
	server_handler = function(sock)
		-- Test Ping with data
		sock:write("bar", "ping")
		local data, typ = sock:read()
		testaux.asserteq(typ, "pong", "Received pong response")
		testaux.asserteq(data, "foo", "Pong data matches")
		sock:close()
	end

	local sock = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.assertneq(sock, nil, "Client connected")
	assert(sock)
	-- Handle server ping
	local data, typ = sock:read()
	testaux.asserteq(data, "bar", "Ping data received")
	testaux.asserteq(typ, "ping", "Ping frame type")
	local ok = sock:write("foo", "pong")
	testaux.asserteq(ok, true, "Pong write succeeds")

	-- Verify close handshake
	local dat, type = sock:read()
	testaux.asserteq(type, "close", "Close frame received")
	testaux.asserteq(dat, "", "Close frame data empty")
	sock:close()
	wait_done()
end)

testaux.case("Test 4: Error condition - abrupt connection close", function()
	server_handler = function(sock)
		local data, typ = sock:read()
		testaux.asserteq(data, nil, "Read broken data returns nil")
		testaux.asserteq(typ, errno.EOF, "Read broken returns EOF error")
	end

	local sock = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.assertneq(sock, nil, "Client connected")
	assert(sock)
	sock.conn:close()
	wait_done()
end)

testaux.case("Test 5: TLS encrypted connection", function()
	tls_server_handler = function(sock)
		sock:write("secure", "text")
		sock:close()
	end

	local sock = websocket.connect("wss://" .. TEST_HOST .. ":" .. TLS_PORT)
	testaux.assertneq(sock, nil, "TLS connection succeeds")
	assert(sock)
	local data, typ = sock:read()
	testaux.asserteq(typ, "text", "TLS data type correct")
	testaux.asserteq(data, "secure", "TLS data content correct")
	sock:close()

	local sock2, err = websocket.connect("wss://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.asserteq(sock2, nil, "wss can't connect to non-TLS server")
	testaux.assertneq(err, nil, "wss connection should return error")
	testaux.assertneq(err, ETIMEDOUT, "wss error should not be read timeout")
	local err_l = string.lower(tostring(err))
	local ok = err_l:find("ssl", 1, true) ~= nil
		or err_l:find("tls", 1, true) ~= nil
		or err_l:find("handshake", 1, true) ~= nil
		or err_l:find("eof", 1, true) ~= nil
		or err_l:find("protocol", 1, true) ~= nil
		or err_l:find("wrong version", 1, true) ~= nil
		or err_l:find("connection reset", 1, true) ~= nil
		or err_l:find("closed", 1, true) ~= nil
		or err_l:find("record", 1, true) ~= nil
	testaux.asserteq(ok, true, "wss connection error correct")
	wait_done()
end)

testaux.case("Test 6: Concurrent stress test", function()
	server_handler = function(sock)
		time.sleep(300)
		sock:write("foo", "pong")
		sock:close()
	end
	local wg = waitgroup.new()
	for _ = 1, STRESS_TEST_CLIENTS do
		wg:fork(function()
			local sock = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
			testaux.assertneq(sock, nil, "Concurrent connection succeeds")
			assert(sock)
			local ok = sock:write("bar", "ping")
			testaux.asserteq(ok, true, "Write ping succeeds")
			local data, typ = sock:read()
			testaux.asserteq(data, "foo", "Read pong data")
			testaux.asserteq(typ, "pong", "Read pong type")
			sock:close()
		end)
	end
	wg:wait()
	wait_done()
end)

testaux.case("Test 7: WebSocket DNS failure returns contextual string", function()
	testaux.with_mocked_dns(function(host, qtype)
		return nil, "Query timed out (10001)"
	end, {"silly.net.websocket"}, function(reloaded)
		local mock_ws = reloaded["silly.net.websocket"]
		local sock, err = mock_ws.connect("ws://dns-fail.test:10005")
		testaux.asserteq(sock, nil, "Test 7.1: WebSocket connect should fail on DNS error")
		testaux.assertcontains(err, "dns lookup",
			"Test 7.2: Error should mention dns lookup")
		testaux.assertcontains(err, "dns-fail.test",
			"Test 7.3: Error should include the failing host")
		testaux.assertcontains(err, "timed out",
			"Test 7.4: Error should propagate underlying DNS reason")
	end)
end)

-- Read wire frames independently of websocket.read(), including their mask and length encoding.
local function readwire(conn)
	local header = assert(conn:read(2, 1000))
	local first, second = header:byte(1, 2)
	local code = second & 0x7f
	local size = code
	if code == 126 then
		local extra = assert(conn:read(2, 1000))
		header = header .. extra
		size = string.unpack(">I2", extra)
	elseif code == 127 then
		local extra = assert(conn:read(8, 1000))
		header = header .. extra
		size = string.unpack(">I8", extra)
	end
	local key = ""
	if second & 0x80 ~= 0 then
		key = assert(conn:read(4, 1000))
	end
	local payload = ""
	if size > 0 then
		payload = assert(conn:read(size, 1000))
	end
	return {fin = first >> 7, op = first & 0x0f, masked = second & 0x80 ~= 0,
		code = code, size = size, key = key, payload = payload, wire = header .. key .. payload}
end

for i, spec in ipairs({
	{size = 0, frames = {{0, 0}}},
	{size = 124, frames = {{124, 124}}},
	{size = 125, frames = {{125, 125}}},
	{size = 126, frames = {{126, 126}}},
	{size = 65534, frames = {{65534, 126}}},
	{size = 65535, frames = {{65535, 126}}},
	{size = 65536, frames = {{65536, 127}}},
	{size = 65537, frames = {{65536, 127}, {1, 1}}},
}) do
	testaux.case("Test 8." .. i .. ": Client frame length boundary " .. spec.size, function()
		local utils = require "silly.crypto.utils"
		local finished = channel.new()
		server_handler = function(sock)
			local ok, frames = pcall(function()
				local result = {}
				repeat
					result[#result + 1] = readwire(sock.conn)
				until result[#result].fin == 1
				return result
			end)
			sock.conn:close()
			finished:push({ok = ok, frames = frames})
		end
		local sock = assert(websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT))
		local payload = string.rep("x", spec.size)
		assert(sock:write(payload, "binary"))
		local result = testaux.await(finished, "client frames reach the wire reader")
		sock:close()
		assert(result.ok, result.frames)
		testaux.asserteq(#result.frames, #spec.frames, "Test 8." .. i .. ": Fragment count matches the message")
		local parts = {}
		for n, frame in ipairs(result.frames) do
			local expected_size, expected_code = table.unpack(spec.frames[n])
			local label = "Test 8." .. i .. "." .. n .. ": "
			testaux.asserteq(frame.masked, true, label .. "Every client fragment is masked")
			testaux.asserteq(#frame.key, 4, label .. "Every client fragment contains its masking key")
			testaux.asserteq(frame.code, expected_code, label .. "Payload length uses the shortest encoding")
			testaux.asserteq(frame.size, expected_size, label .. "Fragment length matches its payload")
			testaux.asserteq(frame.op, n == 1 and 2 or 0, label .. "Later fragments use continuation opcode")
			parts[#parts + 1] = utils.xor(frame.key, frame.payload)
		end
		testaux.asserteq(table.concat(parts), payload, "Test 8." .. i .. ": Masked fragments preserve data")
	end)
end

local function randomclient(generator)
	local random = require "silly.crypto.random"
	local bytes = random.bytes
	local loaded = package.loaded["silly.net.websocket"]
	random.bytes = generator
	package.loaded["silly.net.websocket"] = nil
	local ok, client = pcall(require, "silly.net.websocket")
	random.bytes = bytes
	package.loaded["silly.net.websocket"] = loaded
	assert(ok, client)
	return client
end

testaux.case("Test 9: Client controls and Close use a new cryptographic key for each frame", function()
	local finished = channel.new()
	local calls = {}
	local keys = {"\x37\xfa\x21\x3d", "\0\0\0\0", "\xff\xee\xaa\0",
		"\x10\x20\x30\x40", "\x50\x60\x70\x80", "\1\2\3\4"}
	local client = randomclient(function(size)
		calls[#calls + 1] = size
		if size == 16 then
			return string.rep("\0", 16)
		end
		assert(size == 4)
		return assert(keys[#calls - 1])
	end)
	server_handler = function(sock)
		local protected, frames = pcall(function()
			local result = {}
			for i = 1, 6 do
				result[i] = readwire(sock.conn).wire
			end
			return result
		end)
		sock.conn:close()
		finished:push({ok = protected, frames = frames})
	end
	local sock = assert(client.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT))
	assert(sock:write("Hello", "text"))
	assert(sock:write("", "ping"))
	assert(sock:write("pong", "pong"))
	assert(sock:write(string.rep("\0", 65537), "binary"))
	sock:close()
	local result = testaux.await(finished, "masked client control frames arrive before transport close")
	assert(result.ok, result.frames)
	testaux.asserteq(result.frames[1], "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58",
		"Test 9.1: Text frame matches the RFC 6455 masked Hello example")
	testaux.asserteq(result.frames[2], "\x89\x80\0\0\0\0", "Test 9.2: Empty Ping keeps its all-zero masking key")
	testaux.asserteq(result.frames[3], "\x8a\x84\xff\xee\xaa\0\x8f\x81\xc4\x67",
		"Test 9.3: Pong uses its own key and preserves its payload")
	testaux.asserteq(result.frames[4], "\x02\xff\0\0\0\0\0\1\0\0" .. keys[4] .. string.rep(keys[4], 16384),
		"Test 9.4: The first binary fragment uses its own key")
	testaux.asserteq(result.frames[5], "\x80\x81\x50\x60\x70\x80\x50",
		"Test 9.5: The continuation fragment uses another key")
	testaux.asserteq(result.frames[6], "\x88\x80\1\2\3\4", "Test 9.6: Active Close is masked even without a payload")
	testaux.asserteq(table.concat(calls, ","), "16,4,4,4,4,4,4",
		"Test 9.7: Handshake nonce and every frame request cryptographic randomness")
end)

for i, scheme in ipairs({"ws", "wss"}) do
	testaux.case("Test 10." .. i .. ": Handshake random failure cannot open a " .. scheme .. " transport", function()
		local transport = scheme == "ws" and tcp or require "silly.net.tls"
		local attempts = 0
		local opened
		local client = randomclient(function()
			error("test random source failure", 0)
		end)
		local connect = transport.connect
		transport.connect = function(...)
			attempts = attempts + 1
			local conn, err = connect(...)
			opened = conn
			return conn, err
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local ok, err = pcall(client.connect, scheme .. "://" .. TEST_HOST .. ":" .. port)
		transport.connect = connect
		if opened then
			opened:close()
		end
		testaux.asserteq(ok, false, "Test 10." .. i .. ".1: Handshake propagates random-source failure")
		testaux.assertcontains(err, "test random source failure", "Test 10." .. i .. ".2: Original error is retained")
		testaux.asserteq(attempts, 0, "Test 10." .. i .. ".3: Randomness is obtained before opening a transport")
	end)
end

testaux.case("Test 11: Close releases the transport when masking randomness fails", function()
	local random = require "silly.crypto.random"
	local finished = channel.new()
	local client = randomclient(function(size)
		if size == 4 then
			error("test close mask failure", 0)
		end
		return random.bytes(size)
	end)
	server_handler = function(sock)
		local data, err = sock.conn:read(1, 1000)
		sock.conn:close()
		finished:push({data = data, err = err})
	end
	local sock = assert(client.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT))
	local conn = sock.conn
	local ok, closed, err = pcall(sock.close, sock)
	local released = conn.fd == nil
	local detached = sock.conn == nil
	if not released then
		conn:close()
	end
	local peer = testaux.await(finished, "peer observes transport close without a Close frame")
	testaux.asserteq(released, true, "Test 11.1: Close releases the socket despite mask generation failure")
	testaux.asserteq(detached, true, "Test 11.2: Closed WebSocket detaches its transport")
	testaux.asserteq(ok and closed, true, "Test 11.3: Best-effort Close still closes successfully")
	testaux.asserteq(err, nil, "Test 11.4: Transport close succeeds")
	testaux.asserteq(peer.data, nil, "Test 11.5: No unmasked Close frame is sent")
	testaux.asserteq(peer.err, errno.EOF, "Test 11.6: Peer sees EOF rather than waiting for data")
end)

for i, scheme in ipairs({"ws", "wss"}) do
	testaux.case("Test 12." .. i .. ": Closed " .. scheme .. " sockets fail without throwing", function()
		local done = channel.new()
		local handler = function(sock)
			sock:read()
			sock:close()
			done:push(true)
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		assert(sock:close())
		local readok, data, readerr = pcall(sock.read, sock)
		local writeok, written, writeerr = pcall(sock.write, sock, "late")
		local closeok, closed, closeerr = pcall(sock.close, sock)
		testaux.await(done, "peer finishes after owner close")
		testaux.asserteq(readok, true, "Closed read returns an error")
		testaux.asserteq(data, nil, "Closed read returns no data")
		testaux.assertneq(readerr, nil, "Closed read reports closure")
		testaux.asserteq(writeok, true, "Closed write returns an error")
		testaux.asserteq(written, false, "Closed write accepts no data")
		testaux.assertneq(writeerr, nil, "Closed write reports closure")
		testaux.asserteq(closeok, true, "Repeated close does not throw")
		testaux.asserteq(closed, false, "Repeated close reports already closed")
		testaux.assertneq(closeerr, nil, "Repeated close reports closure")
	end)
	testaux.case("Test 13." .. i .. ": No " .. scheme .. " messages follow a sent Close", function()
		local done = channel.new()
		local handler = function(sock)
			sock:read()
			sock:close()
			done:push(true)
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		assert(sock:write("", "close"))
		local ok, err = sock:write("late", "text")
		sock:close()
		testaux.await(done, "peer finishes the Close exchange")
		testaux.asserteq(ok, false, "A sent Close prevents further messages")
		testaux.assertneq(err, nil, "Write after Close reports closure")
	end)
	testaux.case("Test 14." .. i .. ": Upgrade transfers " .. scheme .. " read ownership", function()
		local transferred = channel.new()
		local done = channel.new()
		local handler = function(sock)
			transferred:push(sock)
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		local peer = testaux.await(transferred, "handler returns its upgraded socket")
		task.fork(function()
			local ok, data, typ = pcall(peer.read, peer)
			done:push({ok = ok, data = data, typ = typ})
		end)
		assert(sock:write("handoff", "text"))
		local result = testaux.await(done, "new owner receives a complete message")
		sock:close()
		peer:close()
		testaux.asserteq(result.ok, true, "HTTP and WebSocket do not compete for reads")
		testaux.asserteq(result.data, "handoff", "HTTP does not consume WebSocket frame bytes")
		testaux.asserteq(result.typ, "text", "Transferred socket retains its frame type")
	end)
end

for i, secure in ipairs({false, true}) do
	for j, closedconn in ipairs({false, true}) do
		testaux.case("Test 15." .. i .. "." .. j .. ": Upgrade propagates response write failures", function()
			local metrics = require "silly.metrics.c"
			local done = channel.new()
			local listener = assert(http.listen {
				addr = "127.0.0.1:0", tls = secure,
				certs = {{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}},
				handler = function(stream)
					if closedconn then
						stream.conn:close()
					else
						assert(stream:respond(200, {}, true))
					end
					local sock, err = websocket.upgrade(stream)
					if sock then
						sock:close()
					end
					done:push({accepted = sock ~= nil, err = err})
				end,
			})
			local scheme = secure and "wss://" or "ws://"
			local sock = websocket.connect(scheme .. metrics.socketstat(listener.fd).localaddr)
			if sock then
				sock:close()
			end
			local result = testaux.await(done, "failed upgrade completes")
			listener:close()
			testaux.asserteq(result.accepted, false, "A failed 101 response cannot return a usable socket")
			testaux.assertneq(result.err, nil, "The response error reaches the upgrade caller")
		end)
	end
end

for i, scheme in ipairs({"ws", "wss"}) do
	testaux.case("Test 16." .. i .. ": Invalid outgoing messages leave " .. scheme .. " usable", function()
		local done = channel.new()
		local handler = function(sock)
			local data, kind = sock:read()
			sock:close()
			done:push({data = data, kind = kind})
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		local rejected = {}
		for _, spec in ipairs({
			{"\xff", "text"}, {"x", "close"}, {"\x03\xed", "close"},
			{"\x03\xe8\xff", "close"},
		}) do
			local ok, err = sock:write(spec[1], spec[2])
			rejected[#rejected + 1] = {ok = ok, err = err}
		end
		assert(sock:write("ok", "text"))
		sock:close()
		local received = testaux.await(done, "only the valid message reaches the peer")
		for _, result in ipairs(rejected) do
			testaux.asserteq(result.ok, false, "Invalid messages are rejected before writing")
			testaux.assertneq(result.err, nil, "Invalid messages report their error")
		end
		testaux.asserteq(received.data, "ok", "Rejected input does not send bytes or close the write side")
		testaux.asserteq(received.kind, "text", "A valid text message still succeeds")
	end)
end

for i, url in ipairs({
	"http://" .. TEST_HOST .. ":" .. TEST_PORT,
	"ws://" .. TEST_HOST .. ":" .. TEST_PORT .. "/#fragment",
}) do
	testaux.case("Test 17." .. i .. ": Invalid WebSocket URL is rejected before opening", function()
		local sock, err = websocket.connect(url)
		if sock then
			sock:close()
		end
		testaux.asserteq(sock, nil, "An HTTP URL or fragment cannot establish WebSocket")
		testaux.assertcontains(err, "WebSocket URL", "The URL error is reported to the caller")
	end)
end

for i, scheme in ipairs({"ws", "wss"}) do
	testaux.case("Test 18." .. i .. ": A sent Close still permits a required " .. scheme .. " Pong", function()
		local done = channel.new()
		local handler = function(sock)
			local ok, result = pcall(function()
				assert(sock.conn:write("\x89\x01p"))
				local close = readwire(sock.conn)
				local pong = readwire(sock.conn)
				local utils = require "silly.crypto.utils"
				return {close = close.op, pong = pong.op, data = utils.xor(pong.key, pong.payload)}
			end)
			sock:close()
			done:push({ok = ok, result = result})
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		assert(sock:write("", "close"))
		local data, kind = sock:read()
		local ok, err = sock:write(data, "pong")
		sock:close()
		local result = testaux.await(done, "peer observes Close followed by Pong")
		testaux.asserteq(kind, "ping", "A Ping can arrive while waiting for the peer's Close")
		testaux.asserteq(ok, true, "Sending Close does not suppress the required Pong")
		testaux.asserteq(err, nil, "A required Pong succeeds before receiving Close")
		assert(result.ok, result.result)
		testaux.asserteq(result.result.close, 8, "The first frame starts the close handshake")
		testaux.asserteq(result.result.pong, 10, "The following frame is a Pong")
		testaux.asserteq(result.result.data, "p", "Pong echoes the Ping payload")
	end)
end

for i, scheme in ipairs({"ws", "wss"}) do
	testaux.case("Test 19." .. i .. ": Message limit changes while " .. scheme .. " payload read waits", function()
		local release = channel.new()
		local payload = channel.new()
		local received = channel.new()
		local done = channel.new()
		local handler = function(sock)
			local ok, result = pcall(function()
				assert(sock.conn:write("\x82\x04"))
				testaux.await(release, "message limit changes before payload arrives")
				assert(sock.conn:write("data"))
				local frame = readwire(sock.conn)
				local utils = require "silly.crypto.utils"
				return string.unpack(">I2", utils.xor(frame.key, frame.payload))
			end)
			sock:close()
			done:push({ok = ok, code = result})
		end
		if scheme == "ws" then
			server_handler = handler
		else
			tls_server_handler = handler
		end
		local port = scheme == "ws" and TEST_PORT or TLS_PORT
		local sock = assert(websocket.connect(scheme .. "://" .. TEST_HOST .. ":" .. port))
		sock:limit(8)
		local read = sock.conn.read
		sock.conn.read = function(conn, n, ...)
			if n == 4 then
				payload:push(true)
			end
			return read(conn, n, ...)
		end
		task.fork(function()
			local data, err = sock:read()
			received:push({data = data, err = err})
		end)
		testaux.await(payload, "payload read is pending after its header check")
		sock:limit(2)
		release:push(true)
		local result = testaux.await(received, "pending read applies the new message limit")
		sock:close()
		local peer = testaux.await(done, "peer observes the size rejection")
		testaux.asserteq(result.data, nil, "A read cannot return a message above its new limit")
		testaux.assertcontains(result.err, "Message", "Message limit errors survive a suspended read")
		assert(peer.ok, peer.code)
		testaux.asserteq(peer.code, 1009, "The peer receives Close status 1009")
	end)
end

server:close()
tls_server:close()
