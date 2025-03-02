local core = require "core"
local json = require "core.json"
local http = require "core.http"
local tcp = require "core.net.tcp"
local testaux = require "test.testaux"

local server
local handler = function(stream)
	stream:respond(200, {["content-type"] = "text/plain"})
	stream:close("OK")
end

-- Test 1: Basic HTTP Server Setup
do
	server = http.listen {
		addr = "127.0.0.1:8080",
		handler = function(stream)
			handler(stream)
		end
	}
	testaux.asserteq(not not server, true, "Test 1: Server should start successfully")
end

-- Test 2: Malformed HTTP Request Headers
do
	-- Send invalid HTTP method
	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 2.1: Client connection should succeed")
	tcp.write(fd, "INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n")
	local line, err = tcp.readline(fd)
	testaux.assertneq(line, nil, "Test 2.2: Server should respond with 405 for invalid method")
	testaux.asserteq(err, nil, "Test 2.2: Server should respond with 405 for invalid method")
	local ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "405", "Test 2.3: Server should respond with 405 for invalid method")
	tcp.close(fd)
	-- send invalid request line
	fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 2.4: Client connection should succeed")
	tcp.write(fd, "INVALID HTTP\r\nHost: localhost\r\n\r\n")
	local line, err = tcp.readline(fd)
	testaux.assertneq(line, nil, "Test 2.5: Server should respond with 405 for invalid request line")
	testaux.asserteq(err, nil, "Test 2.5: Server should respond with 405 for invalid request line")
	local ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "405", "Test 2.6: Server should respond with 405 for invalid request line")
	tcp.close(fd)
end

-- Test 3: HTTP/1.1 Chunked Transfer
do
	handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["transfer-encoding"] = "chunked"
		})
		tcp.write(stream.fd, "5\r\nHello\r\n")
		tcp.write(stream.fd, "5\r\nWorld\r\n")
		tcp.write(stream.fd, "0\r\n\r\n")
		tcp.close(stream.fd)
	end
	local response = http.GET("http://127.0.0.1:8080")
	testaux.asserteq(response.body, "HelloWorld", "Test 3.1: Chunked transfer should be properly decoded")
end

-- Test 4: HTTP Header Size Limits
do
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
	local line, err = tcp.readline(fd)
	testaux.assertneq(line, nil, "Test 4.2: Server should respond with 200 for too large headers")
	testaux.asserteq(err, nil, "Test 4.2: Server should respond with 200 for too large headers")
	local ver, status = line:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "200", "Test 4.3: Server should respond with 200 for too large headers")
	tcp.close(fd)
end

-- Test 5: Connection Keep-Alive
do
	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 5.1: Client connection should succeed")

	-- Send multiple requests on same connection
	tcp.write(fd, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
	local response1, err = tcp.readline(fd)
	testaux.assertneq(response1, nil, "Test 5.2: First request should succeed")
	testaux.asserteq(err, nil, "Test 5.2: First request should succeed")
	tcp.write(fd, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	local response2, err = tcp.readline(fd)
	testaux.assertneq(response2, nil, "Test 5.3: Second request should succeed")
	testaux.asserteq(err, nil, "Test 5.3: Second request should succeed")
	local ver, status = response1:match("HTTP/([%d|.]+)%s+(%d+)")
	testaux.asserteq(status, "200", "Test 5.4: First request should succeed")
	testaux.asserteq(status, "200", "Test 5.5: Second request should succeed")
	tcp.close(fd)
end

-- Teset 6: test connection broken
do
	-- test client connection broken
	handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["transfer-encoding"] = "chunked"
		})
		tcp.write(stream.fd, "5\r\nHello\r\n")
		tcp.write(stream.fd, "5\r\nWorld\r\n")
		--tcp.write(stream.fd, "0\r\n\r\n"); miss this line
		tcp.close(stream.fd)
	end
	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 6.1: Client connection should succeed")
	local response, err = http.GET("http://127.0.0.1:8080")
	testaux.asserteq(response, nil, "Test 6.1: GET should fail")
	testaux.assertneq(err, nil, "Test 6.1: GET should fail")
	tcp.close(fd)
	core.sleep(500) -- wait for server to close connection
	-- test server connection broken
	handler = function(stream)
		local data, err = stream:readall()
		testaux.asserteq(data, nil, "Test 6.2: Server should not receive data")
		testaux.assertneq(err, nil, "Test 6.2: Server should not receive data")
	end
	local fd = tcp.connect("127.0.0.1:8080")
	testaux.assertneq(fd, nil, "Test 6.2: Client connection should succeed")
	tcp.write(fd, "GET / HTTP/1.1\r\nHost: localhost\r\ntransfer-encoding: chunked\r\n\r\n")
	tcp.write(fd, "5\r\nHello\r\n")
	tcp.write(fd, "5\r\nWorld\r\n")
	tcp.close(fd)
	core.sleep(500) -- wait for server to close connection
end

-- Test 7: HTTP Content-Length and Request Body
do
	handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(body, "Hello Server", "Test 7.1: Server should receive request body")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #"Received",
		})
		stream:close("Received")
	end

	local response = http.POST("http://127.0.0.1:8080", {
		["content-type"] = "text/plain"
	}, "Hello Server")
	testaux.assertneq(response, nil, "Test 7.2: POST request should succeed")
	assert(response)
	testaux.asserteq(response.body, "Received", "Test 7.3: Server should acknowledge receipt")
	testaux.asserteq(response.status, 200, "Test 7.4: Status code should be 200")
end

-- Test 8: HTTP Query Parameters
do
	handler = function(stream)
		local query = stream.query
		testaux.asserteq(query["name"], "test", "Test 8.1: Server should receive query parameters")
		testaux.asserteq(query["value"], "123", "Test 8.1: Server should receive query parameters")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #("Query OK"),
		})
		stream:close("Query OK")
	end

	local response = http.GET("http://127.0.0.1:8080?name=test&value=123")
	testaux.assertneq(response, nil, "Test 8.2: GET with query should succeed")
	assert(response)
	testaux.asserteq(response.body, "Query OK", "Test 8.3: Server should process query")
end

-- Test 9: HTTP Status Codes
do
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
		handler = function(stream)
			if code ~= 204 then  -- 204 No Content should not have body
				local txt = "Status: ".. reason
				stream:respond(code, {
					["content-type"] = "text/plain",
					["content-length"] = #txt,
				})
				stream:close(txt)
			else
				stream:respond(code, {["content-type"] = "text/plain"}, true)
			end
		end

		local response = http.GET("http://127.0.0.1:8080")
		testaux.assertneq(response, nil, "Test 9." .. code .. ": Response should be received")
		assert(response)
		testaux.asserteq(response.status, code, "Test 9." .. code .. ": Status code should be " .. code)
		if code ~= 204 then
			testaux.asserteq(response.body, "Status: " .. reason, "Test 9." .. code .. ": Body should match")
		else
			testaux.asserteq(response.body, "", "Test 9.204: Body should be empty for 204")
		end
	end
end

-- Test 10: HTTP Headers Processing
do
	handler = function(stream)
		local user_agent = stream.header["user-agent"] or ""
		local accept = stream.header["accept"] or ""
		local x_test_header2 = stream.header["x-test-header2"]

		testaux.assertneq(user_agent, "", "Test 10.1: Server should receive User-Agent header")
		testaux.assertneq(accept, "", "Test 10.2: Server should receive Accept header")
		testaux.asserteq(type(x_test_header2), "table", "Test 10.3: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[1], "client-value1", "Test 10.4: Server should receive x-test-header2 as table")
		testaux.asserteq(x_test_header2[2], "client-value2", "Test 10.5: Server should receive x-test-header2 as table")

		stream:respond(200, {
			["content-type"] = "text/plain",
			["x-custom-header"] = "test-value",
			["x-empty-header"] = "",
			["x-test-header2"] = {
				"server-value1",
				"server-value2"
			}
		})
		stream:close("Headers OK")
	end

	local response = http.GET("http://127.0.0.1:8080", {
		["user-agent"] = "Test Client",
		["accept"] = "text/plain, application/json",
		["x-test-header"] = "client-value",
		["x-test-header2"] = {
			"client-value1",
			"client-value2"
		}
	})

	testaux.assertneq(response, nil, "Test 10.3: GET with headers should succeed")
	assert(response)
	testaux.asserteq(response.header["x-custom-header"], "test-value", "Test 10.4: Response should include custom header")
	testaux.asserteq(response.header["x-empty-header"], "", "Test 10.5: Response should include empty header")
	testaux.asserteq(response.header["x-test-header2"][1], "server-value1", "Test 10.6: Response should include x-test-header2 as table")
	testaux.asserteq(response.header["x-test-header2"][2], "server-value2", "Test 10.7: Response should include x-test-header2 as table")
end

-- Test 11: Content-Type and Accept Headers
do
	handler = function(stream)
		local accept = stream.header["accept"] or "*/*"
		if accept:find("application/json", 1, true) then
			local dat = json.encode({status = "success", message = "JSON response"})
			stream:respond(200, {
				["content-type"] = "application/json",
				["content-length"] = #dat,
			})
			stream:close(dat)
		else
			local dat = "Plain text response"
			stream:respond(200, {
				["content-type"] = "text/plain",
				["content-length"] = #dat,
			})
			stream:close(dat)
		end
	end

	-- Test with Accept: application/json
	local response = http.GET("http://127.0.0.1:8080", {
		["accept"] = "application/json"
	})
	testaux.assertneq(response, nil, "Test 11.1: JSON request should succeed")
	assert(response)
	testaux.asserteq(response.header["content-type"], "application/json", "Test 12.2: Content-Type should be application/json")
	local decoded = json.decode(response.body)
	testaux.assertneq(decoded, nil, "Test 11.3: Response should be valid JSON")
	assert(decoded)
	testaux.asserteq(decoded.status, "success", "Test 11.4: JSON content should be correct")

	-- Test with Accept: text/plain
	local response = http.GET("http://127.0.0.1:8080", {
		["accept"] = "text/plain"
	})
	testaux.assertneq(response, nil, "Test 11.5: Text request should succeed")
	assert(response)
	testaux.asserteq(response.header["content-type"], "text/plain", "Test 11.6: Content-Type should be text/plain")
	testaux.asserteq(response.body, "Plain text response", "Test 11.7: Text content should be correct")
end

if server then
	server:close()
end
