local silly = require "silly"
local logger = require "silly.logger"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local waitgroup = require "silly.sync.waitgroup"
local testaux = require "test.testaux"

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
		testaux.asserteq(typ, "end of file", "Read broken returns EOF error")
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
	testaux.asserteq(err, "end of file", "wss connection error correct")
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

server:close()
tls_server:close()