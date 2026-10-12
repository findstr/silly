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
local readers, wait_readers = testaux.track_connections(tls)

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
	if server_handler then testaux.await(handler_done, "server handler completed") end
	handler_done:clear()
end

local function case(name, fn)
	testaux.case(name, function()
		handler_done:clear()
		local ok, err = pcall(fn)
		server_handler = nil
		set_nil = true
		if not ok then error(err) end
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
	readers[stream.channel.conn]:wait_until(function()
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
		-- Close connection without finishing
		stream.channel:close()
	end

	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082", {})
	testaux.assertneq(stream, nil, "Test 20.1: stream should not be nil")
	stream:closewrite()
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, nil, "Test 20.2: Should fail to read")
	testaux.asserteq(err, "Channel goaway", "Test 20.3: Should have error")

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

case("Test 25: HTTP/2 cocurrent stream stream", function()
	local x = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end
	local conn, err = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 25.1: Connect should be ok")
	local ch, err = h2.newchannel("https", conn)
	testaux.assertneq(ch, nil, "Test 25.2: New channel should be ok")
	assert(ch)
	local max = ch.streammax
	local streams = {}
	for i = 1, max do
		server_handler = x
		local s = ch:openstream()
		testaux.assertneq(s, nil, "Test 25.3: Openstream should be ok")
		local ok, err = s:request("GET", "/", {})
		testaux.asserteq(ok, true, "Test 25.4: Request should be ok")
		testaux.asserteq(err, nil, "Test 25.4: Request should be ok")
		s:closewrite("foo")
		local body, err = s:readall()
		testaux.asserteq(body, "OK", "Test 25.4: Request should be ok")
		streams[i] = s
	end
	local block = false
	task.fork(function()
		block = true
		streams[1]:close()
	end)
	local s = ch:openstream()
	testaux.asserteq(block, true, "Test 25.5: Openstream should be block")
	testaux.assertneq(s, nil, "Test 25.5: Openstream should be success")

	local wg = waitgroup.new()
	for i = 1, 100 do
		wg:fork(function()
			local s, err = ch:openstream()
			testaux.asserteq(s, nil, "Test 25.6: Openstream should fail")
			testaux.asserteq(err, "channel closed", "Test 25.6: Openstream should fail")
		end)
	end
	wg:fork(function()
		ch:close()
	end)
	wg:wait()
	-- Close all remaining streams to avoid leaks
	for i = 2, max do
		streams[i]:close()
	end
	s:close()
end)

case("Test 26: HTTP/2 opensream on a closed channel", function()
	local x = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:closewrite("OK")
	end
	local conn, err = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 26.1: Connect should be ok")
	local ch, err = h2.newchannel("https", conn)
	testaux.assertneq(ch, nil, "Test 26.2: New channel should be ok")
	assert(ch)
	server_handler = x
	local s = ch:openstream()
	testaux.assertneq(s, nil, "Test 26.3: Openstream should be ok")
	ch:close()
	s:request("GET", "/", {})
	s:closewrite("foo")
	local body, err = s:readall()
	testaux.asserteq(body, nil, "Test 26.4: Request should fail")
	testaux.asserteq(err, "Channel goaway", "Test 26.4: Request should fail")

	local s, err = ch:openstream()
	testaux.asserteq(s, nil, "Test 26.5: Openstream should fail")
	testaux.asserteq(err, "Channel goaway", "Test 26.5: Openstream should fail")
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
	local ch, err = h2.newchannel("https", conn)
	testaux.assertneq(ch, nil, "Test 27.2: New channel should succeed")
	assert(ch)

	local max = ch.streammax
	local streams = {}

	-- Step 1: Fill up to streammax
	for i = 1, max do
		server_handler = x
		local s = ch:openstream()
		testaux.assertneq(s, nil, "Test 27.3." .. i .. ": Should open stream " .. i)
		streams[i] = s
		s:request("GET", "/", {})
		s:closewrite()
		s:readall()
	end

	testaux.asserteq(ch.streamcount, max, "Test 27.4: streamcount should equal streammax")

	-- Step 2: Try to open one more stream (should block)
	local started = channel.new()
	local blocked = false
	local opened_after_close = false
	local new_stream = nil
	local sync = channel.new()
	task.fork(function()
		blocked = true
		started:push(true)
		new_stream = ch:openstream()
		opened_after_close = true
		sync:push("done")
	end)

	testaux.await(started, "openstream waiter started")
	testaux.asserteq(blocked, true, "Test 27.5: openstream should be blocked when at max")
	testaux.asserteq(opened_after_close, false, "Test 27.6: openstream should still be waiting")
	testaux.asserteq(ch.streamcount, max, "Test 27.7: streamcount should still be at max")
	-- Step 3: Close one stream to unblock the waiting coroutine
	streams[1]:close()
	sync:pop()

	testaux.asserteq(opened_after_close, true, "Test 27.8: openstream should complete after close")
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
			local s = ch:openstream()
			if s then
				server_handler = x
				created_count = created_count + 1
				s:request("GET", "/", {})
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
	local final_streams = {}
	for i = 1, max do
		server_handler = x
		local s, err = ch:openstream()
		testaux.assertneq(s, nil, "Test 27.15." .. i .. ": Should reopen stream " .. i)
		final_streams[i] = s
	end

	testaux.asserteq(ch.streamcount, max, "Test 27.16: streamcount should equal streammax again")

	-- Cleanup - graceful close
	ch:close()
	readers[conn]:wait_closed()
	-- These reservations never sent HEADERS. Once GOAWAY reaches the peer,
	-- it closes its idle connection and the reservations are released.
	testaux.asserteq(ch.streamcount, 0, "Test 27.17: unused reservations released after peer closes")

	-- Close all streams
	for i = 1, max do
		final_streams[i]:close()
	end

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
	local ch = h2.newchannel("https", conn)
	testaux.assertneq(ch, nil, "Test 28.2: New channel should succeed")

	-- Stream 1: Call request() with custom headers
	-- HPACK encoder adds these headers to its dynamic table (literal with indexing)
	local stream1 = ch:openstream()
	testaux.assertneq(stream1, nil, "Test 28.3: Stream 1 should be created")
	stream1:request("POST", "/stream1", {
		["x-shared-header"] = "identical-value-for-both-streams",
		["x-common-value"] = "this-is-shared-too",
	})
	-- stream1 headers are hpack_pack'd but NOT sent yet!
	-- The encoder's dynamic table now has these headers

	-- Stream 2: Call request() with IDENTICAL headers (same name AND value)
	-- HPACK encoder recognizes these are already in dynamic table
	-- It encodes them as indexed references (tiny 1-byte encoding)
	local stream2 = ch:openstream()
	testaux.assertneq(stream2, nil, "Test 28.4: Stream 2 should be created")
	stream2:request("POST", "/stream2", {
		["x-shared-header"] = "identical-value-for-both-streams",
		["x-common-value"] = "this-is-shared-too",
	})

	-- Send stream2 FIRST - BUG TRIGGER!
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
case("Test 29: Stream close in IDLE state (no data sent)", function()
	set_nil = false
	local sync_ch = channel.new()
	local call_count = 0
	server_handler = function(stream)
		call_count = call_count + 1
		sync_ch:push(call_count)
		stream:respond(200, {})
		stream:closewrite("OK")
	end

	local conn = tls.connect("127.0.0.1:8082", {alpnprotos = {"h2"}})
	testaux.assertneq(conn, nil, "Test 29.1: Connect should succeed")
	local ch = h2.newchannel("https", conn)
	testaux.assertneq(ch, nil, "Test 29.2: New channel should succeed")

	-- Scenario 1: openstream → close (no request at all)
	local s1 = ch:openstream()
	testaux.assertneq(s1, nil, "Test 29.3: Stream 1 should be created")
	s1:close()
	-- No sync needed - if server is wrongly called, call_count will be wrong

	-- Scenario 2: openstream → request → close (request called but no data sent)
	-- This is the KEY scenario that the bug fix addresses
	local s2 = ch:openstream()
	testaux.assertneq(s2, nil, "Test 29.5: Stream 2 should be created")
	local ok, err = s2:request("GET", "/test", {
		["x-test-header"] = "test-value"
	})
	testaux.asserteq(ok, true, "Test 29.6: request should succeed")
	testaux.asserteq(err, nil, "Test 29.7: request should not return error")

	-- Close immediately without calling write/closewrite
	-- BUG (before fix): Would send RST_STREAM because localstate=STATE_HEADER
	-- FIX: Should NOT send RST_STREAM because writeheader is not nil (headers not sent yet)
	s2:close()
	-- No sync needed - if server is wrongly called, call_count will be wrong

	-- Verify no server calls happened yet
	testaux.asserteq(call_count, 0, "Test 29.8: Server should not be called for stream1 and stream2")

	-- Verify channel is still healthy (no PROTOCOL_ERROR)
	-- If RST_STREAM was incorrectly sent in IDLE state, the connection might be closed
	testaux.assertneq(ch.conn, nil, "Test 29.9: Channel connection should still be alive")
	testaux.asserteq(ch.goaway, false, "Test 29.10: Channel should not have received GOAWAY")

	-- Scenario 3: openstream → request → write → close (should send RST_STREAM)
	-- This is the normal case - stream has sent HEADERS, so RST_STREAM is valid
	local s3 = ch:openstream()
	testaux.assertneq(s3, nil, "Test 29.11: Stream 3 should be created")
	s3:request("POST", "/test", {})
	s3:write("some data") -- This sends HEADERS + DATA

	-- Wait for server to be called (blocking wait)
	local count = sync_ch:pop()
	testaux.asserteq(count, 1, "Test 29.12: Server should be called exactly once for stream3")

	s3:close() -- Should send RST_STREAM (stream has left IDLE state)

	ch:close()
	set_nil = true
end)

case("Test 30: Host header not duplicated and user header preserved", function()
	local received_host
	server_handler = function(stream)
		received_host = stream.header["host"]
		stream:respond(200, { ["content-length"] = 2 })
		stream:write("OK")
	end

	local hdr = { ["host"] = "my-custom-host", ["x-test"] = "value" }
	local stream<close>, err = httpc:request("GET", "https://127.0.0.1:8082/host-test", hdr)
	testaux.assertneq(stream, nil, "Test 30.1: request should succeed")
	stream:closewrite()
	local body = stream:readall()
	testaux.asserteq(body, "OK", "Test 30.2: body should be OK")

	-- user header table must not be modified
	testaux.asserteq(hdr["host"], "my-custom-host", "Test 30.3: user header[\"host\"] should be preserved")
	testaux.asserteq(hdr["x-test"], "value", "Test 30.4: user header[\"x-test\"] should be preserved")

	-- server should NOT see host (h2 uses :authority pseudo-header)
	testaux.asserteq(received_host, nil, "Test 30.5: server should not receive host header in h2")

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

-- Frame-level regression tests use independent wire frames and public APIs.
do
local builder = require "silly.http2.framebuilder"
local hpack = require "silly.http2.hpack"
testaux.case("Header fragments use CONTINUATION", function()
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

local peer = (function()
-- A raw HTTP/2 peer for testing public channel APIs against independent wire frames.
local task = require "silly.task"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local h2 = require "silly.net.http.h2"
local hpack = require "silly.http2.hpack"
local testaux = require "test.testaux"

local M = {}
local port = 18082
local function nextaddr()
	port = port + 1
	return "127.0.0.1:" .. port
end
M.preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

function M.frame(typ, flags, id, data)
	data = data or ""
	return string.pack(">I3I1I1I4", #data, typ, flags, id) .. data
end

function M.read(conn, timeout)
	local hdr, err = conn:read(9, timeout or 2000)
	if not hdr then return nil, err end
	local len, typ, flags, id = string.unpack(">I3I1I1I4", hdr)
	local data = ""
	if len > 0 then data, err = conn:read(len, timeout or 2000) end
	if not data then return nil, err end
	return {type = typ, flags = flags, id = id & 0x7fffffff, data = data, length = len}
end

function M.untilframe(conn, typ)
	for _ = 1, 100 do
		local frame, err = M.read(conn)
		assert(frame, tostring(err))
		if frame.type == typ then return frame end
	end
	error("expected frame " .. typ)
end

function M.server_handshake(conn, settings)
	assert(conn:read(#M.preface, 2000) == M.preface)
	assert(M.read(conn).type == 4)
	assert(conn:write(M.frame(4, 0, 0, settings) .. M.frame(4, 1, 0)))
	M.untilframe(conn, 4)
end

function M.client_handshake(conn)
	assert(conn:write(M.preface .. M.frame(4, 0, 0)))
	assert(M.read(conn).type == 4)
	assert(conn:write(M.frame(4, 1, 0)))
	M.untilframe(conn, 4)
end

function M.headers(encoder, id, status, fields, flags)
	return M.frame(1, flags or 5, id, hpack.pack(encoder, fields or {}, ":status", status))
end

function M.with_client(peer, body, opts)
	local addr = nextaddr()
	local peererr, accepted
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			accepted = conn
			local ok, err = pcall(peer, conn)
			if not ok then peererr = err end
			conn:close()
			done:push(true)
		end,
	})
	local conn = assert(tcp.connect(addr))
	local watchdog = time.after(5000, function() conn:close(); if accepted then accepted:close() end end)
	local observer = testaux.observe_reads(conn)
	local ch
	local ok, err = pcall(function()
		local channel, cause = h2.newchannel("http", conn, "example.test", opts)
		ch = channel
		body(channel, cause, observer)
	end)
	if ok then testaux.await(done, "peer consumed buffered writes") end
	conn:close()
	if accepted then accepted:close() end
	if not ok then testaux.await(done, "raw peer completed") end
	if ch then observer:wait_closed() end
	listener:close()
	time.cancel(watchdog)
	if not ok then error(err, 0) end
	if peererr then error(peererr, 0) end
end

function M.with_server(handler, body, opts)
	local addr = nextaddr()
	local servererr, accepted
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			accepted = conn
			local ok, err = pcall(h2.httpd, handler, conn, opts)
			if not ok then servererr = err end
			conn:close()
			done:push(true)
		end,
	})
	local conn = assert(tcp.connect(addr))
	local watchdog = time.after(5000, function() conn:close(); if accepted then accepted:close() end end)
	local ok, err = pcall(body, conn)
	conn:close()
	if accepted then accepted:close() end
	testaux.await(done, "h2 server completed")
	listener:close()
	time.cancel(watchdog)
	if not ok then error(err, 0) end
	if servererr then error(servererr, 0) end
end

return M

end)()
local frame = peer.frame
local function get(ch)
	local s = assert(ch:openstream())
	assert(s:request("GET", "/", {}))
	assert(s:closewrite())
	return s
end

local function answer(conn, text)
	local request = peer.untilframe(conn, 1)
	assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 1, request.id, text)))
	return request
end

testaux.case("PING ignores unknown flags and echoes payload", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		assert(conn:write(frame(6, 8, 0, "12345678")))
		local reply, request
		while not reply or not request do
			local incoming = assert(peer.read(conn))
			if incoming.type == 6 then reply = incoming end
			if incoming.type == 1 then request = incoming end
		end
		testaux.asserteq(reply.flags, 1, "PING ACK")
		testaux.asserteq(reply.data, "12345678", "opaque payload echoed")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 1, request.id, "ok")))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "ok", "request survives unknown PING flag")
	end)
end)

testaux.case("Graceful client close sends GOAWAY before EOF", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local reply = peer.untilframe(conn, 7)
		local last, code = string.unpack(">I4I4", reply.data)
		testaux.asserteq(last, 0, "client processed no peer-initiated streams")
		testaux.asserteq(code, 0, "graceful GOAWAY")
	end, function(ch)
		assert(ch):close()
	end)
end)

testaux.case("EOF wakes blocked openstream", function()
	local closepeer = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn, string.pack(">I2I4", 3, 1))
		testaux.await(closepeer, "client filled stream slot")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local _, err = ch:openstream()
			done:push({cause = err})
		end)
		testaux.await(started, "openstream waiter started")
		closepeer:push(true)
		local cause = testaux.await(done, "openstream wakes on EOF").cause
		testaux.assertneq(cause, nil, "openstream returns connection error")
	end)
end)

testaux.case("GOAWAY stops reuse and refuses unprocessed streams", function()
	local release = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, 0))))
		testaux.await(release, "GOAWAY assertions completed")
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(1000)
		testaux.asserteq(ch:isalive(), false, "GOAWAY channel is not reusable")
		testaux.asserteq(ok, false, "unprocessed stream fails promptly")
		testaux.assertneq(err, nil, "GOAWAY cause returned")
		local nextstream, cause = ch:openstream()
		testaux.asserteq(nextstream, nil, "no streams after GOAWAY")
		testaux.assertneq(cause, nil, "openstream has error")
		release:push(true)
	end)
end)

testaux.case("Malformed GOAWAY length is a connection error", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		assert(conn:write(frame(7, 0, 0, "short")))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 6, "FRAME_SIZE_ERROR")
	end, function(ch, err, observer) observer:wait_closed() end)
end)

testaux.case("SETTINGS shrink changes encoder, not decoder", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local encoder = hpack.new(4096)
		local first = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, first.id, "200", {["x-cache"] = "retained"})))
		local second = peer.untilframe(conn, 1)
		-- A static-only block resets the decoder's eviction cursor.
		assert(conn:write(peer.headers(encoder, second.id, "204")))
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 1, 0))))
		peer.untilframe(conn, 4)
		local third = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, third.id, "200", {["x-cache"] = "retained"})))
	end, function(ch)
		for i = 1, 3 do
			local s<close> = get(assert(ch))
			testaux.asserteq(s:waitresponse(2000), true, "response after peer shrinks its decoder")
			if i ~= 2 then testaux.asserteq(s.header["x-cache"], "retained", "incoming dynamic table unchanged") end
		end
	end)
end)

testaux.case("Informational response precedes final response", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(peer.headers(encoder, request.id, "103", {["link"] = "</style.css>"}, 4)))
		assert(conn:write(peer.headers(encoder, request.id, "200", {["x-final"] = "yes"}, 4) .. frame(0, 1, request.id, "ok")))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:waitresponse(2000), true, "final response received")
		testaux.asserteq(s.status, 200, "final status replaces information response")
		testaux.asserteq(s.header["x-final"], "yes", "final response headers")
		testaux.asserteq(s.header.link, nil, "information headers do not leak into final response")
		testaux.asserteq(s:readall(2000), "ok", "final body")
	end)
end)

testaux.case("Initial SETTINGS ACK is rejected", function()
	peer.with_client(function(conn)
		assert(conn:read(#peer.preface, 2000) == peer.preface)
		peer.untilframe(conn, 4)
		assert(conn:write(frame(4, 1, 0) .. frame(4, 1, 0)))
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "invalid handshake closes connection")
	end, function(ch, err)
		testaux.asserteq(ch, nil, "ACK is not a valid preface")
		testaux.assertneq(err, nil, "invalid preface error")
	end)
end)

testaux.case("SETTINGS reduction permits negative send windows", function()
	local lowered, started = channel.new(), channel.new()
	local completed = false
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 0)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
		peer.untilframe(conn, 4)
		lowered:push(true)
		testaux.await(started, "writer entered closewrite")
		testaux.asserteq(completed, false, "write blocks while stream window is negative")
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 2))))
		local body = peer.untilframe(conn, 0)
		testaux.asserteq(body.data, "b", "write resumes after window credit")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		assert(s:write("a"))
		testaux.await(lowered, "SETTINGS reduced window")
		testaux.asserteq(s.sendwindow, -1, "SETTINGS reduction makes send window negative")
		started:push(true)
		assert(s:closewrite("b"))
		completed = true
	end)
end)

testaux.case("Padding is restored to both receive windows", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		assert(conn:write(frame(0, 8, request.id, "\x03a\0\0\0")))
		local connection, stream = 0, 0
		while connection < 5 or stream < 5 do
			local update = peer.untilframe(conn, 8)
			local n = string.unpack(">I4", update.data)
			if update.id == 0 then connection = connection + n else stream = stream + n end
		end
		assert(conn:write(frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:read(1, 2000), "a", "padding excluded from body")
		testaux.asserteq(s:readall(2000), "", "padded stream finishes")
	end)
end)

testaux.case("Receive stream window overflow resets only offending stream", function()
	local reset_seen = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		assert(conn:write(string.rep(frame(0, 0, request.id, string.rep("x", 16384)), 5)))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 3, "FLOW_CONTROL_ERROR")
		reset_seen:push(true)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		assert(s:waitresponse(2000))
		testaux.await(reset_seen, "peer received stream reset")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "other streams survive receive overflow")
	end)
end)

testaux.case("Invalid content length does not consume server slots", function()
	peer.with_server(function(s) s:respond(200, {}); s:closewrite("ok") end, function(conn)
		peer.client_handshake(conn)
		local encoder = hpack.new(4096)
		for id = 1, 199, 2 do
			local data = hpack.pack(encoder, {["content-length"] = "invalid"}, ":method", "GET", ":scheme", "http", ":path", "/")
			assert(conn:write(frame(1, 5, id, data)))
			peer.untilframe(conn, 3)
		end
		local data = hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/")
		assert(conn:write(frame(1, 5, 201, data)))
		local reply = peer.untilframe(conn, 1)
		testaux.asserteq(reply.id, 201, "valid request still admitted")
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "response after malformed requests")
	end)
end)

testaux.case("Content length mismatch does not kill unrelated stream", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {["content-length"] = "1"})))
		peer.untilframe(conn, 3)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		local body, err = s:readall(2000)
		testaux.asserteq(body, nil, "malformed response rejected")
		testaux.assertneq(err, nil, "content length mismatch error")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "connection survives malformed response")
	end)
end)

testaux.case("Server handler failure resets its stream and releases slots", function()
	peer.with_server(function(s)
		if s.path == "/fail" then error("intentional handler failure") end
		s:respond(200, {}); s:closewrite("ok")
	end, function(conn)
		peer.client_handshake(conn)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/fail"))))
		peer.untilframe(conn, 3)
		assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "next request survives handler error")
	end)
end)

testaux.case("Client keepalive probes without streams and matches ACK", function()
	local probes_done = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		for _ = 1, 2 do
			local ping = peer.untilframe(conn, 6)
			testaux.asserteq(ping.id, 0, "connection PING")
			testaux.asserteq(#ping.data, 8, "eight-byte token")
			assert(conn:write(frame(6, 1, 0, ping.data)))
		end
		probes_done:push(true)
		answer(conn, "ok")
	end, function(ch)
		testaux.await(probes_done, "two idle probes acknowledged")
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "ok", "channel survives ACKs while idle")
	end, {read_idle_timeout = 30, ping_timeout = 300})
end)

testaux.case("Client PING timeout wakes readers and openstream waiters", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 6)
		testaux.asserteq(peer.read(conn), nil, "client closes on PING timeout")
	end, function(ch)
		local s<close> = get(assert(ch))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local _, err = ch:openstream()
			done:push({cause = err})
		end)
		testaux.await(started, "openstream waiter started before PING timeout")
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "reader fails on PING timeout")
		testaux.asserteq(err, "PING timeout", "specific timeout cause")
		local cause = testaux.await(done, "openstream wakes on PING timeout").cause
		testaux.asserteq(cause, "PING timeout", "openstream timeout cause")
	end, {read_idle_timeout = 30, ping_timeout = 50})
end)

testaux.case("Wrong ACK and other frames do not complete a pending PING", function()
	local probe_seen, send_frames, processed = channel.new(), channel.new(), channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local ping = peer.untilframe(conn, 6)
		probe_seen:push(ping.data)
		testaux.await(send_frames, "pending probe captured")
		assert(conn:write(frame(6, 1, 0, "wrongACK") .. frame(0xfe, 0, 0) .. frame(6, 0, 0, "activity")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq(ack.data, "activity", "PING barrier follows wrong ACK and other frame")
		processed:push(true)
		testaux.asserteq(peer.read(conn), nil, "peer observes PING timeout EOF")
	end, function(ch, err, observer)
		local token = testaux.await(probe_seen, "peer received pending probe")
		send_frames:push(true)
		testaux.await(processed, "wrong ACK and other frame processed")
		testaux.asserteq(assert(ch).pingtoken, token, "unrelated frames leave probe pending")
		observer:wait_closed()
		testaux.asserteq(ch:isalive(), false, "wrong ACK cannot complete probe")
		testaux.asserteq(ch.errstr, "PING timeout", "pending probe fails before peer closes")
	end, {read_idle_timeout = 30, ping_timeout = 300})
end)

testaux.case("Server keepalive probes idle connections", function()
	peer.with_server(function() end, function(conn)
		peer.client_handshake(conn)
		for _ = 1, 2 do
			local ping = peer.untilframe(conn, 6)
			assert(conn:write(frame(6, 1, 0, ping.data)))
		end
	end, {read_idle_timeout = 30, ping_timeout = 200})
end)

testaux.case("Server PING timeout closes idle connections", function()
	peer.with_server(function() end, function(conn)
		peer.client_handshake(conn)
		peer.untilframe(conn, 6)
		local nextframe = peer.read(conn, 1000)
		testaux.asserteq(nextframe, nil, "server closes without matching ACK")
	end, {read_idle_timeout = 30, ping_timeout = 50})
end)

testaux.case("Received frames postpone keepalive", function()
	local ready = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local ch = testaux.await(ready, "client channel ready")
		local function activity()
			assert(conn:write(frame(0xfe, 0, 0) .. frame(6, 0, 0, "activity")))
			while true do
				local incoming = peer.untilframe(conn, 6)
				if incoming.flags & 1 ~= 0 then
					testaux.asserteq(incoming.data, "activity", "activity barrier processed")
					return
				end
				-- A slow runner may legitimately become idle between inputs.
				assert(conn:write(frame(6, 1, 0, incoming.data)))
			end
		end
		for _ = 1, 6 do activity(); testaux.elapse(20) end
		activity()
		-- Drain any probe queued before the last activity barrier.
		while ch.pingtoken do
			local pending = peer.untilframe(conn, 6)
			assert(conn:write(frame(6, 1, 0, pending.data)))
			activity()
		end
		local lastrecv = ch.lastrecv
		local ping = peer.untilframe(conn, 6)
		testaux.asserteq(time.monotonic() - lastrecv >= 60, true, "probe follows a full idle interval after processed activity")
		assert(conn:write(frame(6, 1, 0, ping.data)))
	end, function(ch) ready:push(assert(ch)) end, {read_idle_timeout = 60, ping_timeout = 1000})
end)

testaux.case("Local reset makes subsequent readall fail immediately", function()
	local arrived, release = channel.new(), channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn); peer.untilframe(conn, 1); arrived:push(true)
		peer.untilframe(conn, 3); testaux.await(release, "local reset assertions completed")
	end, function(ch)
		local s = get(assert(ch)); testaux.await(arrived, "peer received request"); s:close()
		local started = time.monotonic()
		local body, err = s:readall(500)
		testaux.asserteq(body, nil, "closed stream has no body")
		testaux.asserteq(type(err), "string", "local reset returns a string error")
		testaux.asserteq(time.monotonic() - started < 100, true, "readall does not wait after reset")
		release:push(true)
	end)
end)

testaux.case("PING works with exhausted connection and stream windows", function()
	local received = false
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		local bytes = 0
		while bytes < 65535 do bytes = bytes + #peer.untilframe(conn, 0).data end
		local ping = peer.untilframe(conn, 6)
		assert(conn:write(frame(6, 1, 0, ping.data)))
		received = true
		assert(conn:write(frame(8, 0, 0, string.pack(">I4", 1)) .. frame(8, 0, request.id, string.pack(">I4", 1))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "b", "DATA resumes with both windows restored")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream()); assert(s:request("POST", "/", {}))
		assert(s:write(string.rep("a", 65535))); assert(s:closewrite("b"))
		testaux.asserteq(received, true, "PING bypassed flow control")
	end, {read_idle_timeout = 30, ping_timeout = 500})
end)

testaux.case("PING does not split outgoing HEADERS and CONTINUATION", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		while request.flags & 4 == 0 do
			request = assert(peer.read(conn))
			testaux.asserteq(request.type, 9, "header block stays contiguous")
		end
		local ping = peer.untilframe(conn, 6)
		assert(conn:write(frame(6, 1, 0, ping.data)))
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("GET", "/", {["x-large"] = string.rep("abcdef0123456789", 2500)})); assert(s:closewrite())
		testaux.asserteq(s:waitresponse(2000), true, "fragmented request survives probe")
	end, {read_idle_timeout = 30, ping_timeout = 500})
end)

testaux.case("Closing channel cancels all keepalive timers", function()
	local snapshot = time._dump().timer_user_data
	local captured
	local ping_seen = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn); peer.untilframe(conn, 6); ping_seen:push(true); peer.untilframe(conn, 7)
	end, function(ch)
		captured = assert(ch); testaux.await(ping_seen, "keepalive probe pending"); ch:close()
	end, {read_idle_timeout = 30, ping_timeout = 500})
	for _, user_data in pairs(snapshot) do testaux.assertneq(user_data, captured, "no timer retains closed channel") end
end)

testaux.case("Server receive limit is independent of peer concurrent-stream settings", function()
	peer.with_server(function(s) s:respond(200, {}); s:closewrite("ok") end, function(conn)
		peer.client_handshake(conn)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 0)))); peer.untilframe(conn, 4)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "peer setting only limits server-initiated streams")
	end)
end)

testaux.case("Late WINDOW_UPDATE for closed client stream is ignored", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		local nextrequest = peer.untilframe(conn, 1)
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 1))))
		assert(conn:write(peer.headers(hpack.new(4096), nextrequest.id, "200")))
	end, function(ch)
		local s = get(assert(ch)); assert(s:waitresponse(2000)); s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:waitresponse(2000), true, "late update does not close channel")
	end)
end)

testaux.case("Response trailers require END_STREAM and forbid pseudo-headers", function()
	for _, trailer in ipairs({{flags = 4, fields = {"x-trailer", "value"}}, {flags = 5, fields = {":status", "200"}}}) do
		peer.with_client(function(conn)
			peer.server_handshake(conn)
			local request = peer.untilframe(conn, 1)
			local encoder = hpack.new(4096)
			assert(conn:write(peer.headers(encoder, request.id, "200", {}, 4)))
			assert(conn:write(frame(1, trailer.flags, request.id, hpack.pack(encoder, {}, table.unpack(trailer.fields)))))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "malformed trailer is a stream error")
		end, function(ch)
			local s<close> = get(assert(ch))
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "invalid trailer fails reader"); testaux.assertneq(err, nil, "trailer error propagated")
		end)
	end
end)

testaux.case("Completed response survives RST_STREAM NO_ERROR", function()
	local reset_processed = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200") .. frame(3, 0, request.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "rst-done")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq(ack.data, "rst-done", "PING barrier follows processed reset")
		reset_processed:push(true)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch)); testaux.await(reset_processed, "NO_ERROR reset processed")
		testaux.asserteq(s:waitresponse(2000), true, "complete response status survives reset")
		testaux.asserteq(s:readall(2000), "", "complete empty body survives reset")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "connection remains usable")
	end)
end)

testaux.case("Completed early response NO_ERROR stops a request without another reset", function()
	local processed, closed = channel.new(), channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 0)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200") .. frame(3, 0, request.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "rst-done")))
		peer.untilframe(conn, 6)
		processed:push(true)
		testaux.await(closed, "application released stopped request")
		assert(conn:write(frame(6, 0, 0, "no-reset")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 3, "peer reset must not trigger another reset")
			if incoming.type == 6 then break end
		end
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		assert(s:write("partial"))
		testaux.await(processed, "early complete response and reset processed")
		testaux.asserteq(s:waitresponse(2000), true, "valid early response survives NO_ERROR")
		testaux.asserteq(s:readall(2000), "", "valid early empty body retained")
		s:close()
		closed:push(true)
	end)
end)

testaux.case("Server NO_ERROR reset cancels an incomplete response writer", function()
	local finished = channel.new()
	peer.with_server(function(s)
		assert(s:respond(200, {}))
		local ok, err = s:closewrite("unfinished")
		finished:push({ok = ok, err = err})
	end, function(conn)
		peer.client_handshake(conn)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
		peer.untilframe(conn, 4)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local headers = peer.untilframe(conn, 1)
		testaux.asserteq(headers.flags & 1, 0, "response writer waits for flow-control credit")
		assert(conn:write(frame(3, 0, 1, string.pack(">I4", 0))))
		local result = testaux.await(finished, "reset woke incomplete response writer")
		testaux.asserteq(result.ok, false, "client reset stops response writer")
		testaux.asserteq(result.err, "Graceful shutdown", "server receives reset reason rather than preserving a request as a response")
		assert(conn:write(frame(6, 0, 0, "no-reset")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 3, "server must not reset an already reset stream")
			testaux.assertneq(incoming.type, 0, "server must not continue the canceled response body")
			if incoming.type == 6 then break end
		end
	end)
end)

testaux.case("Disabled server push is rejected after SETTINGS acknowledgement", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(5, 4, request.id, string.pack(">I4", 2) .. hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 1, "disabled push is PROTOCOL_ERROR")
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "disabled push closes connection")
		testaux.assertneq(err, nil, "push error wakes response waiter")
	end)
end)

testaux.case("Truncated padding field is rejected", function()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 8, request.id)))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 6, "missing pad-length byte is FRAME_SIZE_ERROR")
	end, function(ch)
		local s<close> = get(assert(ch))
		local body = s:readall(2000)
		testaux.asserteq(body, nil, "truncated DATA rejected")
	end)
end)

testaux.case("Invalid server ENABLE_PUSH setting is rejected", function()
	peer.with_client(function(conn)
		assert(conn:read(#peer.preface, 2000) == peer.preface); peer.untilframe(conn, 4)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 2, 1)) .. frame(4, 1, 0)))
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "invalid handshake closes connection")
	end, function(ch, err)
		testaux.asserteq(ch, nil, "server cannot enable push via SETTINGS")
		testaux.assertneq(err, nil, "invalid setting fails handshake")
	end)
end)

testaux.case("Cleartext HTTP2 server reports http scheme", function()
	peer.with_server(function(s) s:respond(200, {["x-scheme"] = s.scheme}); s:closewrite() end, function(conn)
		peer.client_handshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local reply = peer.untilframe(conn, 1)
		local headers = {}; assert(hpack.unpack(hpack.new(4096), reply.data, headers))
		local scheme
		for i = 1, #headers, 2 do if headers[i] == "x-scheme" then scheme = headers[i + 1] end end
		testaux.asserteq(scheme, "http", "server uses transport scheme")
	end)
end)

for _, finish in ipairs({"HEADERS", "DATA", "trailers", "flow-controlled DATA"}) do
	testaux.case("Completed " .. finish .. " response survives handler cleanup failure", function()
		local release = channel.new()
		peer.with_server(function(s)
			assert(s:respond(200, {}))
			local data = finish ~= "HEADERS" and "valid" or nil
			local trailer = finish == "trailers" and {["x-trailer"] = "done"} or nil
			assert(s:closewrite(data, trailer))
			testaux.await(release, "response received before cleanup fails")
			error("intentional cleanup failure")
		end, function(conn)
			peer.client_handshake(conn)
			if finish == "flow-controlled DATA" then
				assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
				peer.untilframe(conn, 4)
			end
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
			local complete = false
			while not complete do
				local incoming = assert(peer.read(conn))
				assert(incoming.type ~= 3, "response reset before completion")
				if finish == "flow-controlled DATA" and incoming.type == 1 then
					assert(conn:write(frame(8, 0, 1, string.pack(">I4", 5))))
				end
				complete = (incoming.type == 1 or incoming.type == 0) and incoming.flags & 1 ~= 0
			end
			release:push(true)
			assert(conn:write(frame(6, 0, 0, "cleanup1")))
			while true do
				local incoming = assert(peer.read(conn))
				assert(incoming.type ~= 3, "completed response received RST_STREAM after cleanup failure")
				if incoming.type == 6 then break end
			end
		end)
	end)
end

testaux.case("NO_ERROR preserves local response validation failure", function()
	local processed = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local req = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), req.id, "200", {["content-length"] = "1"}) .. frame(3, 0, req.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "reset-ok")))
		peer.untilframe(conn, 6)
		processed:push(true)
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.await(processed, "all response frames processed")
		local ok, err = s:waitresponse(2000)
		local body, bodyerr = s:readall(2000)
		assert(not ok, "malformed response accepted after RST_STREAM(NO_ERROR)")
		assert(body == nil, "malformed response body exposed as success")
		testaux.asserteq(err, "Protocol error detected", "NO_ERROR preserves original validation error")
		testaux.asserteq(bodyerr, err, "body retains the same validation error")
	end)
end)

for _, informational in ipairs({false, true}) do
	testaux.case(informational and "DATA after 103 resets only its stream" or "DATA before final response headers resets only its stream", function()
		local processed = channel.new()
		peer.with_client(function(conn)
			peer.server_handshake(conn)
			local first = peer.untilframe(conn, 1)
			local second = peer.untilframe(conn, 1)
			local enc = hpack.new(4096)
			local dat = informational and peer.headers(enc, first.id, "103", {}, 4) or ""
			assert(conn:write(dat .. frame(0, 0, first.id, "invalid")))
			local reply
			repeat reply = assert(peer.read(conn)) until reply.type == 3 or reply.type == 7
			if reply.type == 3 then
				assert(conn:write(peer.headers(enc, second.id, "200", {}, 4) .. frame(0, 1, second.id, "valid") .. frame(6, 0, 0, "data-end")))
				peer.untilframe(conn, 6)
			end
			processed:push(reply)
		end, function(ch)
			local first<close> = get(assert(ch))
			local second<close> = get(ch)
			local reply = testaux.await(processed, "error scope observed")
			testaux.asserteq(reply.type, 3, "malformed response resets only its stream")
			testaux.asserteq(string.unpack(">I4", reply.data), 1, "expected stream PROTOCOL_ERROR")
			assert(ch:isalive(), "unrelated stream lost its connection")
			assert(second:waitresponse(2000))
			assert(second:readall(2000) == "valid", "unrelated response should remain usable")
		end)
	end)
end

testaux.case("DATA on an idle client stream remains a connection error", function()
	local opened = channel.new()
	peer.with_client(function(conn)
		peer.server_handshake(conn)
		local id = testaux.await(opened, "local idle stream allocated")
		assert(conn:write(frame(0, 0, id, "invalid")))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1, "idle DATA is connection PROTOCOL_ERROR")
	end, function(ch, err, observer)
		local s<close> = assert(assert(ch):openstream())
		opened:push(s.id)
		observer:wait_closed()
		testaux.asserteq(ch:isalive(), false, "idle stream DATA closes connection")
	end)
end)

testaux.case("Trailer encoding failure resets an incomplete response", function()
	peer.with_server(function(s)
		assert(s:respond(200, {}))
		local badkey = setmetatable({}, {__tostring = function() error("intentional trailer encoding failure") end})
		local ok, err = pcall(s.closewrite, s, "partial", {[badkey] = "bad"})
		assert(not ok, "trailer encoding must fail")
		error(err)
	end, function(conn)
		peer.client_handshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local complete = false
		while true do
			local f = assert(peer.read(conn))
			if f.type == 1 or f.type == 0 then complete = complete or f.flags & 1 ~= 0 end
			if f.type == 3 then
				assert(not complete, "response must not have END_STREAM")
				assert(string.unpack(">I4", f.data) == 2, "encoding failure still needs INTERNAL_ERROR")
				break
			end
		end
	end)
end)

testaux.case("Completed early response survives handler cleanup failure", function()
	local release = channel.new()
	peer.with_server(function(s)
		assert(s:respond(200, {}))
		assert(s:closewrite("valid"))
		testaux.await(release, "early response received")
		error("intentional cleanup failure with request still open")
	end, function(conn)
		peer.client_handshake(conn)
		assert(conn:write(frame(1, 4, 1, hpack.pack(hpack.new(4096), {}, ":method", "POST", ":scheme", "http", ":path", "/"))))
		while true do
			local f = assert(peer.read(conn))
			if (f.type == 0 or f.type == 1) and f.flags & 1 ~= 0 then break end
		end
		release:push(true)
		assert(conn:write(frame(6, 0, 0, "cleanup2")))
		local codes = {}
		while true do
			local f = assert(peer.read(conn))
			if f.type == 3 then codes[#codes + 1] = string.unpack(">I4", f.data) end
			if f.type == 6 then break end
		end
		testaux.asserteq(#codes, 1, "stop unfinished request with exactly one reset")
		testaux.asserteq(codes[1], 0, "NO_ERROR preserves completed early response")
	end)
end)
end

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
if server then server:close() end
wait_readers()

print("All tests completed!")
