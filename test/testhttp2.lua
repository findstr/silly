local silly = require "silly"
local pcall = silly.pcall
local task = require "silly.task"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local tls = require "silly.net.tls"
local h2 = require "silly.net.http.h2"
local channel = require "silly.sync.channel"
local json = require "silly.encoding.json"
local http = require "silly.net.http"
local crypto = require "silly.crypto.utils"
local gzip = require "silly.compress.gzip"
local testaux = require "test.testaux"
local errno = require "silly.errno"

-- NOTE (test-only use of silly.errno):
-- EEOF is used here to white-box test that silly.net.http.h2 actually
-- surfaces silly.errno values internally. Production code must NOT
-- compare h2 stream errors against silly.errno — h2's public contract
-- is `string?`, and only silly.net / silly.net.{tcp,tls,udp} callers
-- may branch on silly.errno values.
local EEOF<const> = errno.EOF

local set_nil = true
local server_handler
local handler_done = channel.new()
local readers, wait_readers = testaux.trackconnections(tls)

local server = http.listen {
	tls = true,
	addr = "127.0.0.1:8082",
	alpnprotos = {
		"h2",
	},
	certs = {
		{
			cert = testaux.CERT_DEFAULT,
			key = testaux.KEY_DEFAULT,
		}
	},
	handler = function(stream)
		server_handler(stream)
		if set_nil then
			server_handler = nil
		end
		handler_done:push(true)
	end
}

-- Create a test client for connection pool testing
local httpc = http.newclient({
	max_idle_per_host = 10,
	idle_timeout = 2000,  -- 2 seconds for faster cleanup in tests
})

local function wait_done()
	if server_handler then
		testaux.await(handler_done, "server handler completed")
	end
	handler_done:clear()
end

local function case(name, fn)
	testaux.case(name, function()
		handler_done:clear()
		local ok, err = pcall(fn)
		server_handler = nil
		set_nil = true
		if not ok then
			error(err)
		end
	end)
end

case("Test 1: Basic HTTP/2 Server Setup", function()
	testaux.asserteq(not not server, true, "Server should start successfully")
end)


case("Test 2: HTTP/2 Chunked Transfer", function()
	server_handler = function(stream)
		print("Test 2")
		testaux.asserteq(stream.version, "HTTP/2", "Test 2.1: Should be HTTP/2")
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:write("Hello")
		stream:write("World")
		stream:closewrite()
		print("xxxxxxxx")
	end
	local response = httpc:get("https://127.0.0.1:8082")
	testaux.asserteq(response.body, "HelloWorld", "Test 2.2: Chunked transfer should be properly decoded")
	wait_done()
end)

case("Test 3: HTTP/2 Content-Length and Request Body", function()
	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "Hello Server", "Test 3.1: Server should receive request body")
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("Received")
	end
	local response = httpc:post("https://127.0.0.1:8082/foo", {
		["content-type"] = "text/plain"
	}, "Hello Server")
	testaux.assertneq(response, nil, "Test 3.2: POST request should succeed")
	testaux.asserteq(response.body, "Received", "Test 3.3: Server should acknowledge receipt")
	testaux.asserteq(response.status, 200, "Test 3.4: Status code should be 200")
	wait_done()
end)

case("Test 4: HTTP/2 Query Parameters", function()
	server_handler = function(stream)
		local query = stream.query
		testaux.asserteq(query["name"], "test", "Test 4.1: Server should receive query parameters")
		testaux.asserteq(query["value"], "123", "Test 4.1: Server should receive query parameters")
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("Query OK")
	end

	local response = httpc:get("https://127.0.0.1:8082?name=test&value=123")
	testaux.assertneq(response, nil, "Test 4.2: GET with query should succeed")
	testaux.asserteq(response.body, "Query OK", "Test 4.3: Server should process query")
	wait_done()
end)

case("Test 5: HTTP/2 Status Codes", function()
	local status_codes = {
		[200] = "OK",
		[201] = "Created",
		[204] = "No Content",
		[400] = "Bad Request",
		[401] = "Unauthorized",
		[403] = "Forbidden",
		[404] = "Not Found",
		[500] = "Internal Server Error"
	}

	for code, reason in pairs(status_codes) do
		server_handler = function(stream)
			if code ~= 204 then  -- 204 No Content should not have body
				stream:respond(code, {
					["content-type"] = "text/plain",
				})
				stream:closewrite("Status: " .. reason)
			else
				stream:respond(code, {["content-type"] = "text/plain"})
				stream:closewrite()
			end
		end

		local response = httpc:get("https://127.0.0.1:8082")
		testaux.assertneq(response, nil, "Test 5." .. code .. ": Response should be received")
		testaux.asserteq(response.status, code, "Test 5." .. code .. ": Status code should be " .. code)
		if code ~= 204 then
			testaux.asserteq(response.body, "Status: " .. reason, "Test 5." .. code .. ": Body should match")
		else
			testaux.asserteq(response.body, "", "Test 5.204: Body should be empty for 204")
		end
		wait_done()
	end
end)

case("Test 6: HTTP/2 Headers Processing", function()
	server_handler = function(stream)
		local user_agent = stream.header["user-agent"] or ""
		local accept = stream.header["accept"] or ""
		local x_test_header2 = stream.header["x-test-header2"]

		testaux.assertneq(user_agent, "", "Test 6.2: Server should receive User-Agent header")
		testaux.assertneq(accept, "", "Test 6.3: Server should receive Accept header")
		testaux.asserteq(type(x_test_header2), "table", "Test 6.4: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[1], "client-value1", "Test 6.5: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[2], "client-value2", "Test 6.6: Server should receive x-test-header2 as table")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["x-custom-header"] = "test-value",
			["x-empty-header"] = "",
			["x-test-header2"] = {
				"server-value1",
				"server-value2"
			}
		})
		stream:closewrite("Headers OK")
	end

	local response = httpc:get("https://127.0.0.1:8082", {
		["user-agent"] = "Test Client",
		["accept"] = "text/plain, application/json",
		["x-test-header"] = "client-value",
		["x-test-header2"] = {
			"client-value1",
			"client-value2"
		}
	})

	testaux.assertneq(response, nil, "Test 6.1: GET with headers should succeed")
	testaux.asserteq(response.header["x-custom-header"], "test-value", "Test 6.7: Response should include custom header")
	testaux.asserteq(response.header["x-empty-header"], "", "Test 6.8: Response should include empty header")
	testaux.asserteq(response.header["x-test-header2"][1], "server-value1", "Test 6.9: Response should include x-test-header2 as table")
	testaux.asserteq(response.header["x-test-header2"][2], "server-value2", "Test 6.10: Response should include x-test-header2 as table")
	wait_done()
end)

case("Test 7: Content-Type and Accept Headers", function()
	local function x(stream)
		local accept = stream.header["accept"] or "*/*"
		if accept:find("application/json", 1, true) then
			local dat = json.encode({status = "success", message = "JSON response"})
			stream:respond(200, {
				["content-type"] = "application/json",
			})
			stream:closewrite(dat)
		else
			stream:respond(200, {
				["content-type"] = "text/plain",
			})
			stream:closewrite("Plain text response")
		end
	end

	server_handler = x
	-- Test with Accept: application/json
	local response = httpc:get("https://127.0.0.1:8082", {
		["accept"] = "application/json"
	})
	testaux.assertneq(response, nil, "Test 7.1: JSON request should succeed")
	testaux.asserteq(response.header["content-type"], "application/json", "Test 7.2: Content-Type should be application/json")
	local decoded = json.decode(response.body)
	testaux.assertneq(decoded, nil, "Test 7.3: Response should be valid JSON")
	testaux.asserteq(decoded.status, "success", "Test 7.4: JSON content should be correct")

	-- Test with Accept: text/plain
	server_handler = x
	local response = httpc:get("https://127.0.0.1:8082", {
		["accept"] = "text/plain"
	})
	testaux.assertneq(response, nil, "Test 7.5: Text request should succeed")
	testaux.asserteq(response.header["content-type"], "text/plain", "Test 7.6: Content-Type should be text/plain")
	testaux.asserteq(response.body, "Plain text response", "Test 7.7: Text content should be correct")
	wait_done()
end)

case("Test 8: client.request API - Basic GET", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "GET", "Test 8.1: Method should be GET")
		testaux.asserteq(stream.path, "/api/test", "Test 8.2: Path should be /api/test")
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082/api/test", {})
	testaux.assertneq(stream, nil, "Test 8.3: stream should not be nil")
	testaux.asserteq(err, nil, "Test 8.4: err should be nil")
	stream:closewrite()
	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 8.4.1: waitresponse should succeed")
	testaux.asserteq(stream.status, 200, "Test 8.5: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 8.6: body should be OK")
	wait_done()
end)

case("Test 9: client.request API - POST with body", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "POST", "Test 9.1: Method should be POST")
		local body, err = stream:readall()
		testaux.asserteq(body, "Request Data", "Test 9.2: body should be 'Request Data'")
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("Received")
	end

	local stream<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
		["content-length"] = 12,
	})
	testaux.assertneq(stream, nil, "Test 9.3: stream should not be nil")

	stream:closewrite("Request Data")
	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 9.4: waitresponse should succeed")
	testaux.asserteq(stream.status, 200, "Test 9.5: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "Received", "Test 9.6: body should be 'Received'")
	wait_done()
end)

case("Test 10: client.request API - Multiple writes", function()
	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "part1part2part3", "Test 10.1: body should be concatenated")
		stream:respond(200, {})
		stream:closewrite("OK")
	end

	local stream<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 10.2: stream should not be nil")

	stream:write("part1")
	stream:write("part2")
	stream:closewrite("part3")
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 10.3: body should be OK")
	wait_done()
end)

case("Test 11: client.request API - HEAD request", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "HEAD", "Test 11.1: Method should be HEAD")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 100,
		})
		stream:closewrite()
	end

	local stream<close>, err = httpc:request("HEAD", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 11.2: stream should not be nil")
	stream:closewrite()
	stream:waitresponse()
	testaux.asserteq(stream.status, 200, "Test 11.3: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "", "Test 11.5: body should be empty for HEAD")
	wait_done()
end)

case("Test 12: Trailer headers with chunked", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:write("data1")
		stream:write("data2")
		stream:closewrite(nil, {
			["x-checksum"] = "abc123",
			["x-final-status"] = "complete"
		})
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 12.1: stream should not be nil")
	testaux.asserteq(err, nil, "Test 12.2: err should be nil")
	stream:closewrite()
	stream:waitresponse()
	local body, err = stream:readall()
	testaux.asserteq(body, "data1data2", "Test 12.3: body should be concatenated")
	testaux.assertneq(stream.trailer, nil, "Test 12.4: trailer should be received")
	testaux.asserteq(stream.trailer["x-checksum"], "abc123", "Test 12.5: trailer header should match")
	testaux.asserteq(stream.trailer["x-final-status"], "complete", "Test 12.6: trailer header should match")
	wait_done()
end)

case("Test 13: stream:read(n) - partial reads with small data", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("12345678901234567890")
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 13.1: Request should succeed")
	stream:closewrite()
	stream:waitresponse()

	-- Read 5 bytes at a time
	local chunk1, err = stream:read(5)
	testaux.asserteq(chunk1, "12345", "Test 13.2: First read should get 5 bytes")

	local chunk2, err = stream:read(5)
	testaux.asserteq(chunk2, "67890", "Test 13.3: Second read should get 5 bytes")

	local chunk3, err = stream:read(5)
	testaux.asserteq(chunk3, "12345", "Test 13.4: Third read should get 5 bytes")

	local chunk4, err = stream:read(5)
	testaux.asserteq(chunk4, "67890", "Test 13.5: Fourth read should get 5 bytes")

	-- Read after EOF should return nil, EOF
	local chunk5, err = stream:read(5)
	testaux.asserteq(chunk5, nil, "Test 13.6: Read after EOF should return nil")
	testaux.asserteq(err, EEOF, "Test 13.7: err should be EOF after stream ended")

	wait_done()
end)

case("Test 14: stream:read(n) - partial reads with multiple writes", function()
	server_handler = function(stream)
		stream:respond(200, {})
		stream:write("AAAAA")  -- 5 bytes
		stream:write("BBBBB")  -- 5 bytes
		stream:write("CCCCC")  -- 5 bytes
		stream:write("DDDDD")  -- 5 bytes
		stream:closewrite()
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 14.1: Request should succeed")
	stream:closewrite()
	stream:waitresponse()

	-- Read 7 bytes - should span across chunks and get exactly 7 bytes
	local chunk1, err = stream:read(7)
	testaux.asserteq(chunk1, "AAAAABB", "Test 14.2: First read should get exactly 7 bytes (spans chunks)")

	-- Read 8 bytes - should get exactly 8 bytes
	local chunk2, err = stream:read(8)
	testaux.asserteq(chunk2, "BBBCCCCC", "Test 14.3: Second read should get exactly 8 bytes")

	-- Read 3 bytes
	local chunk3, err = stream:read(3)
	testaux.asserteq(chunk3, "DDD", "Test 14.4: Third read should get exactly 3 bytes")

	-- Read rest (2 bytes left)
	local chunk4, err = stream:read(10)
	testaux.asserteq(chunk4, nil, "Test 14.5: Fourth read should get nil")
	testaux.asserteq(err, EEOF, "Test 14.6: err should be EOF")

	local chunk5, err = stream:readall()
	testaux.asserteq(chunk5, "DD", "Test 14.7: Fifth read should get exactly 	2 bytes")
	testaux.asserteq(err, nil, "Test 14.8: err should be nil")

	-- Concatenate and verify total
	local total = chunk1 .. chunk2 .. chunk3 .. (chunk4 or "") .. chunk5
	testaux.asserteq(total, "AAAAABB" .. "BBBCCCCC" .. "DDD" .. "" .. "DD", "Test 14.6: Total should be all data read")
	testaux.asserteq(#total, 20, "Test 14.7: Total should be exactly 20 bytes")

	wait_done()
end)

case("Test 15: stream:read(n) - read more than available", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("SHORT")
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 15.1: Request should succeed")
	stream:closewrite()
	stream:waitresponse()

	-- Try to read 100 bytes, but only 5 available before EOF
	local chunk, err = stream:read(100)
	testaux.asserteq(chunk, nil, "Test 15.2: read should return nil when requesting more than available")
	testaux.asserteq(err, EEOF, "Test 15.3: err should be EOF when requesting more than available")

	local chunk2, err2 = stream:readall()
	testaux.asserteq(chunk2, "SHORT", "Test 15.4: readall should return remaining data")
	testaux.asserteq(err2, nil, "Test 15.5: err should be nil")

	wait_done()
end)

case("Test 16: Flow control - Stream window 63KB single stream", function()
	local ch = channel.new()
	local data = crypto.randomkey(63 * 1024)
	server_handler = function(stream)
		ch:pop()
		local dat = stream:readall()
		testaux.asserteq(dat, data, "Test 16.4: body should be the same as the data")
		stream:respond(200, {})
		stream:closewrite("OK")
	end

	local stream<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
		["content-length"] = #data,
	})
	testaux.assertneq(stream, nil, "Test 16.1: stream should not be nil")
	-- Write 63KB - this should consume most of stream window (65535 initial)
	stream:write(data)
	readers[stream.channel.conn]:waituntil(function()
		return stream.channel.sendwindow == 4 * 1024 * 1024
	end, "connection WINDOW_UPDATE applied")
	testaux.asserteq(stream.sendwindow, 1023, "Test 16.2: sendwindow should be 1023")
	testaux.asserteq(stream.channel.sendwindow, 4*1024*1024, "Test 16.3: channel sendwindow should be 65535")
	ch:push("")
	stream:closewrite()
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 16.5: Response should be OK")

	testaux.asserteq(stream.sendwindow, 65535, "Test 16.6: sendwindow should be full")
	testaux.asserteq(stream.channel.sendwindow, 4*1024*1024, "Test 16.7: channel sendwindow should be full")

	wait_done()
end)

case("Test 17: Flow control - Connection window with concurrent streams", function()
	-- Test that connection window is shared between streams
	-- Stream 1 sends 1M-1KB, then Stream 2 sends 1M-1KB
	-- This should exhaust connection window and require flow control

	local data = crypto.randomkey(4 * 1024 * 1024 - 1024)
	local stream1_arrived = channel.new()
	local stream2_arrived = channel.new()
	local release_first = channel.new()
	local requests = waitgroup.new()
	set_nil = false

	-- Server handler will be called twice
	local call_count = 0
	server_handler = function(stream)
		call_count = call_count + 1
		local current_call = call_count

		-- Mark stream arrival
		if current_call == 1 then
			stream1_arrived:push(true)
			testaux.await(release_first, "second stream arrived")
		else
			stream2_arrived:push(true)
			release_first:push(true)
		end

		local body, err = stream:readall()
		testaux.asserteq(#body, #data, "Test 17." .. current_call .. ": Should receive " .. tostring(#data) .. "KB")

		stream:respond(200, {})
		stream:closewrite("OK" .. current_call)
	end

	-- Launch two concurrent requests
	requests:fork(function()
		local s<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
			["content-length"] = #data,
		})
		testaux.assertneq(s, nil, "Test 17.1: stream1 should not be nil")

		s:closewrite(data)
		s:waitresponse()

		local body, err = s:readall()
		testaux.asserteq(body, "OK1", "Test 17.2: Stream1 response should be OK1")
	end)

	-- Wait for first stream to arrive at server
	testaux.await(stream1_arrived, "first stream arrived")

	-- Second stream
	requests:fork(function()
		local s<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
			["content-length"] = #data,
		})
		testaux.assertneq(s, nil, "Test 17.4: stream2 should not be nil")

		s:write(data)
		s:closewrite()
		s:waitresponse()

		local body, err = s:readall()
		testaux.asserteq(body, "OK2", "Test 17.5: Stream2 response should be OK2")
	end)

	-- Wait for second stream to arrive
	testaux.await(stream2_arrived, "second stream arrived")

	-- Wait for both handlers to complete
	requests:wait()
	testaux.await(handler_done, "first handler completed")
	testaux.await(handler_done, "second handler completed")
end)

case("Test 18: Flow control - Window recovery after read", function()
	-- Test that reading data sends WINDOW_UPDATE and recovers window
	local data = crypto.randomkey(66 * 1024)
	local release = channel.new()
	local writer = waitgroup.new()

	server_handler = function(stream)
		testaux.await(release, "client exhausted stream send window")
		local body, err = stream:readall()
		testaux.asserteq(#body, #data, "Test 18.1: Should receive " .. tostring(#data) .. " KB")

		stream:respond(200, {})
		stream:closewrite("OK")
	end

	local stream<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
		["content-length"] = #data,
	})
	testaux.assertneq(stream, nil, "Test 18.2: stream should not be nil")

	local started = channel.new()
	writer:fork(function()
		started:push(true)
		assert(stream:closewrite(data))
	end)
	testaux.await(started, "body writer started")
	testaux.asserteq(stream.sendwindow, 0, "Test 18: writer exhausted stream window before server reads")
	testaux.assertneq(stream.writeco, nil, "Test 18: writer waits for window credit")
	release:push(true)
	writer:wait()
	stream:waitresponse()
	testaux.asserteq(stream.sendwindow, 65535, "Test 18.2: sendwindow should be full")
	testaux.asserteq(stream.channel.sendwindow, 4*1024*1024, "Test 18.2: channel sendwindow should be full")
	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 18.3: Response should be OK")

	wait_done()
end)

case("Test 19: Connection reuse - Multiple requests on same channel", function()
	-- Test that multiple requests reuse the same HTTP/2 connection

	for i = 1, 5 do
		server_handler = function(stream)
			stream:respond(200, {})
			stream:closewrite("Response" .. i)
		end

		local response = httpc:get("https://127.0.0.1:8082/request" .. i)
		testaux.asserteq(response.status, 200, "Test 19." .. i .. ": Status should be 200")
		testaux.asserteq(response.body, "Response" .. i, "Test 19." .. i .. ": Body should match")

		wait_done()
	end

	-- Verify only one h2 connection exists
	local h2_count = 0
	for key, entries in pairs(httpc.h2pool) do
		h2_count = h2_count + #entries
	end
	testaux.asserteq(h2_count, 1, "Test 19.6: Should have exactly 1 HTTP/2 connection")
end)

case("Test 20: Connection broken during read", function()
	server_handler = function(stream)
		stream:respond(200, {})
		stream:write("partial")
		-- Break the transport; channel:close() allows accepted responses to finish.
		stream.channel.conn:close()
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 20.1: stream should not be nil")
	stream:closewrite()
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, nil, "Test 20.2: Should fail to read")
	testaux.asserteq(err, EEOF, "Test 20.3: Transport EOF is preserved")

	-- server_handler already set to nil by broken connection
	server_handler = nil
end)

case("Test 21: HTTP/2 GET with gzip compression", function()
	local original_data = "Hello HTTP/2 World! This is a test data that should be compressed with gzip. " ..
		"The more data we have, the better compression ratio we get. " ..
		"HTTP/2 supports gzip compression transparently."

	server_handler = function(stream)
		-- Compress the data
		local compressed, err = gzip.compress(original_data)
		testaux.assertneq(compressed, nil, "Test 21.1: gzip.compress should succeed")
		testaux.asserteq(err, nil, "Test 21.2: gzip.compress should not return error")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-encoding"] = "gzip",
		})
		stream:closewrite(compressed)
	end

	-- http.get should automatically decompress
	local response = httpc:get("https://127.0.0.1:8082")
	testaux.assertneq(response, nil, "Test 21.3: GET should succeed")
	testaux.asserteq(response.status, 200, "Test 21.4: Status should be 200")
	testaux.asserteq(response.body, original_data, "Test 21.5: Body should be automatically decompressed")
	testaux.asserteq(response.header["content-encoding"], "gzip", "Test 21.6: Content-Encoding header should be preserved")
	wait_done()
end)

case("Test 22: HTTP/2 POST with gzip compression response", function()
	local request_data = "Request from HTTP/2 client"
	local response_data = "This is a compressed HTTP/2 response from server. " ..
		"Adding more text to make compression more effective with HTTP/2."

	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, request_data, "Test 22.1: Server should receive uncompressed request")

		-- Compress the response
		local compressed, err = gzip.compress(response_data)
		testaux.assertneq(compressed, nil, "Test 22.2: gzip.compress should succeed")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-encoding"] = "gzip",
		})
		stream:closewrite(compressed)
	end

	-- http.post should automatically decompress
	local response = httpc:post("https://127.0.0.1:8082", {
		["content-type"] = "text/plain"
	}, request_data)
	testaux.assertneq(response, nil, "Test 22.3: POST should succeed")
	testaux.asserteq(response.status, 200, "Test 22.4: Status should be 200")
	testaux.asserteq(response.body, response_data, "Test 22.5: Body should be automatically decompressed")
	wait_done()
end)

case("Test 23: HTTP/2 GET without gzip (no Content-Encoding)", function()
	local original_data = "Uncompressed HTTP/2 data"

	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite(original_data)
	end

	-- Should work normally without decompression
	local response = httpc:get("https://127.0.0.1:8082")
	testaux.assertneq(response, nil, "Test 23.1: GET should succeed")
	testaux.asserteq(response.body, original_data, "Test 23.2: Body should remain uncompressed")
	wait_done()
end)

case("Test 24: HTTP/2 GET with Accept-Encoding header check", function()
	server_handler = function(stream)
		local accept_encoding = stream.header["accept-encoding"]
		testaux.asserteq(accept_encoding, "gzip", "Test 24.1: Client should send Accept-Encoding: gzip")

		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end

	local response = httpc:get("https://127.0.0.1:8082")
	testaux.asserteq(response.body, "OK", "Test 24.2: Response should be OK")
	wait_done()
end)

case("Test 25: HTTP/2 concurrent request admission", function()
	set_nil = false
	server_handler = function(s)
		assert(s:respond(200, {}, true))
	end
	local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
	local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
	ch.streammax = 1
	local first = assert(ch:request("GET", "/", {}, true))
	local started, done = channel.new(), channel.new()
	task.fork(function()
		started:push(true)
		local s = assert(ch:request("GET", "/", {}, true))
		done:push(s)
	end)
	testaux.await(started, "Test 25: second request entered admission")
	testaux.asserteq(ch.openwaitq:size(), 1, "Test 25.1: only request waits for concurrency")
	assert(first:waitresponse(2000))
	first:close()
	local second<close> = testaux.await(done, "Test 25: request admitted after release")
	assert(second:waitresponse(2000))
	testaux.asserteq(ch.streamcount, 1, "Test 25.2: admission occupies one slot")
	second:close()
	ch:close()
end)

case("Test 26: HTTP/2 existing stream survives local channel close", function()
	local x = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end
	local conn, err = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 26.1: Connect should be ok")
	local ch, err = h2.newchannel("https", conn, "127.0.0.1:8082")
	testaux.assertneq(ch, nil, "Test 26.2: New channel should be ok")
	assert(ch)
	server_handler = x
	local s = ch:request("GET", "/", {})
	testaux.assertneq(s, nil, "Test 26.3: Openstream should be ok")
	ch:close()

	s:closewrite("foo")
	local body, err = s:readall()
	testaux.asserteq(body, "OK", "Test 26.4: Existing request completes after local close")
	s:close()
	testaux.asserteq(ch.conn, nil, "Test 26.4: Existing stream releases the closing transport")

	local s, err = ch:request("GET", "/", {})
	testaux.asserteq(s, nil, "Test 26.5: Openstream should fail")
	testaux.asserteq(err, "Graceful shutdown", "Test 26.5: Openstream should report completed local shutdown")
end)

case("Test 27: HTTP/2 streamcount accuracy with concurrent open/close", function()
	local x = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end

	local conn, err = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 27.1: Connect should succeed")
	local ch, err = h2.newchannel("https", conn, "127.0.0.1:8082")
	testaux.assertneq(ch, nil, "Test 27.2: New channel should succeed")
	assert(ch)

	local max = ch.streammax
	local streams = {}

	-- Step 1: Fill up to streammax
	for i = 1, max do
		server_handler = x
		local s = ch:request("GET", "/", {})
		testaux.assertneq(s, nil, "Test 27.3." .. i .. ": Should open stream " .. i)
		streams[i] = s

		s:closewrite()
		s:readall()
	end

	testaux.asserteq(ch.streamcount, max, "Test 27.4: streamcount should equal streammax")

	-- Step 2: Initial HEADERS for another stream should wait for a slot
	local started = channel.new()
	local blocked = false
	local opened_after_close = false
	local new_stream = nil
	local sync = channel.new()
	task.fork(function()
		blocked = true
		started:push(true)
		new_stream = assert(ch:request("GET", "/", {}))
		assert(new_stream:closewrite())
		opened_after_close = true
		sync:push("done")
	end)

	testaux.await(started, "initial HEADERS waiter started")
	testaux.asserteq(blocked, true, "Test 27.5: Initial HEADERS should wait when at max")
	testaux.asserteq(opened_after_close, false, "Test 27.6: Initial HEADERS should still be waiting")
	testaux.asserteq(ch.streamcount, max, "Test 27.7: streamcount should still be at max")
	-- Step 3: Close one stream to unblock the waiting coroutine
	server_handler = x
	streams[1]:close()
	sync:pop()
	testaux.asserteq(new_stream:readall(), "OK", "Test 27.8: Admitted request completes")

	testaux.asserteq(opened_after_close, true, "Test 27.8: Initial HEADERS should send after close")
	testaux.assertneq(new_stream, nil, "Test 27.9: new stream should be created")

	-- Critical check: streamcount should NOT exceed streammax
	testaux.asserteq(ch.streamcount, max, "Test 27.10: streamcount should not exceed streammax")

	-- Step 4: Close multiple streams and open multiple new ones
	local wg = waitgroup.new()
	local created_count = 0

	-- Close 5 streams
	for i = 2, 6 do
		streams[i]:close()
	end

	testaux.asserteq(ch.streamcount, max - 5, "Test 27.11: streamcount should decrease by 5")
	-- Try to open 5 new streams concurrently
	set_nil = false
	for i = 1, 5 do
		wg:fork(function()
			local s = ch:request("GET", "/", {})
			if s then
				server_handler = x
				created_count = created_count + 1

				s:closewrite()
				s:readall()
				s:close()
			end
		end)
	end

	wg:wait()
	set_nil = true
	testaux.asserteq(created_count, 5, "Test 27.12: Should create exactly 5 new streams")
	testaux.asserteq(ch.streamcount, max - 5, "Test 27.13: streamcount should be consistent after concurrent operations")

	-- Step 5: Verify streamcount never exceeded streammax during the test
	-- by trying to open streammax streams again
	for i = 7, max do
		streams[i]:close()
	end
	new_stream:close()

	testaux.asserteq(ch.streamcount, 0, "Test 27.14: All streams should be closed")

	-- Open streammax streams again
	set_nil = false
	local final_streams = {}
	for i = 1, max do
		server_handler = x
		local s, err = ch:request("GET", "/", {})
		testaux.assertneq(s, nil, "Test 27.15." .. i .. ": Should reopen stream " .. i)
		final_streams[i] = s
	end

	testaux.asserteq(ch.streamcount, max, "Test 27.16: Returned requests occupy stream slots")

	-- Cleanup - graceful close
	ch:close()
	testaux.assertneq(ch.conn, nil, "Test 27.17: Admitted requests retain the closing transport")

	-- Close all streams
	for i = 1, max do
		final_streams[i]:close()
	end

	readers[conn]:waitclosed()
	-- Now streamcount should be 0
	testaux.asserteq(ch.streamcount, 0, "Test 27.18: streamcount should be 0 after all streams closed")

	-- Verify the channel connection is closed
	testaux.asserteq(ch.conn, nil, "Test 27.19: channel connection should be closed after graceful close completes")
end)

-- Test 28: HPACK encoder state corruption from interleaved streams
-- Bug: When stream1 calls request() (hpack_pack adds headers to dynamic table),
-- then stream2 uses IDENTICAL headers (HPACK encodes as indexed reference),
-- if stream2 sends first, the server's decoder fails (dynamic table entry doesn't exist)
case("Test 28: HPACK encoder state corruption", function()
	set_nil = false
	server_handler = function(stream)
		-- Return received headers as JSON in body for verification
		local h = stream.header
		local body = json.encode({
			["x-shared-header"] = h["x-shared-header"],
			["x-common-value"] = h["x-common-value"],
		})
		stream:respond(200, {
			["content-type"] = "application/json",
		})
		stream:closewrite(body)
	end

	-- Use manual connection to ensure both streams are on the same connection
	local conn = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 28.1: Connect should succeed")
	local ch = h2.newchannel("https", conn, "127.0.0.1:8082")
	testaux.assertneq(ch, nil, "Test 28.2: New channel should succeed")

	-- Stream 1: Call request() with custom headers
	-- HPACK encoder adds these headers to its dynamic table (literal with indexing)
	local stream1 = ch:request("POST", "/stream1", {
		["x-shared-header"] = "identical-value-for-both-streams",
		["x-common-value"] = "this-is-shared-too",
	})
	testaux.assertneq(stream1, nil, "Test 28.3: Stream 1 should be created")

	-- The encoder's dynamic table now has these headers

	-- Stream 2: Call request() with IDENTICAL headers (same name AND value)
	-- HPACK encoder recognizes these are already in dynamic table
	-- It encodes them as indexed references (tiny 1-byte encoding)
	local stream2 = ch:request("POST", "/stream2", {
		["x-shared-header"] = "identical-value-for-both-streams",
		["x-common-value"] = "this-is-shared-too",
	})
	testaux.assertneq(stream2, nil, "Test 28.4: Stream 2 should be created")

	-- stream2's encoded headers contain indexed references to dynamic table entries
	-- But those entries were added by stream1 which hasn't been sent yet!
	-- When server decodes stream2, its dynamic table doesn't have these entries
	stream2:closewrite()

	-- Now send stream1 (contains literal encodings that add to decoder's table)
	stream1:closewrite()

	-- Try to read responses - stream2 should have failed to decode on server
	stream2:waitresponse()
	local body2 = stream2:readall()
	-- If bug exists: body2 will be nil (decode failed) or headers wrong
	-- If fixed: both streams decode correctly

	stream1:waitresponse()
	local body1 = stream1:readall()

	-- Check if we got valid responses
	local h1_received = body1 and json.decode(body1)
	local h2_received = body2 and json.decode(body2)

	-- Both streams should have received correct headers
	-- If HPACK state is corrupted, stream2 will fail or have wrong values
	testaux.assertneq(body1, nil, "Test 28.5: Stream 1 body should not be nil")
	testaux.assertneq(h1_received, nil, "Test 28.6: Stream 1 body should be valid JSON")
	testaux.assertneq(body2, nil, "Test 28.7: Stream 2 body should not be nil")
	testaux.assertneq(h2_received, nil, "Test 28.8: Stream 2 body should be valid JSON")

	-- Verify headers were received correctly
	testaux.asserteq(h1_received["x-shared-header"], "identical-value-for-both-streams",
		"Test 28.9: Stream 1 x-shared-header")
	testaux.asserteq(h1_received["x-common-value"], "this-is-shared-too",
		"Test 28.10: Stream 1 x-common-value")
	testaux.asserteq(h2_received["x-shared-header"], "identical-value-for-both-streams",
		"Test 28.11: Stream 2 x-shared-header")
	testaux.asserteq(h2_received["x-common-value"], "this-is-shared-too",
		"Test 28.12: Stream 2 x-common-value")

	stream1:close()
	stream2:close()
	ch:close()
	set_nil = true
end)

-- Test 29: Stream close before sending any data (IDLE state close)
-- Bug: If stream.request() sets localstate=STATE_HEADER, then close() would send RST_STREAM
-- even though no HEADERS frame was sent yet (stream is still IDLE).
-- According to HTTP/2 spec, sending RST_STREAM in IDLE state causes PROTOCOL_ERROR.
case("Test 29: Closing a returned request resets an already started stream", function()
	local ready, done = channel.new(), channel.new()
	server_handler = function(s)
		ready:push(true)
		local data, err = s:readall(2000)
		testaux.asserteq(data, nil, "Test 29.1: cancellation wakes the request reader")
		testaux.assertneq(err, nil, "Test 29.2: cancellation reports its reason")
		done:push(true)
	end
	local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
	local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
	local s = assert(ch:request("POST", "/", {}))
	testaux.await(ready, "Test 29: HEADERS reached the server")
	s:close()
	testaux.await(done, "Test 29: server observed the reset")
	testaux.asserteq(ch:isalive(), true, "Test 29.3: reset leaves the channel reusable")
	ch:close()
end)

case("Test 30: Explicit HTTP2 Host is sent and caller headers are preserved", function()
	local received_host, received_authority
	server_handler = function(stream)
		received_host = stream.header["host"]
		received_authority = stream.header[":authority"]
		stream:respond(200, { ["content-length"] = 2 })
		stream:write("OK")
	end

	local hdr = { ["host"] = "127.0.0.1:8082", ["x-test"] = "value" }
	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082/host-test", hdr)
	testaux.assertneq(stream, nil, "Test 30.1: request should succeed")
	stream:closewrite()
	local body = stream:readall()
	testaux.asserteq(body, "OK", "Test 30.2: body should be OK")

	-- user header table must not be modified
	testaux.asserteq(hdr["host"], "127.0.0.1:8082", "Test 30.3: user header[\"host\"] should be preserved")
	testaux.asserteq(hdr["x-test"], "value", "Test 30.4: user header[\"x-test\"] should be preserved")

	testaux.asserteq(received_host, "127.0.0.1:8082", "Test 30.5: explicit Host reaches the server")
	testaux.asserteq(received_authority, received_host, "Test 30.6: Host and authority identify the same target")

	wait_done()
end)

-- Redirect tests for HTTP/2

case("Test 31: h2 301 redirect changes POST to GET and drops body", function()
	set_nil = false
	local methods = {}
	server_handler = function(stream)
		methods[#methods + 1] = stream.method
		if stream.path == "/redirect" then
			stream:readall()
			stream:respond(301, { ["location"] = "/target" })
		else
			stream:respond(200, {
				["content-type"] = "text/plain",
			})
			stream:closewrite("OK")
		end
	end
	local response = httpc:post("https://127.0.0.1:8082/redirect", {
		["content-type"] = "text/plain"
	}, "request-body")
	testaux.assertneq(response, nil, "Test 31.1: redirect should succeed")
	testaux.asserteq(response.status, 200, "Test 31.2: final status should be 200")
	testaux.asserteq(response.body, "OK", "Test 31.3: body should be OK")
	testaux.asserteq(methods[1], "POST", "Test 31.4: first request should be POST")
	testaux.asserteq(methods[2], "GET", "Test 31.5: redirect should change method to GET")
end)

case("Test 32: h2 307 redirect preserves POST method and body", function()
	set_nil = false
	local target_method
	local target_body
	server_handler = function(stream)
		if stream.path == "/redirect" then
			stream:readall()
			stream:respond(307, { ["location"] = "/target" })
		else
			target_method = stream.method
			target_body = stream:readall()
			stream:respond(200, {
				["content-type"] = "text/plain",
			})
			stream:closewrite("OK")
		end
	end
	local response = httpc:post("https://127.0.0.1:8082/redirect", {
		["content-type"] = "text/plain"
	}, "preserved-body")
	testaux.assertneq(response, nil, "Test 32.1: redirect should succeed")
	testaux.asserteq(response.status, 200, "Test 32.2: final status should be 200")
	testaux.asserteq(target_method, "POST", "Test 32.3: method should be preserved as POST")
	testaux.asserteq(target_body, "preserved-body", "Test 32.4: body should be preserved")
end)

case("Test 33: h2 redirect loop detection", function()
	set_nil = false
	server_handler = function(stream)
		stream:respond(301, { ["location"] = "/loop" })
	end
	local response, err = httpc:get("https://127.0.0.1:8082/loop")
	testaux.asserteq(response, nil, "Test 33.1: loop should fail")
	testaux.assertneq(err, nil, "Test 33.2: should return error")
	testaux.assertneq(err:find("redirect loop"), nil, "Test 33.3: error should mention redirect loop")
end)

case("Test 34: h2 redirect with gzip response", function()
	local original_data = "Compressed h2 redirect data that should be long enough for gzip. " ..
		"Adding more text to improve compression ratio for this test."
	local compressed = gzip.compress(original_data)
	testaux.assertneq(compressed, nil, "Test 34.1: gzip.compress should succeed")
	set_nil = false
	server_handler = function(stream)
		if stream.path == "/redirect" then
			stream:respond(301, { ["location"] = "/target" })
		else
			stream:respond(200, {
				["content-type"] = "text/plain",
				["content-encoding"] = "gzip",
			})
			stream:closewrite(compressed)
		end
	end
	local response = httpc:get("https://127.0.0.1:8082/redirect")
	testaux.assertneq(response, nil, "Test 34.2: redirect with gzip should succeed")
	testaux.asserteq(response.status, 200, "Test 34.3: final status should be 200")
	testaux.asserteq(response.body, original_data, "Test 34.4: body should be decompressed")
end)

case("Test 35: h2 cross-host redirect resolves new authority", function()
	set_nil = false
	server_handler = function(stream)
		if stream.path == "/redirect" then
			stream:respond(301, { ["location"] = "https://localhost:8082/target" })
		else
			stream:respond(200, {
				["content-type"] = "text/plain",
			})
			stream:closewrite("host")
		end
	end
	local response = httpc:get("https://127.0.0.1:8082/redirect")
	testaux.assertneq(response, nil, "Test 35.1: cross-host redirect should succeed")
	testaux.asserteq(response.status, 200, "Test 35.2: final status should be 200")
	testaux.asserteq(response.body, "host", "Test 35.3: body should be host")
end)

case("Test 36: h2 redirect preserves query string in Location", function()
	set_nil = false
	local received_query
	server_handler = function(stream)
		if stream.path == "/redirect" then
			stream:respond(302, { ["location"] = "/target?foo=bar&baz=1" })
		else
			received_query = stream.query
			stream:respond(200, {
				["content-type"] = "text/plain",
			})
			stream:closewrite("OK")
		end
	end
	local response = httpc:get("https://127.0.0.1:8082/redirect?original=1")
	testaux.assertneq(response, nil, "Test 36.1: query redirect should succeed")
	testaux.asserteq(response.status, 200, "Test 36.2: final status should be 200")
	testaux.asserteq(received_query["foo"], "bar", "Test 36.3: target query foo should be present")
	testaux.asserteq(received_query["baz"], "1", "Test 36.4: target query baz should be present")
	testaux.asserteq(received_query["original"], nil, "Test 36.5: original query should not leak")
end)


-- Direct builder and buffered flow-control unit tests stay native.
-- Frame regressions (Test 39–108, 110–111, except Test 52/81) are in conformance/testhttp2.lua.
do
local builder = require "silly.http2.framebuilder"
local hpack = require "silly.http2.hpack"
local function frame(typ, flags, id, data)
	data = data or ""
	return string.pack(">I3I1I1I4", #data, typ, flags, id) .. data
end
local client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

testaux.case("Test 38: Header fragments use CONTINUATION", function()
	for _, size in ipairs({0, 16384, 16385, 32768, 40000}) do
		local payload = string.rep("x", size)
		local wire = builder.header(1, 16384, payload, true)
		local offset, count, chunks = 1, 0, {}
		while offset <= #wire do
			local len, typ, flags, id = string.unpack(">I3I1I1I4", wire, offset)
			count = count + 1
			testaux.asserteq(typ, count == 1 and 1 or 9, "fragment type")
			testaux.asserteq(id, 1, "fragment stream")
			testaux.asserteq(flags & 1, count == 1 and 1 or 0, "END_STREAM only on HEADERS")
			testaux.asserteq(flags & 4, offset + 9 + len > #wire and 4 or 0, "END_HEADERS only on last fragment")
			chunks[count] = wire:sub(offset + 9, offset + 8 + len)
			offset = offset + 9 + len
		end
		testaux.asserteq(table.concat(chunks), payload, "fragment payload")
	end
end)

for index, expanded in ipairs({false, true}) do
	local phase = expanded and "after" or "before"
	testaux.case("Test 52." .. index .. ": Connection receive boundary " .. phase .. " handshake expansion", function()
		local encoder = hpack.new(4096)
		local prefix = client_preface .. frame(4, 0, 0)
		if expanded then
			prefix = prefix .. frame(4, 1, 0)
		end
		local input = {prefix}
		local capacity = expanded and 4 * 1024 * 1024 or 65535
		local left, id = capacity, 1
		while left > 0 do
			input[#input + 1] = frame(1, 4, id, hpack.pack(encoder, {},
				":method", "POST", ":scheme", "http", ":path", "/", ":authority", "example.test"))
			local size = math.min(left, 65535)
			left = left - size
			while size > 0 do
				local n = math.min(size, 16384)
				input[#input + 1] = frame(0, 0, id, string.rep("x", n))
				size = size - n
			end
			if left > 0 then
				id = id + 2
			end
		end
		input[#input + 1] = frame(0, 0, id, "x")
		local wire = table.concat(input)
		local offset, closed, flushed = 1, false, false
		local output = {}
		-- Buffered reads keep refunds pending, so the boundary is independent of packet timing.
		local conn = {
			remoteaddr = "buffered HTTP/2 peer",
			read = function(_, n)
				if closed or offset > #wire then
					return nil, "EOF"
				end
				if expanded and not flushed and offset == #prefix + 1 then
					flushed = true
					local ready = channel.new()
					task.fork(function()
						ready:push(true)
					end)
					testaux.await(ready, "initial WINDOW_UPDATE was flushed before DATA")
				end
				local dat = wire:sub(offset, offset + n - 1)
				offset = offset + n
				return dat
			end,
			write = function(_, dat)
				output[#output + 1] = type(dat) == "table" and table.concat(dat) or dat
				return true
			end,
			close = function()
				closed = true
			end,
		}
		h2.httpd(function()
			error("buffered request handler should be aborted before it runs")
		end, conn, "http")
		local frames = table.concat(output)
		local pos, code = 1, nil
		while pos <= #frames do
			local len, typ = string.unpack(">I3I1", frames, pos)
			if typ == 7 then
				code = string.unpack(">I4", frames, pos + 13)
			end
			pos = pos + 9 + len
		end
		testaux.asserteq(offset, #wire + 1, "entire connection capacity is accepted before the excess byte")
		testaux.asserteq(code, 3, "excess byte causes connection FLOW_CONTROL_ERROR")
	end)
end

case("Test 81: TLS listener advertising only HTTP1 preserves https scheme", function()
	local done = channel.new()
	local listener = assert(http.listen {
		tls = true,
		addr = "127.0.0.1:18443",
		alpnprotos = {"http/1.1"},
		certs = {{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}},
		handler = function(stream)
			testaux.asserteq(stream.version, "1.1", "HTTP1-only ALPN selects HTTP1")
			testaux.asserteq(stream.scheme, "https", "HTTP1-only ALPN preserves the TLS scheme")
			stream:respond(200, {["x-scheme"] = stream.scheme})
			stream:closewrite("ok")
			done:push(true)
		end,
	})
	local client = http.newclient({alpnprotos = {"h2", "http/1.1"}})
	local response = assert(client:get("https://127.0.0.1:18443/"))
	testaux.asserteq(response.header["x-scheme"], "https", "HTTP1 handler receives listener scheme")
	testaux.asserteq(response.body, "ok", "HTTP1 response remains usable")
	testaux.await(done, "HTTP1 handler completed")
	client:close()
	listener:close()
end)


case("Test 110: Stream close immediately releases its channel references", function()
	local ready, done = channel.new(), channel.new()
	server_handler = function(s)
		ready:push(true)
		local data = s:readall(2000)
		testaux.asserteq(data, nil, "Test 110.1: cancelled request wakes the server reader")
		done:push(true)
	end
	local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
	local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
	local s<close> = assert(ch:request("POST", "/released", {}))

	s:flush()
	testaux.await(ready, "server received the open request")
	s:close()
	testaux.asserteq(ch.streams[s.id], nil, "Test 110.2: close removes the stream mapping immediately")
	testaux.asserteq(s.closed, true, "Test 110.3: close marks the stream released immediately")
	testaux.asserteq(ch.streamcount, 0, "Test 110.4: close releases the admission slot")
	ch:close()
	-- No yield: final cleanup must not depend on the dispatch task observing transport closure.
	testaux.asserteq(ch.conn, nil, "Test 110.5: last stream releases the transport")
	testaux.asserteq(next(ch.streams), nil, "Test 110.6: final close leaves no stream mappings")
	testaux.asserteq(s.channel, ch, "Test 110.7: released streams retain their channel ownership")
	testaux.asserteq(ch.sendwaitq:size(), 0, "Test 110.8: final close releases the writer queue")
	ch:close()
	s:close()
	testaux.await(done, "server reader finished after cancellation")
end)


case("Test 111: Abort preserves a completed request while failing the response writer", function()
	for _, mode in ipairs({"read", "readall"}) do
		local input, ready, received, written, done = channel.new(), channel.new(), channel.new(), channel.new(), channel.new()
		local wire = client_preface .. frame(4, 0, 0, string.pack(">I2I4", 4, 0)) .. frame(4, 1, 0)
			.. frame(1, 4, 1, hpack.pack(hpack.new(4096), {},
				":method", "POST", ":scheme", "http", ":path", "/", ":authority", "example.test"))
		local offset, closed = 1, false
		local conn = {
			remoteaddr = "buffered HTTP/2 peer",
			read = function(_, n)
				if closed then
					return nil, errno.CLOSED
				end
				if offset > #wire then
					wire = testaux.await(input, "Test 111: next buffered frame batch")
					offset = 1
				end
				local dat = wire:sub(offset, offset + n - 1)
				offset = offset + n
				assert(#dat == n)
				return dat
			end,
			write = function() return true end,
			close = function() closed = true end,
		}
		task.fork(function()
			h2.httpd(function(s)
				assert(s:respond(200, {}))
				task.fork(function()
					local data, err
					if mode == "read" then data, err = s:read(9, 2000) else data, err = s:readall(2000) end
					received:push({data = data, err = err})
				end)
				task.fork(function() ready:push(true) end)
				local ok, err = s:closewrite("blocked")
				local body, cause = s:readall(2000)
				written:push({ok = ok, err = err, body = body, cause = cause, headers = s:waitresponse(2000)})
			end, conn, "http")
			done:push(true)
		end)
		testaux.await(ready, "Test 111: reader and flow-control writer are waiting")
		-- Buffered parsing processes END and abort before either queued waiter resumes.
		input:push(frame(0, 1, 1, "short") .. frame(6, 0, 1, "bad-ping"))
		local response = testaux.await(written, "Test 111: blocked response writer resumed")
		testaux.asserteq(response.ok, false, "Test 111.1: unfinished response writer fails")
		testaux.asserteq(response.err, "Protocol error detected", "Test 111.2: writer gets abort reason")
		local request = testaux.await(received, "Test 111: request reader resumed")
		testaux.asserteq(request.data, mode == "readall" and "short" or nil, "Test 111.3: queued read retains its completed result")
		testaux.asserteq(request.err, mode == "read" and EEOF or nil,
			"Test 111.4: receive EOF is independent of write failure")
		testaux.asserteq(response.body, mode == "read" and "short" or "", "Test 111.5: remaining completed request stays readable")
		testaux.asserteq(response.cause, nil, "Test 111.6: readall does not inherit write error")
		testaux.asserteq(response.headers, true, "Test 111.7: completed request headers remain available")
		testaux.await(done, "Test 111: dispatcher finished")
		testaux.asserteq(closed, true, "Test 111.8: abort closes the connection")
	end
end)


end

case("Test 112: Queued header conversion errors return to the requester", function()
	for _, trigger in ipairs({"close", "settings", "graceful"}) do
		local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
		local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
		local ready, done = channel.new(), channel.new()
		local peer
		server_handler = function(s)
			peer = s.channel
			assert(s:respond(200, {}, true))
		end
		local first = assert(ch:request("GET", "/first", {}, true))
		assert(first:waitresponse(2000))
		wait_done()
		ch.streammax = 1
		if trigger == "settings" then
			first:close()
			ch.streammax = 0
		end
		local bad = setmetatable({}, {__tostring = function()
			error("queued header conversion failed")
		end})
		task.fork(function()
			ready:push(true)
			local ok, err = pcall(ch.request, ch, "GET", "/invalid", {["x-poison"] = {"good", bad}}, true)
			done:push({ok = ok, err = err})
		end)
		testaux.await(ready, "Test 112: invalid request is queued")
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 112.1: request waits for admission")
		if trigger == "settings" then
			-- Raising the peer limit opens admission in the protocol reader.
			assert(peer.conn:write(require("silly.http2.framebuilder").setting(0, 3, 1)))
		elseif trigger == "graceful" then
			ch:close()
			first:close()
		else
			local ok, err = pcall(first.close, first)
			testaux.asserteq(ok, true, "Test 112.2: conversion does not escape through another stream close: " .. tostring(err))
		end
		local result = testaux.await(done, "Test 112: requester receives its conversion error")
		testaux.asserteq(result.ok, false, "Test 112.3: request rethrows the conversion error")
		testaux.assertneq(result.err:find("queued header conversion failed", 1, true), nil,
			"Test 112.4: original conversion error is preserved")
		if trigger == "graceful" then
			testaux.asserteq(ch.conn, nil, "Test 112.5: the final failed admission completes graceful close")
		else
			server_handler = function(s)
				testaux.asserteq(s.path, "/valid", "Test 112.6: rejected request emits no headers")
				testaux.asserteq(s.header["x-poison"], "good", "Test 112.7: HPACK stays synchronized")
				assert(s:respond(200, {}, true))
			end
			local stream<close> = assert(ch:request("GET", "/valid", {["x-poison"] = "good"}, true))
			assert(stream:waitresponse(2000))
			wait_done()
		end
		ch:close()
	end
end)

case("Test 113: Endstream rejects a nonzero request length before encoding headers", function()
	for _, length in ipairs({1, "1", {"0", "1"}}) do
		local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
		local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
		local stream, err = ch:request("POST", "/invalid", {
			["content-length"] = length,
			["x-reused"] = "must not enter the HPACK table",
		}, true)
		testaux.asserteq(stream, nil, "Test 113.1: contradictory headers return no stream")
		testaux.assertneq(err, nil, "Test 113.2: contradictory headers report an error")
		testaux.asserteq(ch.streamidx, -1, "Test 113.3: rejection consumes no stream ID")
		testaux.asserteq(ch.streamcount, 0, "Test 113.4: rejection consumes no stream slot")
		server_handler = function(s)
			testaux.asserteq(s.path, "/valid", "Test 113.5: only the valid request reaches the server")
			testaux.asserteq(s.header["x-reused"], "must not enter the HPACK table",
				"Test 113.6: rejected headers leave HPACK synchronized")
			assert(s:respond(200, {}, true))
		end
		local valid<close> = assert(ch:request("POST", "/valid", {
			["content-length"] = "0",
			["x-reused"] = "must not enter the HPACK table",
		}, true))
		testaux.asserteq(valid.id, 1, "Test 113.7: the valid request uses the first stream ID")
		assert(valid:waitresponse(2000))
		wait_done()
		ch:close()
	end
end)

case("Test 114: Queued endstream validation returns an error without consuming a slot", function()
	local conn = assert(tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}}))
	local ch = assert(h2.newchannel("https", conn, "127.0.0.1:8082"))
	server_handler = function(s)
		assert(s:respond(200, {}, true))
	end
	local first = assert(ch:request("GET", "/first", {}, true))
	assert(first:waitresponse(2000))
	wait_done()
	ch.streammax = 1
	local ready, done = channel.new(), channel.new()
	task.fork(function()
		ready:push(true)
		local stream, err = ch:request("POST", "/invalid", {["content-length"] = "1"}, true)
		done:push({stream = stream, err = err})
	end)
	testaux.await(ready, "Test 114: invalid request starts admission")
	first:close()
	local result = testaux.await(done, "Test 114: invalid request returns")
	testaux.asserteq(result.stream, nil, "Test 114.1: queued invalid request returns no stream")
	testaux.assertneq(result.err, nil, "Test 114.2: queued invalid request preserves its error")
	testaux.asserteq(ch.streamidx, 1, "Test 114.3: queued rejection consumes no ID")
	testaux.asserteq(ch.streamcount, 0, "Test 114.4: queued rejection consumes no slot")
	ch:close()
end)

-- Check h1 pool (should be empty since we only use h2)
for key, entries in pairs(httpc.h1pool) do
	testaux.asserteq(#entries, 0, "h1pool[" .. key .. "] should be empty")
end

-- Check h2 pool
for key, entries in pairs(httpc.h2pool) do
	for i, entry in ipairs(entries) do
		local channel = entry.channel
		testaux.asserteq(next(channel.streams), nil, "h2pool[" .. key .. "][" .. i .. "] all streams should be closed")
		channel:close()
	end
end

httpc:close()
if server then
	server:close()
end
wait_readers()

print("All tests completed!")
