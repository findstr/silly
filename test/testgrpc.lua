local silly = require "silly"
local pcall = silly.pcall
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"
local protoc = require "protoc"
local grpc = require "silly.net.grpc"
local code = require "silly.net.grpc.code"
local waitgroup = require "silly.sync.waitgroup"
local registrar = require "silly.net.grpc.registrar".new()
local testaux = require "test.testaux"

local _, wait_readers = testaux.trackconnections(tcp)

-- Endpoint address and authority regressions are covered by Test 11 below.
local slow_done = channel.new()
local slow_started = false
local p = protoc:new()

local ok = p:load([[
syntax = "proto3";

package test;

message EchoRequest {
  string message = 1;
  int32 value = 2;
}

message EchoResponse {
  string message = 1;
  int32 value = 2;
}

message StreamRequest {
  int32 count = 1;
}

message StreamResponse {
  int32 index = 1;
  string data = 2;
}

message ErrorRequest {
  int32 error_code = 1;
}

message ErrorResponse {
  string result = 1;
}

service TestService {
  rpc Echo (EchoRequest) returns (EchoResponse) {}
  rpc ServerStream (StreamRequest) returns (stream StreamResponse) {}
  rpc ClientStream (stream EchoRequest) returns (EchoResponse) {}
  rpc BidiStream (stream EchoRequest) returns (stream EchoResponse) {}
  rpc ErrorTest (ErrorRequest) returns (ErrorResponse) {}
  rpc SlowCall (EchoRequest) returns (EchoResponse) {}
  rpc MissingServerStream (EchoRequest) returns (stream EchoResponse) {}
  rpc MissingUnary (EchoRequest) returns (EchoResponse) {}
}
]], "test.proto")

testaux.asserteq(ok, true, "Test 0.1: Protobuf schema should load")

local proto = p.loaded["test.proto"]

registrar:register(proto, "TestService", {
	Echo = function(input)
		return {
			message = "echo: " .. input.message,
			value = input.value * 2
		}
	end,

	ServerStream = function(input, stream)
		for i = 1, input.count do
			local ok, err = stream:write({
				index = i,
				data = "item_" .. i
			})
			if not ok then
				return {code = code.INTERNAL, message = err}
			end
		end
	end,

	ClientStream = function(stream)
		local total = 0
		local messages = {}
		while true do
			local req = stream:read()
			if not req then
				break
			end
			total = total + req.value
			messages[#messages + 1] = req.message
		end
		return {
			message = table.concat(messages, ","),
			value = total
		}
	end,

	BidiStream = function(stream)
		while true do
			local req = stream:read()
			if not req then
				break
			end
			local ok, err = stream:write({
				message = "echo: " .. req.message,
				value = req.value * 2
			})
			if not ok then
				return {code = code.INTERNAL, message = err}
			end
		end
	end,

	ErrorTest = function(input)
		if input.error_code ~= 0 then
			return nil, {
				code = input.error_code,
				message = "test error"
			}
		end
		return {result = "success"}
	end,

	SlowCall = function(input)
		slow_started = true
		-- Application latency is the input to the RPC deadline test.
		testaux.elapse(3000)
		slow_done:push(true)
		return {
			message = "slow: " .. input.message,
			value = input.value
		}
	end,
})

local server_scheme
local echo = registrar.handlers["/test.TestService/Echo"]
registrar.handlers["/test.TestService/Echo"] = function(stream)
	server_scheme = stream.scheme
	return echo(stream)
end

local server = grpc.listen {
	addr = "127.0.0.1:8991",
	registrar = registrar,
}

testaux.assertneq(server, nil, "Test 0.2: Server should start successfully")

local conn = grpc.newclient {
	targets = {"127.0.0.1:8991"},
}

testaux.assertneq(conn, nil, "Test 0.3: Client connection should be created")

local client = grpc.newservice(conn, proto, "TestService")
testaux.assertneq(client, nil, "Test 0.4: Client service should be created")

testaux.case("Test 1: Basic Unary RPC", function()
	local resp, err = client:Echo({
		message = "hello",
		value = 42
	})
	testaux.assertneq(resp, nil, "Test 1.1: Response should not be nil")
	testaux.asserteq(err, nil, "Test 1.2: Error should be nil")
	testaux.asserteq(resp.message, "echo: hello", "Test 1.3: Response message should match")
	testaux.asserteq(resp.value, 84, "Test 1.4: Response value should be doubled")
	testaux.asserteq(server_scheme, "http", "plaintext gRPC passes its transport scheme")
	testaux.asserteq(conn[1].channel.authority, "127.0.0.1:8991", "gRPC channel preserves target authority")
end)


testaux.case("Test 2: Server Streaming RPC", function()
	local stream, err = client:ServerStream({count = 5})
	testaux.assertneq(stream, nil, "Test 2.1: Stream should not be nil")
	testaux.asserteq(err, nil, "Test 2.2: Error should be nil")

	local count = 0
	while true do
		local resp = stream:read()
		if not resp then
			break
		end
		count = count + 1
		testaux.asserteq(resp.index, count, "Test 2.3." .. count .. ": Index should match")
		testaux.asserteq(resp.data, "item_" .. count, "Test 2.4." .. count .. ": Data should match")
	end
	testaux.asserteq(count, 5, "Test 2.5: Should receive 5 items")
	testaux.asserteq(stream.status, code.OK, "Test 2.6: Stream status should be OK")
	stream:close()
end)

testaux.case("Test 3: Client Streaming RPC", function()
	local stream<close>, err = client:ClientStream()
	testaux.assertneq(stream, nil, "Test 3.1: Stream should not be nil")
	testaux.asserteq(err, nil, "Test 3.2: Error should be nil")

	for i = 1, 3 do
		local ok, err = stream:write({
			message = "msg" .. i,
			value = i * 10
		})
		testaux.asserteq(ok, true, "Test 3.3." .. i .. ": Write should succeed")
	end

	local ok, err = stream:closewrite()
	testaux.asserteq(ok, true, "Test 3.4: closewrite should succeed")

	local resp = stream:read()
	testaux.assertneq(resp, nil, "Test 3.5: Response should not be nil")
	testaux.asserteq(resp.message, "msg1,msg2,msg3", "Test 3.6: Messages should be concatenated")
	testaux.asserteq(resp.value, 60, "Test 3.7: Values should be summed")
end)

testaux.case("Test 4: Bidirectional Streaming RPC", function()
	local stream<close>, err = client:BidiStream()
	testaux.assertneq(stream, nil, "Test 4.1: Stream should not be nil")
	testaux.asserteq(err, nil, "Test 4.2: Error should be nil")

	for i = 1, 3 do
		local ok, err = stream:write({
			message = "test" .. i,
			value = i
		})
		testaux.asserteq(ok, true, "Test 4.3." .. i .. ": Write should succeed")

		local resp = stream:read()
		testaux.assertneq(resp, nil, "Test 4.4." .. i .. ": Response should not be nil")
		testaux.asserteq(resp.message, "echo: test" .. i, "Test 4.5." .. i .. ": Message should match")
		testaux.asserteq(resp.value, i * 2, "Test 4.6." .. i .. ": Value should be doubled")
	end

	local ok, err = stream:closewrite()
	testaux.asserteq(ok, true, "Test 4.7: closewrite should succeed")

	local resp = stream:read()
	testaux.asserteq(resp, nil, "Test 4.8: Should receive nil after closewrite")
	testaux.asserteq(stream.status, code.OK, "Test 4.9: Stream status should be OK")
end)

testaux.case("Test 5: Error Handling", function()
	local resp, err = client:ErrorTest({error_code = code.INVALID_ARGUMENT})
	testaux.asserteq(resp, nil, "Test 5.1: Response should be nil on error")
	testaux.assertneq(err, nil, "Test 5.2: Error should not be nil")
	testaux.asserteq(type(err), "string", "Test 5.3: Error should be string")

	resp, err = client:ErrorTest({error_code = 0})
	testaux.assertneq(resp, nil, "Test 5.4: Response should not be nil on success")
	testaux.asserteq(err, nil, "Test 5.5: Error should be nil on success")
	testaux.asserteq(resp.result, "success", "Test 5.6: Result should be success")
end)

testaux.case("Test 6: Timeout Handling", function()
	local resp, err = client:SlowCall({
		message = "timeout test",
		value = 1
	}, 1000)
	testaux.asserteq(resp, nil, "Test 6.1: Response should be nil on timeout")
	testaux.asserteq(err, "Deadline exceeded", "Test 6.2: Error should be deadline exceeded")

	local resp, err = client:SlowCall({
		message = "no timeout",
		value = 2
	}, 5000)
	testaux.assertneq(resp, nil, "Test 6.3: Response should not be nil with longer timeout")
	testaux.asserteq(resp.message, "slow: no timeout", "Test 6.4: Message should match")
end)

testaux.case("Test 7: Concurrent Requests", function()
	local wg = waitgroup.new()
	local results = {}

	for i = 1, 10 do
		wg:fork(function()
			local resp, err = client:Echo({
				message = "concurrent" .. i,
				value = i
			})
			testaux.assertneq(resp, nil, "Test 7." .. i .. ".1: Response should not be nil")
			testaux.asserteq(resp.message, "echo: concurrent" .. i, "Test 7." .. i .. ".2: Message should match")
			testaux.asserteq(resp.value, i * 2, "Test 7." .. i .. ".3: Value should be doubled")
			results[i] = true
		end)
	end

	wg:wait()

	local count = 0
	for _ in pairs(results) do
		count = count + 1
	end
	testaux.asserteq(count, 10, "Test 7.4: All 10 requests should complete")
end)

testaux.case("Test 8: Large Message Handling", function()
	local large_msg = string.rep("x", 1024 * 1024)
	local resp, err = client:Echo({
		message = large_msg,
		value = 999
	})
	testaux.assertneq(resp, nil, "Test 8.1: Response should not be nil for large message")
	testaux.asserteq(#resp.message, #large_msg + 6, "Test 8.2: Response message length should match")
	testaux.asserteq(resp.value, 1998, "Test 8.3: Value should be doubled")
end)

testaux.case("Test 9: gRPC DNS failure returns host-specific string", function()
	testaux.with_mocked_dns(function(host, qtype)
		return nil, "Query timed out (10001)"
	end, {"silly.net.grpc.client.conn", "silly.net.grpc"}, function(reloaded)
		local mock_grpc = reloaded["silly.net.grpc"]
		local conn2, err = mock_grpc.newclient({
			targets = {"dns-fail.test:8991"},
		})
		testaux.asserteq(conn2, nil, "Test 9.1: gRPC client creation should fail on DNS error")
		testaux.assertcontains(err, "dns lookup",
			"Test 9.2: Error should mention dns lookup")
		testaux.assertcontains(err, "dns-fail.test",
			"Test 9.3: Error should include the failing host")
		testaux.assertcontains(err, "timed out",
			"Test 9.4: Error should propagate underlying DNS reason")
	end)
end)

testaux.case("Test 10: Trailers-only UNIMPLEMENTED response", function()
	local stream<close> = assert(client:MissingServerStream({message = "missing"}))
	testaux.asserteq(stream:read(), nil, "missing streaming method has no messages")
	testaux.asserteq(stream.h2stream.headeronly, true, "trailers-only ends at the initial response headers")
	testaux.asserteq(stream.status, code.UNIMPLEMENTED, "status is read from initial headers")
	testaux.asserteq(stream.message, "Method not found: /test.TestService/MissingServerStream", "initial error message retained")
	local response, err = client:MissingUnary({message = "missing"})
	testaux.asserteq(response, nil, "missing unary method has no response")
	testaux.assertcontains(err, "Method not found: /test.TestService/MissingUnary", "unary initial error message retained")
end)
testaux.case("Test 11: gRPC endpoints reuse target authority and only join resolved addresses", function()
	local addr = require "silly.net.addr"
	local dns = require "silly.net.dns"
	local join, lookup = addr.join, dns.lookup
	local calls = 0
	addr.join = function(...)
		calls = calls + 1
		return join(...)
	end
	dns.lookup = function(host, qtype)
		if host == "example.test" then
			testaux.asserteq(qtype, dns.A, "hostname target uses the configured A lookup")
			return "127.0.0.2"
		end
		return lookup(host, qtype)
	end
	local ok, err = pcall(function()
		-- Observe a separate factory's cached join function; leave existing clients unchanged.
		local factory = assert(loadfile("lualib/silly/net/grpc/client/conn.lua"))()
		local v4, v6 = "127.0.0.1:8991", "[::1]:8991"
		local fullv6, domain = "[2001:db8::1]:8991", "example.test:443"
		for _, spec in ipairs({
			{v4, "127.0.0.1", v4, v4, 0},
			{"passthrough:///" .. v4, "127.0.0.1", v4, v4, 0},
			{v6, "::1", v6, v6, 0},
			{"dns:///" .. fullv6, "2001:db8::1", fullv6, fullv6, 0},
			{"dns:///" .. domain, "example.test", "127.0.0.2:443", domain, 1},
			{"example.test:00443", "example.test", "127.0.0.2:00443", "example.test:00443", 1},
		}) do
			calls = 0
			local c<close> = assert(factory.new {targets = {spec[1]}})
			testaux.asserteq(c[1].hostname, spec[2], "TLS hostname keeps the parsed target host")
			testaux.asserteq(c[1].addr, spec[3], "transport address uses the resolved IP and port")
			testaux.asserteq(c[1].authority, spec[4], "authority keeps target host, brackets and port")
			testaux.asserteq(calls, spec[5], "only the distinct resolved address needs a join call")
		end
	end)
	addr.join, dns.lookup = join, lookup
	if not ok then
		error(err, 0)
	end
end)


local response_port = 8992
local function with_response(handler, run)
	local tcp = require "silly.net.tcp"
	local h2 = require "silly.net.http.h2"
	response_port = response_port + 1
	local addr = "127.0.0.1:" .. response_port
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			h2.httpd(handler, conn, "http")
		end,
	})
	local conn<close> = assert(grpc.newclient {targets = {addr}})
	local saved = client
	client = assert(grpc.newservice(conn, proto, "TestService"))
	local ok, err = pcall(run)
	client = saved
	conn:close()
	listener:close()
	if not ok then
		error(err, 0)
	end
end


testaux.case("Test 13: gRPC final status does not fall back to nonterminal response headers", function()
	local writebody = require "silly.net.grpc.helper".writebody
	for _, finish in ipairs({"DATA", "trailers"}) do
		with_response(function(s)
			assert(s:respond(200, {
				["content-type"] = "application/grpc",
				["grpc-status"] = code.OK,
				["grpc-message"] = "wrong initial message",
			}))
			assert(writebody(s, "test.EchoResponse", {message = "payload"}, false))
			assert(s:closewrite(nil, finish == "trailers" and {} or nil))
		end, function()
			local response, err = client:MissingUnary({message = "missing"})
			testaux.asserteq(response, nil, "unary rejects missing terminal status despite initial OK")
			testaux.assertneq(err, nil, "missing final status reports an error")
			local stream<close> = assert(client:MissingServerStream({message = "missing"}))
			testaux.asserteq(stream:read().message, "payload", "stream receives its message before EOF")
			testaux.asserteq(stream:read(), nil, "stream reaches its final state")
			testaux.asserteq(stream.status, code.UNKNOWN, "initial OK does not replace missing final status")
			testaux.assertneq(stream.message, "wrong initial message", "initial error text is not reused")
		end)
	end
end)

testaux.case("Test 14: gRPC final status and message come from the same terminal metadata", function()
	local writebody = require "silly.net.grpc.helper".writebody
	for _, message in ipairs({false, "right final message"}) do
		with_response(function(s)
			assert(s:respond(200, {
				["content-type"] = "application/grpc",
				["grpc-status"] = code.OK,
				["grpc-message"] = "wrong initial message",
			}))
			assert(writebody(s, "test.EchoResponse", {message = "payload"}, false))
			assert(s:closewrite(nil, {["grpc-status"] = code.INTERNAL,
				["grpc-message"] = message or nil}))
		end, function()
			local response, err = client:MissingUnary({message = "missing"})
			testaux.asserteq(response, nil, "terminal error rejects the unary response")
			testaux.assertcontains(err, message or "Unknown", "unary message uses only terminal metadata")
			testaux.asserteq(err:find("wrong initial message", 1, true), nil, "unary does not mix metadata blocks")
			local stream<close> = assert(client:MissingServerStream({message = "missing"}))
			testaux.asserteq(stream:read().message, "payload", "stream receives its payload")
			testaux.asserteq(stream:read(), nil, "terminal metadata ends the stream")
			testaux.asserteq(stream.status, code.INTERNAL, "stream uses the terminal status")
			testaux.asserteq(stream.message, message or code[code.INTERNAL], "stream does not mix metadata blocks")
		end)
	end
end)

testaux.case("Test 15: Streaming constructors send request headers before returning", function()
	for _, method in ipairs({"ClientStream", "BidiStream"}) do
		local stream<close> = assert(client[method](client))
		testaux.asserteq(stream.h2stream.id > 0, true, "stream is opened before it is returned")
		testaux.asserteq(stream.h2stream.localstate > 0, true, "request headers are already queued")
		assert(stream:closewrite())
		local response = stream:read()
		if method == "ClientStream" then
			testaux.assertneq(response, nil, "empty client stream still receives its unary response")
		else
			testaux.asserteq(response, nil, "empty bidirectional stream completes without a message")
		end
		testaux.asserteq(stream.status, code.OK, "stream terminates normally")
	end
end)

testaux.case("Test 16: A bidirectional stream can receive the first message before writing", function()
	local name = "/test.TestService/BidiStream"
	local saved = registrar.handlers[name]
	local writebody = require "silly.net.grpc.helper".writebody
	registrar.handlers[name] = function(stream)
		assert(writebody(stream, "test.EchoResponse", {message = "greeting", value = 7}, false))
		local data = stream:read(1, 2000)
		testaux.asserteq(data, nil, "client closes its empty request after receiving the greeting")
		assert(stream:closewrite(nil, {["grpc-status"] = code.OK}))
	end
	local ok, err = pcall(function()
		local stream<close> = assert(client:BidiStream())
		testaux.asserteq(stream.h2stream.id > 0, true, "constructor opens the request without a message")
		assert(stream.h2stream:waitresponse(2000))
		local response = stream:read()
		testaux.asserteq(response.message, "greeting", "server can send the first message")
		testaux.asserteq(response.value, 7, "first message is decoded")
		assert(stream:closewrite())
		testaux.asserteq(stream:read(), nil, "server trailers complete the stream")
		testaux.asserteq(stream.status, code.OK, "bidirectional stream finishes normally")
	end)
	registrar.handlers[name] = saved
	if not ok then
		error(err, 0)
	end
end)

testaux.case("Test 17: Local close drains a streaming constructor waiting for a slot", function()
	for _, method in ipairs({"ClientStream", "BidiStream"}) do
		local conn<close> = assert(grpc.newclient {targets = {"127.0.0.1:8991"}})
		local client = assert(grpc.newservice(conn, proto, "TestService"))
		assert(client:Echo({message = "connect", value = 1}))
		local ch = conn[1].channel
		ch.streammax = 1
		local blocker<close> = assert(ch:request("POST", "/test.TestService/BidiStream",
			{["content-type"] = "application/grpc"}))
		assert(blocker:waitresponse(2000))
		local started, done = channel.new(), channel.new()
		local wg = waitgroup.new()
		wg:fork(function()
			started:push(true)
			local stream, err = client[method](client)
			done:push({stream = stream, err = err})
		end)
		testaux.await(started, "Test 17: constructor started its initial header write")
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 17.1: constructor waits for a stream slot")
		ch:close()
		testaux.asserteq(ch:request("GET", "/", {}), nil, "Test 17.2: local close rejects new requests")
		blocker:close()
		local result = testaux.await(done, "Test 17: constructor drains after a slot is released")
		wg:wait()
		testaux.assertneq(result.stream, nil, "Test 17.3: queued constructor is admitted after local close")
		testaux.asserteq(result.err, nil, "Test 17.4: queued constructor reports no close error")
		local stream<close> = result.stream
		testaux.asserteq(stream:write({message = "queued", value = 3}), true, "Test 17.5: admitted RPC can send")
		assert(stream:closewrite())
		local response = assert(stream:read())
		testaux.asserteq(response.message, method == "ClientStream" and "queued" or "echo: queued",
			"Test 17.6: admitted RPC receives its response")
		testaux.asserteq(response.value, method == "ClientStream" and 3 or 6, "Test 17.7: response data is complete")
		if method == "BidiStream" then
			testaux.asserteq(stream:read(), nil, "Test 17.8: bidirectional response reaches its trailers")
		end
		testaux.asserteq(stream.status, code.OK, "Test 17.9: admitted RPC completes successfully")
		stream:close()
		testaux.asserteq(ch.conn, nil, "Test 17.10: drained channel releases its transport")
		testaux.assertneq(client:Echo({message = "reconnect", value = 2}), nil,
			"Test 17.11: client establishes a replacement connection")
	end
end)

testaux.case("Test 18: ID exhaustion rolls over connections without cancelling existing requests", function()
	local conn<close> = assert(grpc.newclient {targets = {"127.0.0.1:8991"}})
	local seed = assert(conn:request("POST", "/test.TestService/DoesNotExist", {}, true))
	assert(seed:waitresponse(2000))
	local ch = seed.channel
	seed:close()
	ch.streamidx = 0x7ffffffd
	local reserved<close> = assert(conn:request("POST", "/test.TestService/Echo", {["content-type"] = "application/grpc"}))
	local extra<close> = assert(conn:request("POST", "/test.TestService/DoesNotExist", {["content-type"] = "application/grpc"}, true))
	testaux.assertneq(extra.channel, ch, "Test 18.1: exhausted IDs cause connection replacement")
	testaux.assertneq(ch.conn, nil, "Test 18.2: replacement retains the admitted stream's transport")

	testaux.asserteq(require("silly.net.grpc.helper").writebody(reserved, "test.EchoRequest", {message = "last"}, true), true, "Test 18.3: the admitted request can still send")
	testaux.asserteq(reserved:waitresponse(2000), true, "Test 18.4: the admitted request receives its response")
	reserved:readall(2000)
	reserved:close()
	testaux.asserteq(ch.conn, nil, "Test 18.5: the replaced channel closes when its last stream finishes")

	testaux.asserteq(extra.id, 1, "Test 18.6: the replacement connection starts with the first ID")
	testaux.asserteq(extra:waitresponse(2000), true, "Test 18.7: the replacement receives responses")
	extra:readall(2000)
end)

testaux.case("Test 19: Request decoding errors use trailers after response headers", function()
	local conn<close> = assert(grpc.newclient {targets = {"127.0.0.1:8991"}})
	for _, fixture in ipairs({
		{body = string.pack(">I1I4", 0, 4 * 1024 * 1024 + 1), status = code.RESOURCE_EXHAUSTED},
		{body = string.pack(">I1I4", 1, 3) .. "bad", status = code.UNIMPLEMENTED},
	}) do
		local stream<close> = assert(conn:request("POST", "/test.TestService/Echo", {["content-type"] = "application/grpc"}))

		assert(stream:closewrite(fixture.body))
		local body, err = stream:readall(2000)
		testaux.asserteq(body, "", err or "Test 19.1: decoding error remains a valid HTTP/2 response")
		testaux.asserteq(tonumber(stream.trailer['grpc-status']), fixture.status,
			"Test 19.2: decoding error status follows the flushed response headers")
	end
end)

testaux.case("Test 20: Existing gRPC deadlines cover request admission", function()
	local conn<close> = assert(grpc.newclient {targets = {"127.0.0.1:8991"}})
	local service = assert(grpc.newservice(conn, proto, "TestService"))
	assert(service:Echo({message = "connect"}))
	local ch = conn[1].channel
	for _, method in ipairs({"Echo", "ServerStream"}) do
		ch.streammax = 0
		local response, err = service[method](service, {}, 20)
		testaux.asserteq(response, nil, "Test 20.1: admission obeys the RPC deadline")
		testaux.asserteq(err, "Deadline exceeded", "Test 20.2: existing deadline error is preserved")
		testaux.asserteq(ch.openwaitq:size(), 0, "Test 20.3: expired RPC leaves no admission waiter")
	end
	ch.streammax = 1
	testaux.assertneq(service:Echo({message = "reuse"}), nil, "Test 20.4: expired admission leaves the connection usable")
end)

testaux.case("Test 12: gRPC applies keepalive defaults only for positive receive intervals", function()
	for _, opts in ipairs({
		{keep_alive_timeout = 2345},
		{keep_alive_interval = 0, keep_alive_timeout = 2345},
		{keep_alive_interval = -1, keep_alive_timeout = 2345},
		{keep_alive_interval = 60000},
		{keep_alive_interval = 60000, keep_alive_timeout = 0},
		{keep_alive_interval = 60000, keep_alive_timeout = -1},
		{keep_alive_interval = 60000, keep_alive_timeout = 2345, keep_alive_while_idle = false},
		{keep_alive_interval = 60000, keep_alive_while_idle = true},
	}) do
		opts.targets = {"127.0.0.1:8991"}
		local pool<close> = assert(grpc.newclient(opts))
		local service = grpc.newservice(pool, proto, "TestService")
		local response = assert(service:Echo({message = "options", value = 1}))
		testaux.asserteq(response.message, "echo: options", "RPC succeeds with keepalive options")
		local ch = pool[1].channel
		local enabled = opts.keep_alive_interval and opts.keep_alive_interval > 0
		testaux.asserteq(ch.keepaliveinterval, enabled and 60000 or nil,
			"only positive intervals enable probing")
		if enabled then
			local timeout = opts.keep_alive_timeout
			timeout = timeout and timeout > 0 and timeout or 20000
			testaux.asserteq(ch.keepalivetimeout, timeout, "gRPC uses its own probe timeout default")
			testaux.asserteq(ch.keepalivewhileidle, opts.keep_alive_while_idle == true,
				"idle probing defaults false and preserves explicit values")
		end
		testaux.asserteq(ch.timer ~= nil, not not enabled, "only enabled probes have a timer")
	end
end)

if slow_started then
	testaux.await(slow_done, "slow RPC handler completed")
end
conn:close()
server:close()
wait_readers()
