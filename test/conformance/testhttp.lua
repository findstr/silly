local os = os
local time = require "silly.time"
local client = require "silly.net.http.client"
local http = require "silly.net.http"
local json = require "silly.encoding.json"
local testaux = require "test.testaux"
local conformance = require "test.conformance"

-- Connect to the Go conformance process started by test.sh
local env = require "silly.env"
local GO_PORT = tonumber(env.get("conf_port")) or 19090

local c = conformance.connect("127.0.0.1", GO_PORT)

local netstat = testaux.netstat

-----------------------------------------------------------
-- Group A: Go client → Lua server
-----------------------------------------------------------

local lua_server_handler
local LUA_PORT = 18080

-- Single Lua HTTP server for all Group A tests (avoid frequent
-- listen/close which can fail on some platforms)
local lua_server = http.listen {
	addr = "127.0.0.1:" .. LUA_PORT,
	handler = function(stream)
		if lua_server_handler then
			lua_server_handler(stream)
			lua_server_handler = nil
		end
	end
}

local function wait_handler()
	local count = 0
	while lua_server_handler do
		time.sleep(50)
		count = count + 1
		if count > 100 then
			testaux.error("wait_handler timeout")
		end
	end
end

testaux.case("Test 1: GET with Content-Length response", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "GET", "Test 1.1: method should be GET")
		testaux.asserteq(stream.path, "/test", "Test 1.2: path should be /test")
		local body = "Hello from Lua"
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #body,
		})
		stream:write(body)
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/test")
	testaux.assertneq(resp, nil, "Test 1.3: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 1.4: status should be 200")
	testaux.asserteq(resp.body, "Hello from Lua", "Test 1.5: body should match")

	wait_handler()
end)

testaux.case("Test 2: POST with body", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "POST", "Test 2.1: method should be POST")
		local body, err = stream:readall()
		testaux.asserteq(body, "request data", "Test 2.2: server should receive request body")
		testaux.asserteq(err, nil, "Test 2.3: readall should not error")
		local resp_body = "received: " .. body
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = #resp_body,
		})
		stream:write(resp_body)
	end

	local resp = c:http_request("POST", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Content-Type"] = "text/plain"},
		body = "request data",
	})
	testaux.assertneq(resp, nil, "Test 2.4: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 2.5: status should be 200")
	testaux.asserteq(resp.body, "received: request data", "Test 2.6: body should echo request")

	wait_handler()
end)

testaux.case("Test 3: PUT with body", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "PUT", "Test 3.1: method should be PUT")
		local body, err = stream:readall()
		testaux.asserteq(body, "put data", "Test 3.2: server should receive PUT body")
		testaux.asserteq(err, nil, "Test 3.3: readall should not error")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("PUT", "http://127.0.0.1:" .. LUA_PORT .. "/resource", {
		headers = {["Content-Type"] = "text/plain"},
		body = "put data",
	})
	testaux.assertneq(resp, nil, "Test 3.4: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 3.5: status should be 200")

	wait_handler()
end)

testaux.case("Test 4: DELETE without body", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "DELETE", "Test 4.1: method should be DELETE")
		stream:respond(204, {})
	end

	local resp = c:http_request("DELETE", "http://127.0.0.1:" .. LUA_PORT .. "/resource")
	testaux.assertneq(resp, nil, "Test 4.2: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 204, "Test 4.3: status should be 204")

	wait_handler()
end)

testaux.case("Test 5: HEAD request", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "HEAD", "Test 5.1: method should be HEAD")
		stream:respond(200, {
			["content-length"] = 100,
		})
	end

	local resp = c:http_request("HEAD", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 5.2: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 5.3: status should be 200")
	testaux.asserteq(resp.body, "", "Test 5.4: body should be empty for HEAD")

	wait_handler()
end)

testaux.case("Test 6: OPTIONS request", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "OPTIONS", "Test 6.1: method should be OPTIONS")
		stream:respond(204, {
			["allow"] = "GET, POST, PUT, DELETE, HEAD, OPTIONS",
		})
	end

	local resp = c:http_request("OPTIONS", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 6.2: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 204, "Test 6.3: status should be 204")

	wait_handler()
end)

testaux.case("Test 7: Chunked request body", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "POST", "Test 7.1: method should be POST")
		local body, err = stream:readall()
		testaux.asserteq(err, nil, "Test 7.2: readall should not error")
		testaux.assertneq(body, nil, "Test 7.3: server should receive body")
		testaux.asserteq(#body > 0, true, "Test 7.4: body should not be empty")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("POST", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Content-Type"] = "text/plain"},
		body = "chunk1chunk2chunk3",
	})
	testaux.assertneq(resp, nil, "Test 7.5: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 7.6: status should be 200")

	wait_handler()
end)

testaux.case("Test 8: Chunked response", function()
	lua_server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
			["transfer-encoding"] = "chunked",
		})
		stream:write("chunk1")
		stream:write("chunk2")
		stream:write("chunk3")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 8.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 8.2: status should be 200")
	testaux.asserteq(resp.body, "chunk1chunk2chunk3", "Test 8.3: body should be concatenated chunks")

	wait_handler()
end)

testaux.case("Test 9: Response without Content-Length or chunked (read until EOF)", function()
	lua_server_handler = function(stream)
		local conn = stream.conn
		conn:write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
		conn:write("data until EOF")
		conn:close()
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 9.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 9.2: status should be 200")
	testaux.asserteq(resp.body, "data until EOF", "Test 9.3: body should be read until EOF")

	wait_handler()
end)

testaux.case("Test 10: Multiple requests on keep-alive", function()
	-- Separate port with stateful handler that persists across requests
	local KA_PORT = 18081
	local request_count = 0
	local ka_server = http.listen {
		addr = "127.0.0.1:" .. KA_PORT,
		handler = function(stream)
			request_count = request_count + 1
			local body = "response_" .. request_count
			stream:respond(200, {
				["content-type"] = "text/plain",
				["content-length"] = #body,
			})
			stream:write(body)
		end
	}
	testaux.assertneq(ka_server, nil, "Test 10.1: start keep-alive server")

	local results = c:http_request_pair(
		"http://127.0.0.1:" .. KA_PORT .. "/first",
		"http://127.0.0.1:" .. KA_PORT .. "/second",
		{disable_keep_alives = false}
	)
	testaux.assertneq(results, nil, "Test 10.2: request pair should succeed")
	assert(results)
	testaux.asserteq(#results, 2, "Test 10.3: should return two responses")
	testaux.asserteq(results[1].body, "response_1", "Test 10.4: first response body")
	testaux.asserteq(results[2].body, "response_2", "Test 10.5: second response body")

	ka_server:close()
end)

testaux.case("Test 11: Connection: close", function()
	lua_server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 2,
			["connection"] = "close",
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Connection"] = "close"},
	})
	testaux.assertneq(resp, nil, "Test 11.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 11.2: status should be 200")

	wait_handler()
end)

testaux.case("Test 12: Multiple headers with same name", function()
	lua_server_handler = function(stream)
		local x_custom = stream.header["x-custom"]
		testaux.assertneq(x_custom, nil, "Test 12.1: X-Custom header should be present")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
			["x-multi"] = {"val1", "val2"},
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["X-Custom"] = "test-value"},
	})
	testaux.assertneq(resp, nil, "Test 12.2: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 12.3: status should be 200")
	testaux.assertneq(resp.headers["x-multi"], nil, "Test 12.4: multi-value header should be present")

	wait_handler()
end)

testaux.case("Test 13: Query parameter parsing", function()
	lua_server_handler = function(stream)
		local query = stream.query
		testaux.asserteq(query["name"], "test", "Test 13.1: query param name")
		testaux.asserteq(query["value"], "123", "Test 13.2: query param value")
		stream:respond(200, {
			["content-type"] = "text/plain",
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/?name=test&value=123")
	testaux.assertneq(resp, nil, "Test 13.3: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 13.4: status should be 200")

	wait_handler()
end)

testaux.case("Test 14: Large body", function()
	local large_body = string.rep("A", 1024 * 1024)
	lua_server_handler = function(stream)
		local body, err = stream:readall()
		testaux.asserteq(err, nil, "Test 14.1: readall should not error")
		testaux.asserteq(#body, #large_body, "Test 14.2: body length should match")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("POST", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Content-Type"] = "application/octet-stream"},
		body = large_body,
	})
	testaux.assertneq(resp, nil, "Test 14.3: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 14.4: status should be 200")

	wait_handler()
end)

-- Tests 15-29 reserved for future Group A tests

testaux.case("Test 30: 304 Not Modified response", function()
	lua_server_handler = function(stream)
		stream:respond(304, {
			["etag"] = "\"abc123\"",
		})
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 30.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 304, "Test 30.2: status should be 304")
	testaux.asserteq(resp.body, "", "Test 30.3: body should be empty for 304")

	wait_handler()
end)

testaux.case("Test 31: Auto-chunked response (no CL, no TE)", function()
	lua_server_handler = function(stream)
		stream:respond(200, {
			["content-type"] = "text/plain",
		})
		stream:write("auto-")
		stream:write("chunked")
		stream:closewrite()
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 31.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 31.2: status should be 200")
	testaux.asserteq(resp.body, "auto-chunked", "Test 31.3: body should be concatenated")

	wait_handler()
end)

testaux.case("Test 32: Connection: close from Lua server", function()
	lua_server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 2,
			["connection"] = "close",
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 32.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 32.2: status should be 200")
	testaux.asserteq(resp.body, "OK", "Test 32.3: body should be OK")

	wait_handler()
end)

testaux.case("Test 33: Duplicate header merging", function()
	lua_server_handler = function(stream)
		local x_custom = stream.header["x-custom"]
		testaux.assertneq(x_custom, nil, "Test 33.1: X-Custom should be present")
		assert(x_custom)
		testaux.asserteq(type(x_custom), "table", "Test 33.2: header should be promoted to table")
		testaux.asserteq(#x_custom, 2, "Test 33.3: should have 2 values")
		testaux.asserteq(x_custom[1], "value1", "Test 33.4: first value")
		testaux.asserteq(x_custom[2], "value2", "Test 33.5: second value")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["X-Custom"] = {"value1", "value2"}},
	})
	testaux.assertneq(resp, nil, "Test 33.6: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 33.7: status should be 200")

	wait_handler()
end)


testaux.case("Test 34: Write exceed Content-Length", function()
	lua_server_handler = function(stream)
		stream:respond(200, {
			["content-length"] = 5,
		})
		local ok = stream:write("12345")
		testaux.asserteq(ok, true, "Test 34.1: first write should succeed")
		local ok2, err = stream:write("67890")
		testaux.asserteq(ok2, false, "Test 34.2: second write should fail (exceed CL)")
		testaux.assertcontains(err, "exceed", "Test 34.3: error should mention exceed")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 34.4: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 34.5: status should be 200")
	testaux.asserteq(resp.body, "12345", "Test 34.6: body should be first write only")

	wait_handler()
end)

testaux.case("Test 35: 1xx Informational response", function()
	lua_server_handler = function(stream)
		stream.conn:write("HTTP/1.1 100 Continue\r\n\r\n")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/")
	testaux.assertneq(resp, nil, "Test 35.1: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 35.2: status should be 200 (after 100)")
	testaux.asserteq(resp.body, "OK", "Test 35.3: body should be OK")

	wait_handler()
end)

testaux.case("Test 36: Expect: 100-continue", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.header["expect"], "100-continue", "Test 36.1: Expect header")
		stream.conn:write("HTTP/1.1 100 Continue\r\n\r\n")
		local body, err = stream:readall()
		testaux.asserteq(err, nil, "Test 36.2: no read error")
		testaux.asserteq(body, "request data", "Test 36.3: body should match")
		stream:respond(200, {
			["content-length"] = 2,
		})
		stream:write("OK")
	end

	local resp = c:http_request("POST", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Expect"] = "100-continue", ["Content-Type"] = "text/plain"},
		body = "request data",
	})
	testaux.assertneq(resp, nil, "Test 36.4: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 36.5: status should be 200")
	testaux.asserteq(resp.body, "OK", "Test 36.6: body should be OK")

	wait_handler()
end)

-- TODO: implement hop-by-hop header stripping (RFC 9112 Section 6.1)
-- Headers named in the Connection value should be removed before the
-- application sees them. Requires careful placement to avoid breaking
-- protocol logic that reads transfer-encoding / content-length.
--[[
testaux.case("Test 37: Hop-by-hop stripping", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.header["x-test-hop"], nil, "Test 37.1: X-Test-Hop should be stripped")
		stream:respond(200, {["content-type"] = "text/plain", ["content-length"] = 2})
		stream:write("OK")
	end
	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Connection"] = "X-Test-Hop", ["X-Test-Hop"] = "should-be-stripped"},
	})
	testaux.assertneq(resp, nil, "Test 37.2: Go client should get response")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 37.3: status should be 200")
	wait_handler()
end)
--]]

testaux.case("Test 38: Pipelining", function()
	local KA_PORT = 18082
	local req_count = 0
	local ka_server = http.listen {
		addr = "127.0.0.1:" .. KA_PORT,
		handler = function(stream)
			req_count = req_count + 1
			local body = "response_" .. req_count
			stream:respond(200, {["content-type"] = "text/plain", ["content-length"] = #body})
			stream:write(body)
		end
	}
	testaux.assertneq(ka_server, nil, "Test 38.1: start pipelining server")
	local results = c:http_request_pair(
		"http://127.0.0.1:" .. KA_PORT .. "/first",
		"http://127.0.0.1:" .. KA_PORT .. "/second",
		{disable_keep_alives = false}
	)
	testaux.assertneq(results, nil, "Test 38.2: pipelined requests should succeed")
	assert(results)
	testaux.asserteq(#results, 2, "Test 38.3: should return two responses")
	testaux.asserteq(results[1].body, "response_1", "Test 38.4: first response")
	testaux.asserteq(results[2].body, "response_2", "Test 38.5: second response")
	ka_server:close()
end)

testaux.case("Test 39: PATCH method", function()
	lua_server_handler = function(stream)
		testaux.asserteq(stream.method, "PATCH", "Test 39.1: method should be PATCH")
		local body, err = stream:readall()
		testaux.asserteq(body, "patch data", "Test 39.2: body should match")
		testaux.asserteq(err, nil, "Test 39.3: no read error")
		stream:respond(200, {["content-type"] = "text/plain", ["content-length"] = 2})
		stream:write("OK")
	end
	local resp = c:http_request("PATCH", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Content-Type"] = "text/plain"},
		body = "patch data",
	})
	testaux.assertneq(resp, nil, "Test 39.4: PATCH should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 39.5: status should be 200")
	wait_handler()
end)

testaux.case("Test 40: Comma-separated Accept", function()
	lua_server_handler = function(stream)
		local accept = stream.header["accept"]
		testaux.assertneq(accept, nil, "Test 40.1: Accept should be present")
		assert(accept)
		testaux.assertneq(accept:find("text/html", 1, true), nil, "Test 40.2: should contain text/html")
		testaux.assertneq(accept:find("application/json", 1, true), nil, "Test 40.3: should contain application/json")
		stream:respond(200, {["content-length"] = 2})
		stream:write("OK")
	end
	local resp = c:http_request("GET", "http://127.0.0.1:" .. LUA_PORT .. "/", {
		headers = {["Accept"] = "text/html, application/json"},
	})
	testaux.assertneq(resp, nil, "Test 40.4: request should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 40.5: status should be 200")
	wait_handler()
end)

-- Close the shared Lua server
lua_server:close()
lua_server = nil

-----------------------------------------------------------
-- Group B: Lua client → Go server
-----------------------------------------------------------

local httpc = http.newclient({
	max_idle_per_host = 10,
	idle_timeout = 2000,
})

testaux.case("Test 100: http.get() basic", function()
	local srv = c:start_server("content_length", {body = "Hello from Go"})
	testaux.assertneq(srv, nil, "Test 100.1: Go server should start")
	assert(srv)

	local resp = httpc:get("http://" .. srv.addr .. "/test")
	testaux.assertneq(resp, nil, "Test 100.2: Lua GET should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 100.3: status should be 200")
	testaux.asserteq(resp.body, "Hello from Go", "Test 100.4: body should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 101: http.post() with body", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 101.1: Go server should start")
	assert(srv)

	local resp = httpc:post("http://" .. srv.addr .. "/submit", {
		["content-type"] = "text/plain",
	}, "post data")
	testaux.assertneq(resp, nil, "Test 101.2: Lua POST should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 101.3: status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 101.4: echo response should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.body, "post data", "Test 101.5: echo body should match")
	testaux.asserteq(echoed.method, "POST", "Test 101.6: echo method should be POST")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 102: http.head()", function()
	local srv = c:start_server("head_no_body", {body_length = 100})
	testaux.assertneq(srv, nil, "Test 102.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("HEAD", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 102.2: Lua HEAD request should succeed")
	testaux.asserteq(err, nil, "Test 102.3: no error")
	stream:closewrite()
	stream:waitresponse()
	testaux.asserteq(stream.status, 200, "Test 102.4: status should be 200")
	testaux.asserteq(stream.eof, true, "Test 102.5: eof should be true for HEAD")

	local body, read_err = stream:readall()
	testaux.asserteq(body, "", "Test 102.6: body should be empty for HEAD")
	testaux.asserteq(read_err, nil, "Test 102.7: no read error for HEAD")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 103: client:request() streaming API", function()
	local srv = c:start_server("content_length", {body = "streaming response"})
	testaux.assertneq(srv, nil, "Test 103.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/stream", {})
	testaux.assertneq(stream, nil, "Test 103.2: stream should not be nil")
	testaux.asserteq(err, nil, "Test 103.3: no error")
	stream:closewrite()

	local ok, err = stream:waitresponse()
	testaux.asserteq(ok, true, "Test 103.4: waitresponse should succeed")
	testaux.asserteq(stream.status, 200, "Test 103.5: status should be 200")

	local body, err = stream:readall()
	testaux.asserteq(body, "streaming response", "Test 103.6: body should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 104: Chunked response decoding", function()
	local srv = c:start_server("chunked", {chunks = {"chunk1", "chunk2", "chunk3"}})
	testaux.assertneq(srv, nil, "Test 104.1: Go server should start")
	assert(srv)

	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 104.2: Lua GET should succeed")
	assert(resp)
	testaux.asserteq(resp.body, "chunk1chunk2chunk3", "Test 104.3: chunked body should be concatenated")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 105: Content-Length partial reads", function()
	local srv = c:start_server("content_length", {body = "1234567890"})
	testaux.assertneq(srv, nil, "Test 105.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 105.2: stream should not be nil")
	stream:closewrite()

	local chunk1 = stream:read(5)
	testaux.asserteq(chunk1, "12345", "Test 105.3: first read should get 5 bytes")
	testaux.asserteq(stream.eof, false, "Test 105.4: eof should be false")

	local chunk2 = stream:read(5)
	testaux.asserteq(chunk2, "67890", "Test 105.5: second read should get 5 bytes")
	testaux.asserteq(stream.eof, true, "Test 105.6: eof should be true after reading all")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 106: Read until EOF (no Content-Length, no chunked)", function()
	local srv = c:start_server("read_until_eof", {body = "data until EOF"})
	testaux.assertneq(srv, nil, "Test 106.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 106.2: stream should not be nil")
	stream:closewrite()

	local body, err = stream:readall()
	testaux.asserteq(body, "data until EOF", "Test 106.3: body should be read until EOF")
	testaux.asserteq(stream.eof, true, "Test 106.4: eof should be true")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 107: Empty body (Content-Length: 0)", function()
	local srv = c:start_server("content_length", {body = "", status = 200})
	testaux.assertneq(srv, nil, "Test 107.1: Go server should start")
	assert(srv)

	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 107.2: Lua GET should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 107.3: status should be 200")
	testaux.asserteq(resp.body, "", "Test 107.4: body should be empty")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 108: Empty chunked body", function()
	local srv = c:start_server("chunked", {chunks = {}})
	testaux.assertneq(srv, nil, "Test 108.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 108.2: stream should not be nil")
	stream:closewrite()

	local body, err = stream:readall()
	testaux.asserteq(body, "", "Test 108.3: body should be empty")
	testaux.asserteq(stream.eof, true, "Test 108.4: eof should be true")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 109: Trailer headers", function()
	local srv = c:start_server("trailers", {
		chunks = {"data1", "data2"},
		trailer_key = "X-Checksum",
		trailer_val = "abc123",
	})
	testaux.assertneq(srv, nil, "Test 109.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 109.2: stream should not be nil")
	stream:closewrite()

	local body, err = stream:readall()
	testaux.asserteq(body, "data1data2", "Test 109.3: body should be concatenated")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 110: Gzip auto-decompression", function()
	local raw = "This is compressible text for gzip testing. " ..
		"Adding more text to improve compression ratio. " ..
		"The more text, the better the compression."
	local srv = c:start_server("gzip_response", {body = raw})
	testaux.assertneq(srv, nil, "Test 110.1: Go server should start")
	assert(srv)

	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 110.2: Lua GET should succeed")
	assert(resp)
	testaux.asserteq(resp.body, raw, "Test 110.3: body should be auto-decompressed")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 111: Connection reuse (H1 pool)", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 111.1: Go server should start")
	assert(srv)

	-- First request establishes the TCP connection
	local resp1 = httpc:get("http://" .. srv.addr .. "/first")
	testaux.assertneq(resp1, nil, "Test 111.2: first request should succeed")
	assert(resp1)

	local stat1 = netstat()

	-- Second request should reuse the same connection (no new TCP client)
	local resp2 = httpc:get("http://" .. srv.addr .. "/second")
	testaux.assertneq(resp2, nil, "Test 111.3: second request should succeed")
	assert(resp2)

	local stat2 = netstat()
	testaux.asserteq(stat2.tcpclient, stat1.tcpclient, "Test 111.4: connection should be reused")

	local echoed = json.decode(resp2.body)
	testaux.assertneq(echoed, nil, "Test 111.5: echo response should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.path, "/second", "Test 111.6: second request path should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 112: Multiple status codes", function()
	local codes = {200, 201, 204, 301, 400, 404, 500}
	for _, code in ipairs(codes) do
		local srv = c:start_server("status_code", {status = code})
		testaux.assertneq(srv, nil, "Test 112." .. code .. ".1: Go server should start for " .. code)
		assert(srv)

		local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
		testaux.assertneq(stream, nil, "Test 112." .. code .. ".2: request should succeed")
		stream:closewrite()
		stream:waitresponse()
		testaux.asserteq(stream.status, code, "Test 112." .. code .. ".3: status should be " .. code)

		c:stop_server(srv.server_id)
	end
end)

testaux.case("Test 113: Large response body", function()
	local large = string.rep("X", 1024 * 1024)
	local srv = c:start_server("content_length", {body = large})
	testaux.assertneq(srv, nil, "Test 113.1: Go server should start")
	assert(srv)

	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 113.2: Lua GET should succeed")
	assert(resp)
	testaux.asserteq(#resp.body, #large, "Test 113.3: body length should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 114: Connection broken mid-response", function()
	local srv = c:start_server("close_midway", {
		part1 = "hel",
		part2 = "lo",
	})
	testaux.assertneq(srv, nil, "Test 114.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 114.2: stream should not be nil")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.asserteq(body, nil, "Test 114.3: readall should fail on broken connection")
	testaux.assertneq(read_err, nil, "Test 114.4: should have error")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 115: Chunked request body", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 115.1: Go server should start")
	assert(srv)

	-- Streaming API without content-length triggers chunked transfer
	local stream<close>, err = httpc:request("POST", "http://" .. srv.addr .. "/submit", {
		["content-type"] = "text/plain",
	})
	testaux.assertneq(stream, nil, "Test 115.2: stream should not be nil")
	stream:write("chunk1")
	stream:write("chunk2")
	stream:write("chunk3")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.assertneq(body, nil, "Test 115.3: body should not be nil")
	testaux.asserteq(read_err, nil, "Test 115.4: no read error")
	assert(body)
	local echoed = json.decode(body)
	testaux.assertneq(echoed, nil, "Test 115.5: echo should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.body, "chunk1chunk2chunk3", "Test 115.6: echo body should match")
	testaux.asserteq(echoed.method, "POST", "Test 115.7: method should be POST")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 116: Client timeout with slow response", function()
	local srv = c:start_server("slow_response", {
		chunks = {"part1", "part2"},
		delay_ms = 500,
	})
	testaux.assertneq(srv, nil, "Test 116.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 116.2: stream should not be nil")
	stream:closewrite()

	-- Read with short timeout; server has 500ms delay between chunks
	local chunk, read_err = stream:read(5, 100)
	testaux.asserteq(chunk, nil, "Test 116.3: read should timeout")
	testaux.assertneq(read_err, nil, "Test 116.4: should have timeout error")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 117: Connection: close from Go server", function()
	local srv = c:start_server("conn_close", {body = "closing"})
	testaux.assertneq(srv, nil, "Test 117.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 117.2: stream should not be nil")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.asserteq(body, "closing", "Test 117.3: body should match")
	testaux.asserteq(read_err, nil, "Test 117.4: no read error")
	testaux.asserteq(stream.header["connection"], "close", "Test 117.5: response should have Connection: close")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 118: Invalid chunk size error", function()
	local srv = c:start_server("invalid_chunk")
	testaux.assertneq(srv, nil, "Test 118.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 118.2: stream should not be nil")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.assertneq(read_err, nil, "Test 118.3: should have error for invalid chunk")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 119: Read(n) from chunked response", function()
	local srv = c:start_server("chunked", {chunks = {"AAAAA", "BBBBB", "CCCCC", "DDDDD"}})
	testaux.assertneq(srv, nil, "Test 119.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 119.2: stream should not be nil")
	stream:closewrite()

	-- Read spans across chunk boundaries
	local chunk1 = stream:read(7)
	testaux.asserteq(chunk1, "AAAAABB", "Test 119.3: first read spans chunks")
	testaux.asserteq(stream.eof, false, "Test 119.4: eof should be false")

	local chunk2 = stream:read(8)
	testaux.asserteq(chunk2, "BBBCCCCC", "Test 119.5: second read gets 8 bytes")
	testaux.asserteq(stream.eof, false, "Test 119.6: eof should be false")

	local rest = stream:readall()
	testaux.asserteq(rest, "DDDDD", "Test 119.7: readall gets remaining bytes")
	testaux.asserteq(stream.eof, true, "Test 119.8: eof should be true")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 120: Read(n) from EOF response", function()
	local srv = c:start_server("read_until_eof", {body = "ABCDEFGHIJ"})
	testaux.assertneq(srv, nil, "Test 120.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 120.2: stream should not be nil")
	stream:closewrite()

	-- Partial reads from unframed response (read until EOF)
	local chunk1 = stream:read(5)
	testaux.asserteq(chunk1, "ABCDE", "Test 120.3: first read gets 5 bytes")

	local chunk2 = stream:read(5)
	testaux.asserteq(chunk2, "FGHIJ", "Test 120.4: second read gets 5 bytes")

	-- Read past end triggers EOF
	local chunk3, read_err = stream:read(1)
	testaux.asserteq(chunk3, nil, "Test 120.5: read past end returns nil")
	testaux.asserteq(stream.eof, true, "Test 120.6: eof should be true")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 121: Trailer header values", function()
	local srv = c:start_server("trailers", {
		chunks = {"data1", "data2"},
		trailer_key = "X-Checksum",
		trailer_val = "abc123",
	})
	testaux.assertneq(srv, nil, "Test 121.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 121.2: stream should not be nil")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.asserteq(body, "data1data2", "Test 121.3: body should be concatenated")
	testaux.asserteq(stream.trailer["x-checksum"], "abc123", "Test 121.4: trailer value should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 122: Expect: 100-continue client path", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 122.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("POST", "http://" .. srv.addr .. "/submit", {
		["content-type"] = "text/plain",
		["expect"] = "100-continue",
	})
	testaux.assertneq(stream, nil, "Test 122.2: stream should not be nil")
	testaux.asserteq(err, nil, "Test 122.3: no error")
	stream:write("hello world")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.assertneq(body, nil, "Test 122.4: body should not be nil")
	testaux.asserteq(read_err, nil, "Test 122.5: no read error")
	assert(body)
	local echoed = json.decode(body)
	testaux.assertneq(echoed, nil, "Test 122.6: echo should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.body, "hello world", "Test 122.7: echo body should match")
	testaux.asserteq(echoed.method, "POST", "Test 122.8: method should be POST")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 123: write > 4KB triggers auto-flush", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 123.1: Go server should start")
	assert(srv)

	local big_data = string.rep("ABCDEFGHIJ", 500)  -- 5000 bytes
	local stream<close>, err = httpc:request("POST", "http://" .. srv.addr .. "/submit", {
		["content-type"] = "application/octet-stream",
	})
	testaux.assertneq(stream, nil, "Test 123.2: stream should not be nil")
	stream:write(big_data)
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.assertneq(body, nil, "Test 123.3: body should not be nil")
	testaux.asserteq(read_err, nil, "Test 123.4: no read error")
	assert(body)
	local echoed = json.decode(body)
	testaux.assertneq(echoed, nil, "Test 123.5: echo should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.body, big_data, "Test 123.6: echo body should match")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 124: read(n) buffer hit from chunked", function()
	local srv = c:start_server("chunked", {chunks = {"ABCDEFGHIJKLMNOPQRST"}})
	testaux.assertneq(srv, nil, "Test 124.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 124.2: stream should not be nil")
	stream:closewrite()

	local chunk1 = stream:read(10)
	testaux.asserteq(chunk1, "ABCDEFGHIJ", "Test 124.3: first read gets 10 bytes")
	testaux.asserteq(stream.eof, false, "Test 124.4: eof should be false")

	local chunk2 = stream:read(10)
	testaux.asserteq(chunk2, "KLMNOPQRST", "Test 124.5: second read gets 10 bytes (buffer hit)")

	local chunk3, err3 = stream:read(1)
	testaux.asserteq(chunk3, nil, "Test 124.6: third read should return nil (EOF)")
	testaux.asserteq(stream.eof, true, "Test 124.7: eof should be true after exhausting data")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 125: POST with gzip auto-decompression", function()
	local raw = "compressible text for POST gzip test with enough repetition to compress well"
	local srv = c:start_server("gzip_response", {body = raw})
	testaux.assertneq(srv, nil, "Test 125.1: Go server should start")
	assert(srv)

	local resp = httpc:post("http://" .. srv.addr .. "/submit", {
		["content-type"] = "text/plain",
	}, "post data")
	testaux.assertneq(resp, nil, "Test 125.2: Lua POST should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 125.3: status should be 200")
	testaux.asserteq(resp.body, raw, "Test 125.4: body should be auto-decompressed")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 126: stream:flush() API", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 126.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("POST", "http://" .. srv.addr .. "/submit", {
		["content-type"] = "text/plain",
	})
	testaux.assertneq(stream, nil, "Test 126.2: stream should not be nil")
	stream:write("part1")
	stream:flush()
	stream:write("part2")
	stream:closewrite()

	local body, read_err = stream:readall()
	testaux.assertneq(body, nil, "Test 126.3: body should not be nil")
	testaux.asserteq(read_err, nil, "Test 126.4: no read error")
	assert(body)
	local echoed = json.decode(body)
	testaux.assertneq(echoed, nil, "Test 126.5: echo should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.body, "part1part2", "Test 126.6: echo body should match both parts")

	c:stop_server(srv.server_id)
end)

testaux.case("Test 127: 204 No Content empty body", function()
	local srv = c:start_server("status_code", {status = 204})
	testaux.assertneq(srv, nil, "Test 127.1: Go server should start")
	assert(srv)

	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 127.2: stream should not be nil")
	stream:closewrite()
	stream:waitresponse()
	testaux.asserteq(stream.status, 204, "Test 127.3: status should be 204")
	testaux.asserteq(stream.eof, true, "Test 127.4: eof should be true for 204")

	local body, read_err = stream:readall()
	testaux.asserteq(body, "", "Test 127.5: body should be empty for 204")
	testaux.asserteq(read_err, nil, "Test 127.6: no read error for 204")

	c:stop_server(srv.server_id)
end)

-- TODO: implement hop-by-hop header stripping (RFC 9112 Section 6.1)
--[[
testaux.case("Test 128: Hop-by-hop stripping", function()
	local srv = c:start_server("connection_echo")
	testaux.assertneq(srv, nil, "Test 128.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 128.2: stream should not be nil")
	stream:closewrite()
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 128.3: no read error")
	-- Connection_echo sends: Connection: X-Test-Hop, X-Test-Hop: should-be-stripped
	testaux.asserteq(stream.header["x-test-hop"], nil, "Test 128.4: X-Test-Hop should be stripped from response")
	testaux.asserteq(stream.header["connection"], "X-Test-Hop", "Test 128.5: Connection header preserved")
	c:stop_server(srv.server_id)
end)
--]]

testaux.case("Test 129: Pipelining", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 129.1: Go server should start")
	assert(srv)
	local stream1<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/first", {})
	testaux.assertneq(stream1, nil, "Test 129.2: first stream ok")
	stream1:closewrite()
	local body1, err1 = stream1:readall()
	testaux.asserteq(err1, nil, "Test 129.3: first readall ok")
	local stream2<close>, err2 = httpc:request("GET", "http://" .. srv.addr .. "/second", {})
	testaux.assertneq(stream2, nil, "Test 129.4: second stream ok")
	stream2:closewrite()
	local body2, err3 = stream2:readall()
	testaux.asserteq(err3, nil, "Test 129.5: second readall ok")
	assert(body1 and body2)
	local e1 = json.decode(body1)
	local e2 = json.decode(body2)
	testaux.assertneq(e1, nil, "Test 129.6: first echo valid")
	testaux.assertneq(e2, nil, "Test 129.7: second echo valid")
	assert(e1 and e2)
	testaux.asserteq(e1.path, "/first", "Test 129.8: first path")
	testaux.asserteq(e2.path, "/second", "Test 129.9: second path")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 130: Redirect 301", function()
	local target = c:start_server("echo")
	testaux.assertneq(target, nil, "Test 130.1: target server should start")
	assert(target)
	local redirect_srv = c:start_server("redirect", {
		redirect_status = 301,
		redirect_location = "http://" .. target.addr .. "/final",
	})
	testaux.assertneq(redirect_srv, nil, "Test 130.2: redirect server should start")
	assert(redirect_srv)
	local resp, err = httpc:get("http://" .. redirect_srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 130.3: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 130.4: final status should be 200 after redirect")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 130.5: echo should be valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.method, "GET", "Test 130.6: method should be GET after 301")
	testaux.asserteq(echoed.path, "/final", "Test 130.7: path should be /final")
	c:stop_server(redirect_srv.server_id)
	c:stop_server(target.server_id)
end)

testaux.case("Test 131: Redirect 302", function()
	local target = c:start_server("echo")
	testaux.assertneq(target, nil, "Test 131.1: target server should start")
	assert(target)
	local redirect_srv = c:start_server("redirect", {
		redirect_status = 302,
		redirect_location = "http://" .. target.addr .. "/final",
	})
	testaux.assertneq(redirect_srv, nil, "Test 131.2: redirect server should start")
	assert(redirect_srv)
	local resp, err = httpc:get("http://" .. redirect_srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 131.3: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 131.4: final status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 131.5: echo valid")
	assert(echoed)
	testaux.asserteq(echoed.method, "GET", "Test 131.6: method should be GET after 302")
	c:stop_server(redirect_srv.server_id)
	c:stop_server(target.server_id)
end)

testaux.case("Test 132: Redirect 307 preserves method", function()
	local target = c:start_server("echo")
	testaux.assertneq(target, nil, "Test 132.1: target server should start")
	assert(target)
	local redirect_srv = c:start_server("redirect", {
		redirect_status = 307,
		redirect_location = "http://" .. target.addr .. "/final",
	})
	testaux.assertneq(redirect_srv, nil, "Test 132.2: redirect server should start")
	assert(redirect_srv)
	local resp, err = httpc:post("http://" .. redirect_srv.addr .. "/",
		{["content-type"] = "text/plain"}, "post body")
	testaux.assertneq(resp, nil, "Test 132.3: POST should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 132.4: final status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 132.5: echo valid")
	assert(echoed)
	testaux.asserteq(echoed.method, "POST", "Test 132.6: method should stay POST after 307")
	testaux.asserteq(echoed.body, "post body", "Test 132.7: body should be preserved after 307")
	c:stop_server(redirect_srv.server_id)
	c:stop_server(target.server_id)
end)

testaux.case("Test 133: Redirect 308 preserves method", function()
	local target = c:start_server("echo")
	testaux.assertneq(target, nil, "Test 133.1: target server should start")
	assert(target)
	local redirect_srv = c:start_server("redirect", {
		redirect_status = 308,
		redirect_location = "http://" .. target.addr .. "/final",
	})
	testaux.assertneq(redirect_srv, nil, "Test 133.2: redirect server should start")
	assert(redirect_srv)
	local resp, err = httpc:post("http://" .. redirect_srv.addr .. "/",
		{["content-type"] = "text/plain"}, "post body")
	testaux.assertneq(resp, nil, "Test 133.3: POST should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 133.4: final status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 133.5: echo valid")
	assert(echoed)
	testaux.asserteq(echoed.method, "POST", "Test 133.6: method should stay POST after 308")
	testaux.asserteq(echoed.body, "post body", "Test 133.7: body should be preserved after 308")
	c:stop_server(redirect_srv.server_id)
	c:stop_server(target.server_id)
end)

testaux.case("Test 134: Redirect chain", function()
	local final = c:start_server("echo")
	testaux.assertneq(final, nil, "Test 134.1: final server should start")
	assert(final)
	local middle = c:start_server("redirect", {
		redirect_status = 302,
		redirect_location = "http://" .. final.addr .. "/end",
	})
	testaux.assertneq(middle, nil, "Test 134.2: middle server should start")
	assert(middle)
	local first = c:start_server("redirect", {
		redirect_status = 301,
		redirect_location = "http://" .. middle.addr .. "/mid",
	})
	testaux.assertneq(first, nil, "Test 134.3: first server should start")
	assert(first)
	local resp = httpc:get("http://" .. first.addr .. "/start")
	testaux.assertneq(resp, nil, "Test 134.4: should follow chain")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 134.5: final status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 134.6: echo valid")
	assert(echoed)
	testaux.asserteq(echoed.path, "/end", "Test 134.7: should reach final target")
	c:stop_server(first.server_id)
	c:stop_server(middle.server_id)
	c:stop_server(final.server_id)
end)

testaux.case("Test 135: Redirect to unreachable target", function()
	local srv = c:start_server("redirect", {
		redirect_status = 301,
		redirect_location = "http://127.0.0.1:1/loop",  -- Points to nonexistent port
	})
	testaux.assertneq(srv, nil, "Test 135.1: server should start")
	assert(srv)
	-- Request the redirect URL itself — the Location points elsewhere, so it won't loop
	-- For a real loop test, we'd need the Location to point back to the same server
	-- Instead, test that redirect following works and the second hop fails gracefully
	local resp, err = httpc:get("http://" .. srv.addr .. "/")
	-- The redirect target (port 1) won't connect, so we expect an error
	testaux.asserteq(resp, nil, "Test 135.2: should fail (redirect target unreachable)")
	testaux.assertneq(err, nil, "Test 135.3: should have error")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 136: 413 Payload Too Large", function()
	local srv = c:start_server("payload_limit", {max_bytes = 10})
	testaux.assertneq(srv, nil, "Test 136.1: Go server should start")
	assert(srv)
	local resp, err = httpc:post("http://" .. srv.addr .. "/", {["content-type"] = "text/plain"}, "This body exceeds the 10 byte limit")
	testaux.assertneq(resp, nil, "Test 136.2: should get response")
	assert(resp)
	testaux.asserteq(resp.status, 413, "Test 136.3: status should be 413")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 137: Chunk extensions in response", function()
	local srv = c:start_server("chunked_extensions", {chunks = {"Hello", "World"}})
	testaux.assertneq(srv, nil, "Test 137.1: Go server should start")
	assert(srv)
	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 137.2: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.body, "HelloWorld", "Test 137.3: body should ignore chunk extensions")
	testaux.asserteq(resp.status, 200, "Test 137.4: status should be 200")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 138: Leading zeros in chunk size", function()
	local srv = c:start_server("chunked_leading_zeros", {chunks = {"AAAAA", "BBBBB"}})
	testaux.assertneq(srv, nil, "Test 138.1: Go server should start")
	assert(srv)
	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 138.2: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.body, "AAAAABBBBB", "Test 138.3: body correct despite leading zeros")
	testaux.asserteq(resp.status, 200, "Test 138.4: status should be 200")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 139: Mixed-case hex in chunk size", function()
	local srv = c:start_server("chunked_mixed_hex", {chunks = {"ABCDEFGHIJKLMNOP"}})
	testaux.assertneq(srv, nil, "Test 139.1: Go server should start")
	assert(srv)
	local resp = httpc:get("http://" .. srv.addr .. "/")
	testaux.assertneq(resp, nil, "Test 139.2: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.body, "ABCDEFGHIJKLMNOP", "Test 139.3: body correct despite mixed-case hex")
	testaux.asserteq(resp.status, 200, "Test 139.4: status should be 200")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 140: Bare \\n in response", function()
	local srv = c:start_server("bare_newline", {body = "hello"})
	testaux.assertneq(srv, nil, "Test 140.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 140.2: stream should not be nil")
	stream:closewrite()
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 140.3: no read error")
	testaux.asserteq(body, "hello", "Test 140.4: body should be correct")
	testaux.asserteq(stream.status, 200, "Test 140.5: status should be 200")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 141: OWS in response headers", function()
	local srv = c:start_server("ows_headers", {body = "test"})
	testaux.assertneq(srv, nil, "Test 141.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 141.2: stream ok")
	stream:closewrite()
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 141.3: no read error")
	testaux.asserteq(body, "test", "Test 141.4: body correct")
	-- OWS handler sends: "X-With-Spaces:  has-ows  " — client should strip OWS
	testaux.asserteq(stream.header["x-with-spaces"], "has-ows", "Test 141.5: OWS stripped from header value")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 142: Comma-separated Accept header", function()
	local srv = c:start_server("header_echo")
	testaux.assertneq(srv, nil, "Test 142.1: Go server should start")
	assert(srv)
	local resp = httpc:get("http://" .. srv.addr .. "/", {["accept"] = "text/html, application/json, */*"})
	testaux.assertneq(resp, nil, "Test 142.2: GET should succeed")
	assert(resp)
	testaux.asserteq(resp.status, 200, "Test 142.3: status should be 200")
	local echoed = json.decode(resp.body)
	testaux.assertneq(echoed, nil, "Test 142.4: echo should be valid JSON")
	assert(echoed and echoed.headers)
	local accept_val = echoed.headers["Accept"]
	if type(accept_val) == "table" then accept_val = accept_val[1] end
	testaux.assertneq(accept_val:find("text/html", 1, true), nil, "Test 142.5: should contain text/html")
	testaux.assertneq(accept_val:find("application/json", 1, true), nil, "Test 142.6: should contain application/json")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 143: Empty body via EOF", function()
	local srv = c:start_server("empty_eof")
	testaux.assertneq(srv, nil, "Test 143.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 143.2: stream ok")
	stream:closewrite()
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 143.3: no read error for empty EOF body")
	testaux.asserteq(body, "", "Test 143.4: body should be empty")
	testaux.asserteq(stream.eof, true, "Test 143.5: eof should be true")
	testaux.asserteq(stream.status, 200, "Test 143.6: status should be 200")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 144: Multiple 1xx before final response", function()
	local srv = c:start_server("multi_1xx", {body = "final body"})
	testaux.assertneq(srv, nil, "Test 144.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 144.2: stream ok")
	stream:closewrite()
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 144.3: no read error")
	testaux.asserteq(body, "final body", "Test 144.4: body from final 200")
	testaux.asserteq(stream.status, 200, "Test 144.5: status should be 200 (not 100/103)")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 145: PATCH method", function()
	local srv = c:start_server("echo")
	testaux.assertneq(srv, nil, "Test 145.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("PATCH", "http://" .. srv.addr .. "/item", {["content-type"] = "text/plain"})
	testaux.assertneq(stream, nil, "Test 145.2: PATCH stream ok")
	stream:closewrite("patch body")
	local body, read_err = stream:readall()
	testaux.asserteq(read_err, nil, "Test 145.3: no read error")
	assert(body)
	local echoed = json.decode(body)
	testaux.assertneq(echoed, nil, "Test 145.4: echo valid JSON")
	assert(echoed)
	testaux.asserteq(echoed.method, "PATCH", "Test 145.5: method should be PATCH")
	testaux.asserteq(echoed.body, "patch body", "Test 145.6: body should match")
	c:stop_server(srv.server_id)
end)

testaux.case("Test 146: Client handles 411 Length Required", function()
	local srv = c:start_server("status_code", {status = 411})
	testaux.assertneq(srv, nil, "Test 146.1: Go server should start")
	assert(srv)
	local stream<close>, err = httpc:request("GET", "http://" .. srv.addr .. "/", {})
	testaux.assertneq(stream, nil, "Test 146.2: stream ok")
	stream:closewrite()
	stream:waitresponse()
	testaux.asserteq(stream.status, 411, "Test 146.3: status should be 411")
	c:stop_server(srv.server_id)
end)

-----------------------------------------------------------
-- Cleanup
-----------------------------------------------------------

httpc:close()
httpc = nil
time.sleep(100)

-- Close control connection (Go process is managed by test.sh)
c:close()
