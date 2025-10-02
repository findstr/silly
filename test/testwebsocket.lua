local silly = require "silly"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local websocket = require "silly.websocket"
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

local server, err = websocket.listen {
	addr = TEST_HOST .. ":" .. TEST_PORT,
	handler = function(sock)
		server_handler(sock)
		server_handler = nop
	end,
}
testaux.asserteq(not not server, true, "start websocket server")

local tls_server, err = websocket.listen {
	tls = true,
	addr = TEST_HOST .. ":" .. TLS_PORT,
	certs = {
		{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}
	},
	handler = function(sock)
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

-- Test 1: Basic connection establishment
do
	server_handler = function(sock)
		sock:close()
	end
	local sock, err = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.asserteq(not not sock, true, "Test 1: Basic connection")
	testaux.asserteq(err, nil, "Test 1: Basic connection")
	assert(sock)
	sock:close()
	wait_done()
end

-- Test 2: Frame validation (Enhanced)
do
	-- Extended test vectors with RFC 6455 edge cases
	local test_vectors = {
		-- Basic types
		{data = "", type = "text", true, desc = "Empty text frame"},
		{data = "Hello", type = "text", true, desc = "text frame"},
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
	local case_num = 0
	for _, vec in ipairs(test_vectors) do
		case_num = case_num + 1
		---@param sock silly.websocket.socket
		server_handler = function(sock)
			local received = {}
			local total_len = 0
			while true do
				local data, typ = sock:read()
				testaux.assertneq(data, nil, string.format("Test 2.%s: read frame", case_num))
				if not data or typ == "close" then -- EOF
					break
				end
				testaux.asserteq(typ, vec.type, string.format("Test 2.%s: frame type check", case_num))
				testaux.asserteq(typ, vec.type, string.format("Test 2.%s: frame type check", case_num))
				if #data > 0 then
					received[#received + 1] = data
				end
				total_len = total_len + #data
			end
			local final_data = table.concat(received)
			testaux.asserteq(#final_data, #vec.data, "Length mismatch")
			testaux.asserteq(final_data, vec.data, "Content mismatch")
			sock:close()
		end

		-- Client-side test execution
		local sock, err = websocket.connect("ws://"..TEST_HOST..":"..TEST_PORT)
		testaux.asserteq(not not sock, true, string.format("Test 2.%s: Connect server", case_num))
		assert(sock)
		local ok, err = sock:write(vec.data, vec.type)
		testaux.asserteq(ok, true, string.format("Test 2.%s: Write data", case_num))
		sock:close()
		wait_done()
	end
	-- test client read
	for _, vec in ipairs(test_vectors) do
		case_num = case_num + 1
		server_handler = function(sock)
			sock:write(vec.data, vec.type)
			sock:close()
		end
		local sock, err = websocket.connect("ws://"..TEST_HOST..":"..TEST_PORT)
		testaux.asserteq(not not sock, true, string.format("Test 2.%s: Connect server", case_num))
		assert(sock)
		local data, typ = sock:read()
		testaux.asserteq(data, vec.data, string.format("Test 2.%s: Read data", case_num))
		testaux.asserteq(typ, vec.type, string.format("Test 2.%s: Read type", case_num))
		sock:close()
		wait_done()
	end
end

-- Test 3: Control frames handling
do
	server_handler = function(sock)
		-- Test Ping with data
		sock:write("bar", "ping")
		local data, typ = sock:read()
		testaux.asserteq(typ, "pong", "Test 3: Missing pong response")
		testaux.asserteq(data, "foo", "Test 3: Pong data mismatch")
		sock:close()
	end

	local sock, err = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.asserteq(not not sock, true, "Test 3: Connect server")
	assert(sock)
	-- Handle server ping
	local data, typ = sock:read()
	testaux.asserteq(data, "bar", "Test 3: Ping data")
	testaux.asserteq(typ, "ping", "Test 3: Ping frame type")
	local ok = sock:write("foo", "pong")
	testaux.asserteq(ok, true, "Test 3: Pong write")

	-- Verify close handshake
	local dat, type = sock:read()
	testaux.asserteq(type, "close", "Test 3: Close frame not received")
	testaux.asserteq(dat, "", "Test 3: Close frame data mismatch")
	sock:close()
	wait_done()
end

-- Test 4: Error condition handling
do
	server_handler = function(sock)
		local data, typ = sock:read()
		testaux.asserteq(data, nil, "Test 4: read broken data")
		testaux.asserteq(typ, "end of file", "Test 4: read broken error")
	end

	local sock = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.asserteq(not not sock, true, "Test 4: Connect server")
	assert(sock)
	tcp.close(sock.fd)
	wait_done()
end

-- Test 5: TLS encrypted connection
do
	tls_server_handler = function(sock)
		sock:write("secure", "text")
		sock:close()
	end

	local sock, err = websocket.connect("wss://" .. TEST_HOST .. ":" .. TLS_PORT)
	testaux.asserteq(not not sock, true, "Test 5: Connect server")
	assert(sock)
	local data, typ = sock:read()
	testaux.asserteq(typ, "text", "Test 5: TLS data type check")
	testaux.asserteq(data, "secure", "Teset 5: TLS data content check")
	sock:close()

	print("connect tls", sock, err)
	local sock, err = websocket.connect("wss://" .. TEST_HOST .. ":" .. TEST_PORT)
	testaux.asserteq(sock, nil, "Test 5: wss can't Connect non-tls server")
	testaux.asserteq(err, "end of file", "Test 5: wss can't Connect non-tls error")
	wait_done()
end

-- Test 6: Concurrent stress test
do
	server_handler = function(sock)
		time.sleep(300)
		sock:write("foo", "pong")
		sock:close()
	end
	local wg = waitgroup.new()
	for i = 1, STRESS_TEST_CLIENTS do
		wg:fork(function()
			local sock = websocket.connect("ws://" .. TEST_HOST .. ":" .. TEST_PORT)
			testaux.asserteq(not not sock, true, "Test 6: Connect server")
			assert(sock)
			local ok, err = sock:write("bar", "ping")
			testaux.asserteq(ok, true, "Test 6: Write ping")
			local data, typ = sock:read()
			testaux.asserteq(data, "foo", "Test 6: Read pong")
			testaux.asserteq(typ, "pong", "Test 6: Read pong type")
			sock:close()
		end)
	end
	wg:wait()
	wait_done()
end