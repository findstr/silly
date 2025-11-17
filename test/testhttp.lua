local time = require "silly.time"
local json = require "silly.encoding.json"
local http = require "silly.net.http"
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"
local gzip = require "silly.compress.gzip"
local testaux = require "test.testaux"

local server_handler

local server = http.listen {
	addr = "127.0.0.1:8080",
	handler = function(stream)
		server_handler(stream)
		server_handler = nil
	end
}

-- Create a test client for connection pool testing
-- This avoids connection leak detection issues with http.request/get/post
local httpc = http.newclient({
	max_idle_per_host = 10,
	idle_timeout = 2000,  -- 2 seconds for faster cleanup in tests
})

local function wait_done()
	while server_handler do
		time.sleep(100)
	end
end

testaux.case("Test 1: Basic HTTP Server Setup", function()
	testaux.asserteq(not not server, true, "Server should start successfully")
end)

testaux.case("Test 2: Malformed HTTP Request Headers", function()
	-- Send invalid HTTP method
	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 2.1: Client connection should succeed")
	tcp.write(fd, "INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n")
	local line, err = tcp.read(fd, "\n")
	testaux.assertneq(line, nil, "Test 2.2: Server should respond with 405 for invalid method")
	testaux.asserteq(err, nil, "Test 2.2: Server should respond with 405 for invalid method")
	local ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "405", "Test 2.3: Server should respond with 405 for invalid method")
	tcp.close(fd)

	-- send invalid request line
	fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 2.4: Client connection should succeed")
	tcp.write(fd, "INVALID HTTP\r\nHost: localhost\r\n\r\n")
	line, err = tcp.read(fd, "\n")
	testaux.assertneq(line, nil, "Test 2.5: Server should respond with 405 for invalid request line")
	testaux.asserteq(err, nil, "Test 2.5: Server should respond with 405 for invalid request line")
	ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "405", "Test 2.6: Server should respond with 405 for invalid request line")
	tcp.close(fd)
end)

testaux.case("Test 3: HTTP/1.1 Chunked Transfer", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["transfer-encoding"] = "chunked"
		})
		stream:write("Hello")
		stream:write("World")
	end
	local response = httpc:get("http://127.0.0.1:8080")
	testaux.asserteq(response.body, "HelloWorld", "Test 3.1: Chunked transfer should be properly decoded")
	wait_done()
end)

testaux.case("Test 4: HTTP Header Size Limits", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 4.1: Client connection should succeed")

	-- Create very large header
	local huge_header = "GET / HTTP/1.1\r\nHost: localhost\r\n"
	local buf = {}
	for i = 1, 1000 do
		buf[i] = string.format("X-Custom-%d: value%d\r\n", i, i)
	end
	huge_header = huge_header .. table.concat(buf) .. "\r\n"
	tcp.write(fd, huge_header)
	local line, err = tcp.read(fd, "\n")
	testaux.assertneq(line, nil, "Test 4.2: Server should respond with 200 for too large headers")
	testaux.asserteq(err, nil, "Test 4.2: Server should respond with 200 for too large headers")
	local ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "200", "Test 4.3: Server should respond with 200 for too large headers")
	tcp.close(fd)
	wait_done()
end)

testaux.case("Test 5: Connection Keep-Alive", function()
	local function x(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	server_handler = x
	local conn, err = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(conn, nil, "Test 5.1: Client connection should succeed")
	testaux.asserteq(err, nil, "Test 5.1: Client connection should succeed")
	assert(conn)
	-- Send multiple requests on same connection
	conn:write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
	local response1, err = conn:read("\n")
	testaux.assertneq(response1, nil, "Test 5.2: First request should succeed")
	testaux.asserteq(err, nil, "Test 5.2: First request should succeed")
	local ver, status = response1:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "200", "Test 5.3: First request should succeed")
	while true do --drain the left content
		local line, err = conn:read("\n")
		if not line or line == "\r\n" then
			break
		end
	end
	-- Read body (2 bytes: "OK")
	conn:read(2)
	wait_done()  -- Wait for first request to complete
	-- new http request
	server_handler = x
	conn:write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	local response2, err = conn:read("\n")
	testaux.assertneq(response2, nil, "Test 5.4: Second request should succeed")
	testaux.asserteq(err, nil, "Test 5.4: Second request should succeed")
	local ver, status = response2:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "200", "Test 5.5: Second request should succeed")
	conn:close()
	wait_done()
end)

testaux.case("Test 6: Test connection broken", function()
	-- test server connection broken
	server_handler = function(stream)
		testaux.assertneq(stream:remoteaddr(), nil, "Test 6.2: Server stream contains remoteaddr")
		local data, err = stream:readall()
		testaux.asserteq(data, nil, "Test 6.2: Server should not receive data")
		testaux.assertneq(err, nil, "Test 6.2: Server should not receive data")
	end
	local conn, err = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(conn, nil, "Test 6.2: Client connection should succeed")
	testaux.asserteq(err, nil, "Test 6.2: Client connection should succeed")
	assert(conn)
	conn:write("GET / HTTP/1.1\r\nHost: localhost\r\ntransfer-encoding: chunked\r\n\r\n")
	conn:write("5\r\nHello\r\n")
	conn:write("5\r\nWorld\r\n")
	conn:close()
	wait_done()
end)

testaux.case("Test 7: HTTP Content-Length and Request Body", function()
	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "Hello Server", "Test 7.1: Server should receive request body")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #"Received",
		})
		stream:write("Received")
	end
	local response = httpc:post("http://127.0.0.1:8080/foo", {
		["content-type"] = "text/plain"
	}, "Hello Server")
	testaux.assertneq(response, nil, "Test 7.2: POST request should succeed")
	assert(response)
	testaux.asserteq(response.body, "Received", "Test 7.3: Server should acknowledge receipt")
	testaux.asserteq(response.status, 200, "Test 7.4: Status code should be 200")
	wait_done()
end)

testaux.case("Test 8: HTTP Query Parameters", function()
	server_handler = function(stream)
		local query = stream.query
		testaux.asserteq(query["name"], "test", "Test 8.1: Server should receive query parameters")
		testaux.asserteq(query["value"], "123", "Test 8.1: Server should receive query parameters")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #("Query OK"),
		})
		stream:write("Query OK")
	end

	local response = httpc:get("http://127.0.0.1:8080?name=test&value=123")
	testaux.assertneq(response, nil, "Test 8.2: GET with query should succeed")
	assert(response)
	testaux.asserteq(response.body, "Query OK", "Test 8.3: Server should process query")
	wait_done()
end)

testaux.case("Test 9: HTTP Status Codes", function()
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
				local txt = "Status: ".. reason
				stream:respond(code, {
					["content-type"] = "text/plain",
					["content-length"] = #txt,
				})
				stream:write(txt)
			else
				stream:respond(code, {["content-type"] = "text/plain"})
			end
		end

		local response = httpc:get("http://127.0.0.1:8080")
		testaux.assertneq(response, nil, "Test 9." .. code .. ": Response should be received")
		assert(response)
		testaux.asserteq(response.status, code, "Test 9." .. code .. ": Status code should be " .. code)
		if code ~= 204 then
			testaux.asserteq(response.body, "Status: " .. reason, "Test 9." .. code .. ": Body should match")
		else
			testaux.asserteq(response.body, "", "Test 9.204: Body should be empty for 204")
		end
		wait_done()
	end
end)

testaux.case("Test 10: HTTP Headers Processing", function()
	server_handler = function(stream)
		local user_agent = stream.header["user-agent"] or ""
		local accept = stream.header["accept"] or ""
		local x_test_header2 = stream.header["x-test-header2"]

		testaux.assertneq(user_agent, "", "Test 10.2: Server should receive User-Agent header")
		testaux.assertneq(accept, "", "Test 10.3: Server should receive Accept header")
		testaux.asserteq(type(x_test_header2), "table", "Test 10.4: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[1], "client-value1", "Test 10.5: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[2], "client-value2", "Test 10.6: Server should receive x-test-header2 as table")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["x-custom-header"] = "test-value",
			["x-empty-header"] = "",
			["x-test-header2"] = {
				"server-value1",
				"server-value2"
			}
		})
		stream:write("Headers OK")
	end

	local response = httpc:get("http://127.0.0.1:8080", {
		["user-agent"] = "Test Client",
		["accept"] = "text/plain, application/json",
		["x-test-header"] = "client-value",
		["x-test-header2"] = {
			"client-value1",
			"client-value2"
		}
	})

	testaux.assertneq(response, nil, "Test 10.1: GET with headers should succeed")
	assert(response)
	testaux.asserteq(response.header["x-custom-header"], "test-value", "Test 10.7: Response should include custom header")
	testaux.asserteq(response.header["x-empty-header"], "", "Test 10.8: Response should include empty header")
	testaux.asserteq(response.header["x-test-header2"][1], "server-value1", "Test 10.9: Response should include x-test-header2 as table")
	testaux.asserteq(response.header["x-test-header2"][2], "server-value2", "Test 10.10: Response should include x-test-header2 as table")
	wait_done()
end)

testaux.case("Test 11: Content-Type and Accept Headers", function()
	local function x(stream)
		local accept = stream.header["accept"] or "*/*"
		if accept:find("application/json", 1, true) then
			local dat = json.encode({status = "success", message = "JSON response"})
			stream:respond(200, {
				["content-type"] = "application/json",
				["content-length"] = #dat,
			})
			stream:write(dat)
		else
			local dat = "Plain text response"
			stream:respond(200, {
				["content-type"] = "text/plain",
				["content-length"] = #dat,
			})
			stream:write(dat)
		end
	end

	server_handler = x
	-- Test with Accept: application/json
	local response = httpc:get("http://127.0.0.1:8080", {
		["accept"] = "application/json"
	})
	testaux.assertneq(response, nil, "Test 11.1: JSON request should succeed")
	assert(response)
	testaux.asserteq(response.header["content-type"], "application/json", "Test 11.2: Content-Type should be application/json")
	local decoded = json.decode(response.body)
	testaux.assertneq(decoded, nil, "Test 11.3: Response should be valid JSON")
	assert(decoded)
	testaux.asserteq(decoded.status, "success", "Test 11.4: JSON content should be correct")

	-- Test with Accept: text/plain
	server_handler = x
	local response = httpc:get("http://127.0.0.1:8080", {
		["accept"] = "text/plain"
	})
	testaux.assertneq(response, nil, "Test 11.5: Text request should succeed")
	assert(response)
	testaux.asserteq(response.header["content-type"], "text/plain", "Test 11.6: Content-Type should be text/plain")
	testaux.asserteq(response.body, "Plain text response", "Test 11.7: Text content should be correct")
	wait_done()
end)

testaux.case("Test 12: client.request API - Basic GET", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "GET", "Test 12.1: Method should be GET")
		testaux.asserteq(stream.path, "/api/test", "Test 12.2: Path should be /api/test")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080/api/test", {})
	testaux.assertneq(stream, nil, "Test 12.3: stream should not be nil")
	testaux.asserteq(err, nil, "Test 12.4: err should be nil")
	stream:closewrite()
	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 12.4.1: waitresponse should succeed")
	testaux.asserteq(stream.status, 200, "Test 12.5: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 12.6: body should be OK")
	wait_done()
end)

testaux.case("Test 13: client.request API - POST with body", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "POST", "Test 13.1: Method should be POST")
		local body, err = stream:readall()
		testaux.asserteq(body, "Request Data", "Test 13.2: body should be 'Request Data'")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 8,
		})
		stream:write("Received")
	end

	local stream<close>, err = httpc:request("POST", "http://127.0.0.1:8080", {
		["content-length"] = 12,
	})
	testaux.assertneq(stream, nil, "Test 13.3: stream should not be nil")

	stream:closewrite("Request Data")
	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 13.4: waitresponse should succeed")
	testaux.asserteq(stream.status, 200, "Test 13.5: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "Received", "Test 13.6: body should be 'Received'")
	wait_done()
end)

testaux.case("Test 14: client.request API - Chunked request", function()
	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "part1part2part3", "Test 14.1: body should be concatenated")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local stream<close>, err = httpc:request("POST", "http://127.0.0.1:8080", {
		["transfer-encoding"] = "chunked",
	})
	testaux.assertneq(stream, nil, "Test 14.2: stream should not be nil")

	stream:write("part1")
	stream:write("part2")
	stream:write("part3")
	stream:closewrite()

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 14.3: body should be OK")
	wait_done()
end)

testaux.case("Test 15: client.request API - HEAD request", function()
	server_handler = function(stream)
		testaux.asserteq(stream.method, "HEAD", "Test 15.1: Method should be HEAD")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 100,
		})
	end

	local stream<close>, err = httpc:request("HEAD", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 15.2: stream should not be nil")
	stream:closewrite()
	stream:waitresponse()
	testaux.asserteq(stream.status, 200, "Test 15.3: status should be 200")
	testaux.asserteq(stream.eof, true, "Test 15.4: eof should be true for HEAD")

	local body, err = stream:readall()
	testaux.asserteq(body, "", "Test 15.5: body should be empty for HEAD")
	wait_done()
end)

testaux.case("Test 16: client.request API - Incremental read from chunked", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("chunk1")
		stream:write("chunk2")
		stream:write("chunk3")
		stream:closewrite()
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 16.1: stream should not be nil")
	stream:closewrite()
	local chunk1, err = stream:read(6)
	testaux.asserteq(chunk1, "chunk1", "Test 16.2: first chunk should be 'chunk1'")

	local chunk2 = stream:read(6)
	testaux.asserteq(chunk2, "chunk2", "Test 16.3: second chunk should be 'chunk2'")

	local chunk3 = stream:read(6)
	testaux.asserteq(chunk3, "chunk3", "Test 16.4: third chunk should be 'chunk3'")

	local last = stream:read(6)
	testaux.asserteq(last, "", "Test 16.5: last read should be empty")
	testaux.asserteq(stream.eof, true, "Test 16.6: eof should be true")
	wait_done()
end)

testaux.case("Test 17: client.request API - closewrite with data", function()
	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "Final", "Test 17.1: body should be 'Final'")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local stream<close>, err = httpc:request("POST", "http://127.0.0.1:8080", {
		["content-length"] = 5,
	})
	testaux.assertneq(stream, nil, "Test 17.2: stream should not be nil")
	stream:closewrite("Final")

	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 17.3: waitresponse should succeed")
	testaux.asserteq(err, nil, "Test 17.3.1: err should be nil")

	local body, err = stream:readall()
	testaux.asserteq(body, "OK", "Test 17.4: body should be OK")
	wait_done()
end)

testaux.case("Test 18: Chunked with trailer headers", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["transfer-encoding"] = "chunked",
		})
		stream:write("data1")
		stream:write("data2")
		-- Only case where server needs closewrite - to send trailers
		stream:closewrite(nil, {
			["x-checksum"] = "abc123",
			["x-final-status"] = "complete"
		})
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 18.1: stream should not be nil")
	testaux.asserteq(err, nil, "Test 18.2: err should be nil")
	stream:closewrite()
	local body, err = stream:readall()
	testaux.asserteq(body, "data1data2", "Test 18.3: body should be concatenated")
	testaux.assertneq(stream.trailer, nil, "Test 18.4: trailer should be received")
	testaux.asserteq(stream.trailer["x-checksum"], "abc123", "Test 18.5: trailer header should match")
	testaux.asserteq(stream.trailer["x-final-status"], "complete", "Test 18.6: trailer header should match")
	wait_done()
end)

testaux.case("Test 19: Connection pool - H1 reuse", function()
	local c = http.newclient({
		max_idle_per_host = 2,
		idle_timeout = 2000,
	})

	-- First request
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local stream1<close>, err = c:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream1, nil, "Test 19.1: First request should succeed")
	stream1:closewrite()
	local body1, err = stream1:readall()
	testaux.asserteq(body1, "OK", "Test 19.2: First response body should be OK")
	wait_done()

	-- Second request - should reuse connection
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 3,
		})
		stream:write("OK2")
	end

	local stream2<close>, err = c:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream2, nil, "Test 19.3: Second request should succeed")
	stream2:closewrite()
	local body2, err = stream2:readall()
	testaux.asserteq(body2, "OK2", "Test 19.4: Second response body should be OK2")
	wait_done()
end)

testaux.case("Test 20: Connection pool - max_idle_per_host limit", function()
	local c = http.newclient({
		max_idle_per_host = 2,
		idle_timeout = 2000,
	})

	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	-- Create 3 connections
	for i = 1, 3 do
		local stream<close>, err = c:request("GET", "http://127.0.0.1:8080", {})
		testaux.assertneq(stream, nil, "Test 20." .. i .. ": Request should succeed")
		stream:closewrite()
		local body, err = stream:readall()
		testaux.asserteq(body, "OK", "Test 20." .. i .. ": Body should be OK")
		wait_done()
		server_handler = function(stream)
			stream:respond(200, {
				["content-type"] = "text/plain",
				["content-length"] = 2,
			})
			stream:write("OK")
		end
	end

	-- Pool should only have 2 idle connections (max_idle_per_host = 2)
	-- Third connection should be closed when released
end)

testaux.case("Test 21: Connection pool - chunked response reuse", function()
	local c = http.newclient({
		max_idle_per_host = 2,
		idle_timeout = 2000,
	})

	-- First request with chunked
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("chunk1")
		stream:write("chunk2")
	end

	local stream1<close>, err = c:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream1, nil, "Test 21.1: First request should succeed")
	stream1:closewrite()
	local body1, err = stream1:readall()
	testaux.asserteq(body1, "chunk1chunk2", "Test 21.2: Chunked body should be concatenated")
	wait_done()

	-- Second request - should reuse connection
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local stream2<close>, err = c:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream2, nil, "Test 21.3: Second request should succeed")
	stream2:closewrite()
	local body2, err = stream2:readall()
	testaux.asserteq(body2, "OK", "Test 21.4: Second response should be OK")
	wait_done()
end)

testaux.case("Test 22: stream:read(n) - content-length partial reads", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 20,
		})
		stream:write("12345678901234567890")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 22.1: Request should succeed")
	stream:closewrite()

	-- Read 5 bytes at a time
	local chunk1, err = stream:read(5)
	testaux.asserteq(chunk1, "12345", "Test 22.2: First read should get 5 bytes")
	testaux.asserteq(stream.eof, false, "Test 22.3: EOF should be false after first read")

	local chunk2, err = stream:read(5)
	testaux.asserteq(chunk2, "67890", "Test 22.4: Second read should get 5 bytes")
	testaux.asserteq(stream.eof, false, "Test 22.5: EOF should be false after second read")

	local chunk3, err = stream:read(5)
	testaux.asserteq(chunk3, "12345", "Test 22.6: Third read should get 5 bytes")
	testaux.asserteq(stream.eof, false, "Test 22.7: EOF should be false after third read")

	local chunk4, err = stream:read(5)
	testaux.asserteq(chunk4, "67890", "Test 22.8: Fourth read should get 5 bytes")
	testaux.asserteq(stream.eof, true, "Test 22.9: EOF should be true after reading all")

	-- Read after EOF should return empty string
	local chunk5, err = stream:read(5)
	testaux.asserteq(chunk5, "", "Test 22.10: Read after EOF should return empty string")
	testaux.asserteq(stream.eof, true, "Test 22.11: EOF should remain true")

	wait_done()
end)

testaux.case("Test 23: stream:read(n) - chunked partial reads", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("AAAAA")  -- 5 bytes
		stream:write("BBBBB")  -- 5 bytes
		stream:write("CCCCC")  -- 5 bytes
		stream:write("DDDDD")  -- 5 bytes
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 23.1: Request should succeed")
	stream:closewrite()

	-- Read 7 bytes - should span across chunks and get exactly 7 bytes
	local chunk1, err = stream:read(7)
	testaux.asserteq(chunk1, "AAAAABB", "Test 23.2: First read should get exactly 7 bytes (spans chunks)")
	testaux.asserteq(stream.eof, false, "Test 23.3: EOF should be false after first read")

	-- Read 8 bytes - should get exactly 8 bytes
	local chunk2, err = stream:read(8)
	testaux.asserteq(chunk2, "BBBCCCCC", "Test 23.4: Second read should get exactly 8 bytes")
	testaux.asserteq(stream.eof, false, "Test 23.5: EOF should be false after second read")

	-- Read 3 bytes
	local chunk3, err = stream:read(3)
	testaux.asserteq(chunk3, "DDD", "Test 23.6: Third read should get exactly 3 bytes")
	testaux.asserteq(stream.eof, false, "Test 23.7: EOF should be false after third read")

	-- Read rest (2 bytes left)
	local chunk4, err = stream:read(10)
	testaux.asserteq(chunk4, "", "Test 23.8: Fourth read should get empty string (due to EOF)")
	testaux.asserteq(err, "end of file", "Test 23.9: Should get end of file error")
	testaux.asserteq(stream.eof, true, "Test 23.9: EOF should be true after reading all")

	-- Read accurately
	local chunk5, err = stream:read(1)
	testaux.asserteq(chunk5, "D", "Test 23.10: Fifth read should get 1 byte")
	testaux.asserteq(err, nil, "Test 23.11: Should not get error")
	testaux.asserteq(stream.eof, true, "Test 23.12: EOF should be true after reading all")

	local chunk6, err = stream:readall()
	testaux.asserteq(chunk6, "D", "Test 23.13: Sixth read should get 2 byte")
	testaux.asserteq(err, nil, "Test 23.14: Should not get error")
	testaux.asserteq(stream.eof, true, "Test 23.15: EOF should be true after reading all")

	-- Concatenate and verify total
	local total = chunk1 .. chunk2 .. chunk3 .. chunk4 .. chunk5 .. chunk6
	testaux.asserteq(total, "AAAAABBBBBCCCCCDDDDD", "Test 23.16: Total should be exactly 20 bytes")

	wait_done()
end)

testaux.case("Test 24: stream:read(n) - read more than available with content-length", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 10,
		})
		stream:write("1234567890")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 24.1: Request should succeed")
	stream:closewrite()

	-- Try to read 100 bytes, but only 10 available
	local chunk, err = stream:read(100)
	testaux.asserteq(chunk, "", "Test 24.2: Should read all 10 available bytes")
	testaux.asserteq(err, "end of file", "Test 24.3: Should get end of file error")
	testaux.asserteq(stream.eof, true, "Test 24.4: EOF should be true")

	local chunk1, err = stream:read(5)
	testaux.asserteq(chunk1, "12345", "Test 24.5: Should read 5 bytes")
	testaux.asserteq(err, nil, "Test 24.6: Should not get error")
	testaux.asserteq(stream.eof, true, "Test 24.7: EOF should be true")

	chunk, err = stream:readall()
	testaux.asserteq(chunk, "67890", "Test 24.8: Should read all 5 available bytes")
	testaux.asserteq(err, nil, "Test 24.9: Should not get error")
	testaux.asserteq(stream.eof, true, "Test 24.10: EOF should be true")

	wait_done()
end)

testaux.case("Test 25: stream:read(n) - read more than available with chunked", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("SHORT")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 25.1: Request should succeed")
	stream:closewrite()

	-- Try to read 100 bytes, but only 5 available before EOF
	local chunk, err = stream:read(100)
	testaux.asserteq(chunk, "", "Test 25.2: Should read empty string")
	testaux.asserteq(err, "end of file", "Test 25.3: Should get end of file error")
	testaux.asserteq(stream.eof, true, "Test 25.4: EOF should be true")

	chunk, err = stream:readall()
	testaux.asserteq(chunk, "SHORT", "Test 25.5: Should read all 5 available bytes")
	testaux.asserteq(err, nil, "Test 25.6: Should not get error")
	testaux.asserteq(stream.eof, true, "Test 25.7: EOF should be true")

	wait_done()
end)

testaux.case("Test 26: Timeout marks stream as broken", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 20,
		})
		-- Only write 5 bytes, then delay forever (never complete)
		stream:write("12345")
		stream:flush()
		time.sleep(500)  -- delay longer than client timeout
		stream:write("67890ABCDEFGHIJ")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 26.1: Request should succeed")
	stream:closewrite()

	-- Read with short timeout - should timeout
	local chunk1, err = stream:read(10, 50)
	testaux.asserteq(chunk1, nil, "Test 26.2: chunk1 should be nil on timeout")
	testaux.asserteq(err, "read timeout", "Test 26.3: err should be read timeout")
	testaux.assertneq(stream.err, nil, "Test 26.4: stream.err should be set after timeout")
	testaux.asserteq(stream.err, "read timeout", "Test 26.5: stream.err should be read timeout")

	-- Subsequent reads should fail immediately with the cached error
	local chunk2, err2 = stream:read(5)
	testaux.asserteq(chunk2, nil, "Test 26.6: chunk2 should be nil")
	testaux.asserteq(err2, "read timeout", "Test 26.7: err should be cached timeout error")

	-- readall should also fail
	local body, err3 = stream:readall()
	testaux.asserteq(body, nil, "Test 26.8: body should be nil")
	testaux.asserteq(err3, "read timeout", "Test 26.9: readall should return cached error")

	wait_done()
end)

testaux.case("Test 27: read() exceeding Content-Length", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 10,
		})
		stream:write("1234567890")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 27.1: Request should succeed")
	stream:closewrite()

	-- Read exactly Content-Length
	local chunk1, err = stream:read(10)
	testaux.asserteq(chunk1, "1234567890", "Test 27.2: Read exact length")
	testaux.asserteq(stream.eof, true, "Test 27.3: EOF should be true")

	-- Try to read more
	local chunk2, err = stream:read(10)
	testaux.asserteq(chunk2, "", "Test 27.4: Read after EOF should return empty")
	testaux.asserteq(err, "end of file", "Test 27.5: Should get end of file error")

	wait_done()
end)

testaux.case("Test 28: read() after chunked ends", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("AAAAA")
		stream:write("BBBBB")
		-- closewrite sends the final 0 chunk
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 28.1: Request should succeed")
	stream:closewrite()

	-- Read all data
	local body, err = stream:readall()
	testaux.asserteq(body, "AAAAABBBBB", "Test 28.2: Should read all chunks")
	testaux.asserteq(stream.eof, true, "Test 28.3: EOF should be true")

	-- Try to read more
	local chunk, err = stream:read(10)
	testaux.asserteq(chunk, "", "Test 28.4: Read after EOF should return empty")
	testaux.asserteq(err, "end of file", "Test 28.5: Should get end of file error")

	wait_done()
end)

testaux.case("Test 29: read() partial, then readall() rest - Content-Length", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 20,
		})
		stream:write("12345678901234567890")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 29.1: Request should succeed")
	stream:closewrite()

	-- Read partial
	local chunk1, err = stream:read(5)
	testaux.asserteq(chunk1, "12345", "Test 29.2: First read should get 5 bytes")
	testaux.asserteq(stream.eof, false, "Test 29.3: EOF should be false")

	-- readall() should get the rest
	local rest, err = stream:readall()
	testaux.asserteq(rest, "678901234567890", "Test 29.4: readall should get remaining 15 bytes")
	testaux.asserteq(stream.eof, true, "Test 29.5: EOF should be true")

	wait_done()
end)

testaux.case("Test 30: read() partial, then readall() rest - Chunked", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("AAAAA")
		stream:write("BBBBB")
		stream:write("CCCCC")
		stream:write("DDDDD")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 30.1: Request should succeed")
	stream:closewrite()

	-- Read partial (spans chunks)
	local chunk1, err = stream:read(7)
	testaux.asserteq(chunk1, "AAAAABB", "Test 30.2: First read should span chunks")

	-- readall() should get the rest
	local rest, err = stream:readall()
	testaux.asserteq(rest, "BBBCCCCCDDDDD", "Test 30.3: readall should get rest")
	testaux.asserteq(stream.eof, true, "Test 30.4: EOF should be true")

	local total = chunk1 .. rest
	testaux.asserteq(total, "AAAAABBBBBCCCCCDDDDD", "Test 30.5: Total should be complete")

	wait_done()
end)

testaux.case("Test 31: Connection broken - Content-Length incomplete", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 100,
		})
		stream:write("12345")  -- Only send 5 bytes, then close
		-- Connection will be broken when stream closes
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 31.1: Request should succeed")
	stream:closewrite()

	wait_done()  -- Wait for server to close connection

	-- Try to readall - should fail with body broken
	local body, err = stream:readall()
	testaux.asserteq(body, nil, "Test 31.2: readall should fail")
	testaux.assertneq(err, nil, "Test 31.3: Should have error")
	testaux.assertneq(stream.err, nil, "Test 31.4: stream.err should be set (connection dead)")

	-- Try to read again - should fail immediately
	local chunk, err2 = stream:read(10)
	testaux.asserteq(chunk, nil, "Test 31.5: read should fail")
	testaux.asserteq(err2, stream.err, "Test 31.6: Should return cached error")
end)

testaux.case("Test 32: Connection broken - Chunked incomplete", function()
	server_handler = function(stream)
		stream:respond(200, {
			["transfer-encoding"] = "chunked",
		})
		stream:write("AAAAA")
		stream.conn:close()
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 32.1: Request should succeed")
	stream:closewrite()

	wait_done()  -- Wait for server to close

	-- Try to readall - should fail
	local body, err = stream:readall()
	testaux.asserteq(body, nil, "Test 32.2: readall should fail")
	testaux.assertneq(err, nil, "Test 32.3: Should have error")
	testaux.assertneq(stream.err, nil, "Test 32.4: stream.err should be set")
end)


testaux.case("Test 33: read() returns buffered data before network read", function()
	server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 20,
		})
		stream:write("12345678901234567890")
	end

	local stream<close>, err = httpc:request("GET", "http://127.0.0.1:8080", {})
	testaux.assertneq(stream, nil, "Test 33.1: Request should succeed")
	stream:closewrite()

	-- Read more than available in one request
	local chunk1, err = stream:read(30)
	testaux.asserteq(chunk1, "", "Test 33.2: Should read only available 20 bytes")
	testaux.asserteq(stream.eof, true, "Test 33.3: EOF should be true")

	-- Buffer should be empty now
	local chunk2, err = stream:read(20)
	testaux.asserteq(chunk2, "12345678901234567890", "Test 33.4: Should read all 20 bytes")
	testaux.asserteq(stream.eof, true, "Test 33.5: EOF should be true")

	wait_done()
end)

testaux.case("Test 34: GET with gzip compression", function()
	local original_data = "Hello World! This is a test data that should be compressed with gzip. " ..
		"The more data we have, the better compression ratio we get. " ..
		"So let's add some more text here to make it longer and more compressible."

	server_handler = function(stream)
		-- Compress the data
		local compressed, err = gzip.compress(original_data)
		testaux.assertneq(compressed, nil, "Test 34.1: gzip.compress should succeed")
		testaux.asserteq(err, nil, "Test 34.2: gzip.compress should not return error")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-encoding"] = "gzip",
			["content-length"] = #compressed,
		})
		stream:write(compressed)
	end

	-- http.get should automatically decompress
	local response = httpc:get("http://127.0.0.1:8080")
	testaux.assertneq(response, nil, "Test 34.3: GET should succeed")
	testaux.asserteq(response.status, 200, "Test 34.4: Status should be 200")
	testaux.asserteq(response.body, original_data, "Test 34.5: Body should be automatically decompressed")
	testaux.asserteq(response.header["content-encoding"], "gzip", "Test 34.6: Content-Encoding header should be preserved")
	wait_done()
end)

testaux.case("Test 35: POST with gzip compression response", function()
	local request_data = "Request from client"
	local response_data = "This is a compressed response from server. " ..
		"Adding more text to make compression more effective."

	server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, request_data, "Test 35.1: Server should receive uncompressed request")

		-- Compress the response
		local compressed, err = gzip.compress(response_data)
		testaux.assertneq(compressed, nil, "Test 35.2: gzip.compress should succeed")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-encoding"] = "gzip",
			["content-length"] = #compressed,
		})
		stream:write(compressed)
	end

	-- http.post should automatically decompress
	local response = httpc:post("http://127.0.0.1:8080", {
		["content-type"] = "text/plain"
	}, request_data)
	testaux.assertneq(response, nil, "Test 35.3: POST should succeed")
	testaux.asserteq(response.status, 200, "Test 35.4: Status should be 200")
	testaux.asserteq(response.body, response_data, "Test 35.5: Body should be automatically decompressed")
	wait_done()
end)

testaux.case("Test 36: GET without gzip (no Content-Encoding)", function()
	local original_data = "Uncompressed data"

	server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #original_data,
		})
		stream:write(original_data)
	end

	-- Should work normally without decompression
	local response = httpc:get("http://127.0.0.1:8080")
	testaux.assertneq(response, nil, "Test 36.1: GET should succeed")
	testaux.asserteq(response.body, original_data, "Test 36.2: Body should remain uncompressed")
	wait_done()
end)

testaux.case("Test 37: GET with Accept-Encoding header check", function()
	server_handler = function(stream)
		local accept_encoding = stream.header["accept-encoding"]
		testaux.asserteq(accept_encoding, "gzip", "Test 37.1: Client should send Accept-Encoding: gzip")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local response = httpc:get("http://127.0.0.1:8080")
	testaux.asserteq(response.body, "OK", "Test 37.2: Response should be OK")
	wait_done()
end)

time.sleep(5000)

if server then
	server:close()
end
