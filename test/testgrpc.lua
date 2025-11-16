local time = require "silly.time"
local protoc = require "protoc"
local grpc = require "silly.net.grpc"
local code = require "silly.net.grpc.code"
local waitgroup = require "silly.sync.waitgroup"
local registrar = require "silly.net.grpc.registrar".new()
local testaux = require "test.testaux"

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
				return {code = code.Internal, message = err}
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
				return {code = code.Internal, message = err}
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
		time.sleep(3000)
		return {
			message = "slow: " .. input.message,
			value = input.value
		}
	end,
})

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
	local resp, err = client:ErrorTest({error_code = code.InvalidArgument})
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
	testaux.asserteq(err, "grpc: deadline exceeded", "Test 6.2: Error should be deadline exceeded")

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

time.sleep(1000)

conn:close()
server:close()

time.sleep(500)
