local silly = require "silly"
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

local set_nil = true
local server_handler

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
	end
}

-- Create a test client for connection pool testing
local httpc = http.newclient({
	max_idle_per_host = 10,
	idle_timeout = 2000,  -- 2 seconds for faster cleanup in tests
})

local function wait_done()
	while server_handler do
		time.sleep(100)
	end
end

testaux.case("Test 1: Basic HTTP/2 Server Setup", function()
	testaux.asserteq(not not server, true, "Server should start successfully")
end)

testaux.case("Test 2: HTTP/2 Chunked Transfer", function()
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

testaux.case("Test 3: HTTP/2 Content-Length and Request Body", function()
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

testaux.case("Test 4: HTTP/2 Query Parameters", function()
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

testaux.case("Test 5: HTTP/2 Status Codes", function()
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

testaux.case("Test 6: HTTP/2 Headers Processing", function()
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

testaux.case("Test 7: Content-Type and Accept Headers", function()
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

testaux.case("Test 8: client.request API - Basic GET", function()
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

testaux.case("Test 9: client.request API - POST with body", function()
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

testaux.case("Test 10: client.request API - Multiple writes", function()
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

testaux.case("Test 11: client.request API - HEAD request", function()
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

testaux.case("Test 12: Trailer headers with chunked", function()
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

testaux.case("Test 13: stream:read(n) - partial reads with small data", function()
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

	-- Read after EOF should return empty string
	local chunk5, err = stream:read(5)
	testaux.asserteq(chunk5, "", "Test 13.6: Read after EOF should return empty string")

	wait_done()
end)

testaux.case("Test 14: stream:read(n) - partial reads with multiple writes", function()
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
	testaux.asserteq(chunk4, "", "Test 14.5: Fourth read should get empty string")
	testaux.asserteq(err, "end of stream", "Test 14.6: err should be end of stream")

	local chunk5, err = stream:readall()
	testaux.asserteq(chunk5, "DD", "Test 14.7: Fifth read should get exactly 	2 bytes")
	testaux.asserteq(err, nil, "Test 14.8: err should be nil")

	-- Concatenate and verify total
	local total = chunk1 .. chunk2 .. chunk3 .. chunk4 .. chunk5
	testaux.asserteq(total, "AAAAABBBBBCCCCCDDDDD", "Test 14.6: Total should be exactly 20 bytes")

	wait_done()
end)

testaux.case("Test 15: stream:read(n) - read more than available", function()
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
	testaux.asserteq(chunk, "", "Test 15.2: Should read all 5 available bytes")
	testaux.asserteq(err, "end of stream", "Test 15.3: err should be end of stream")

	local chunk, err = stream:readall()
	testaux.asserteq(chunk, "SHORT", "Test 15.4: Should read all 5 available bytes")
	testaux.asserteq(err, nil, "Test 15.5: err should be nil")

	wait_done()
end)

testaux.case("Test 16: Flow control - Stream window 63KB single stream", function()
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
	time.sleep(200)
	testaux.asserteq(stream.sendwindow, 1023, "Test 16.2: sendwindow should be 1023")
	testaux.asserteq(stream.channel.sendwindow, 65535, "Test 16.3: channel sendwindow should be 65535")
	ch:push("")
	stream:closewrite()
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 16.5: Response should be OK")

	testaux.asserteq(stream.sendwindow, 65535, "Test 16.6: sendwindow should be 0")
	testaux.asserteq(stream.channel.sendwindow, 65535, "Test 16.7: channel sendwindow should be 0")

	wait_done()
end)

testaux.case("Test 17: Flow control - Connection window with concurrent streams", function()
	-- Test that connection window is shared between streams
	-- Stream 1 sends 63KB, then Stream 2 sends 63KB
	-- This should exhaust connection window and require flow control

	local data = crypto.randomkey(63 * 1024)
	local stream1_arrived = false
	local stream2_arrived = false
	local responses = {}

	-- Server handler will be called twice
	local call_count = 0
	server_handler = function(stream)
		call_count = call_count + 1
		local current_call = call_count

		-- Mark stream arrival
		if current_call == 1 then
			stream1_arrived = true
			-- Wait for stream2 to arrive
			while not stream2_arrived do
				time.sleep(10)
			end
		else
			stream2_arrived = true
		end

		local body, err = stream:readall()
		testaux.asserteq(#body, 63 * 1024, "Test 17." .. current_call .. ": Should receive 63KB")

		stream:respond(200, {})
		stream:closewrite("OK" .. current_call)

		responses[current_call] = true
	end

	-- Launch two concurrent requests
	task.fork(function()
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
	while not stream1_arrived do
		time.sleep(10)
	end
	testaux.asserteq(stream1_arrived, true, "Test 17.3: Stream1 should arrive first")

	-- Second stream
	task.fork(function()
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
	while not stream2_arrived do
		time.sleep(10)
	end
	testaux.asserteq(stream2_arrived, true, "Test 17.6: Stream2 should arrive")

	-- Wait for both handlers to complete
	while not (responses[1] and responses[2]) do
		time.sleep(100)
	end
	wait_done()
end)

testaux.case("Test 18: Flow control - Window recovery after read", function()
	-- Test that reading data sends WINDOW_UPDATE and recovers window
	local data = crypto.randomkey(60 * 1024)

	server_handler = function(stream)
		-- Don't read immediately, let client send data
		time.sleep(100)

		local body, err = stream:readall()
		testaux.asserteq(#body, 60 * 1024, "Test 18.1: Should receive 60KB")

		stream:respond(200, {})
		stream:closewrite("OK")
	end

	local stream<close>, err = httpc:request("POST", "https://127.0.0.1:8082", {
		["content-length"] = #data,
	})
	testaux.assertneq(stream, nil, "Test 18.2: stream should not be nil")

	stream:closewrite(data)
	stream:waitresponse()

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 18.3: Response should be OK")

	wait_done()
end)

testaux.case("Test 19: Connection reuse - Multiple requests on same channel", function()
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

testaux.case("Test 20: Connection broken during read", function()
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
	testaux.asserteq(err, "channel goaway", "Test 20.3: Should have error")

	-- server_handler already set to nil by broken connection
	server_handler = nil
end)

testaux.case("Test 21: HTTP/2 GET with gzip compression", function()
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

testaux.case("Test 22: HTTP/2 POST with gzip compression response", function()
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

testaux.case("Test 23: HTTP/2 GET without gzip (no Content-Encoding)", function()
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

testaux.case("Test 24: HTTP/2 GET with Accept-Encoding header check", function()
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

testaux.case("Test 25: HTTP/2 cocurrent stream stream", function()
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

testaux.case("Test 26: HTTP/2 opensream on a closed channel", function()
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
	testaux.asserteq(err, "channel goaway", "Test 26.4: Request should fail")

	local s, err = ch:openstream()
	testaux.asserteq(s, nil, "Test 26.5: Openstream should fail")
	testaux.asserteq(err, "channel goaway", "Test 26.5: Openstream should fail")
end)

testaux.case("Test 27: HTTP/2 streamcount accuracy with concurrent open/close", function()
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
	local blocked = false
	local opened_after_close = false
	local new_stream = nil
	local sync = channel.new()
	task.fork(function()
		blocked = true
		new_stream = ch:openstream()
		opened_after_close = true
		sync:push("done")
	end)

	time.sleep(0)
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
	time.sleep(0)

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
	time.sleep(0)
	set_nil = true
	testaux.asserteq(created_count, 5, "Test 27.12: Should create exactly 5 new streams")
	testaux.asserteq(ch.streamcount, max - 5, "Test 27.13: streamcount should be consistent after concurrent operations")

	-- Step 5: Verify streamcount never exceeded streammax during the test
	-- by trying to open streammax streams again
	for i = 7, max do
		streams[i]:close()
	end
	new_stream:close()
	time.sleep(0)

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
	time.sleep(100)
	-- After graceful close, streams are still open
	testaux.asserteq(ch.streamcount, max, "Test 27.17: streamcount should still be max after graceful close")

	-- Close all streams
	for i = 1, max do
		final_streams[i]:close()
	end
	time.sleep(100)

	-- Now streamcount should be 0
	testaux.asserteq(ch.streamcount, 0, "Test 27.18: streamcount should be 0 after all streams closed")

	-- Verify the channel connection is closed
	testaux.asserteq(ch.conn, nil, "Test 27.19: channel connection should be closed after graceful close completes")
end)

-- Test 28: HPACK encoder state corruption from interleaved streams
-- Bug: When stream1 calls request() (hpack_pack adds headers to dynamic table),
-- then stream2 uses IDENTICAL headers (HPACK encodes as indexed reference),
-- if stream2 sends first, the server's decoder fails (dynamic table entry doesn't exist)
testaux.case("Test 28: HPACK encoder state corruption", function()
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
testaux.case("Test 29: Stream close in IDLE state (no data sent)", function()
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

time.sleep(2000)

if server then
	server:close()
end

time.sleep(2000)

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

print("All tests completed!")
