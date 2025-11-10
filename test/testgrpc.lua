local env = require "silly.env"
local time = require "silly.time"
local protoc = require "protoc"
local grpc = require "silly.net.grpc"
local crypto = require "silly.crypto.utils"
local waitgroup = require "silly.sync.waitgroup"
local registrar = require "silly.net.grpc.registrar".new()
local testaux = require "test.testaux"

local timeout = env.get("test.grpc.timeout")
timeout = timeout and tonumber(timeout) or 5000

local p = protoc:new()

local ok = p:load([[
syntax = "proto3";

package foo;

message HelloRequest {
  string name = 1;
  int32 age = 2;
  string rand = 3;
}

message HelloResponse {
	string rand = 1;
}


service GreetService {
  rpc SayHello (HelloRequest) returns (HelloResponse) {}
}
]], "greetpb.proto")

assert(ok)

local case
local function case_one(msg)
	print("case_one", msg)
	return msg, nil
end

local function case_two(msg)
	time.sleep(10)
	return msg, nil
end

local function case_three(msg)
	time.sleep(2*timeout)
	return msg
end

local proto = p.loaded["greetpb.proto"]
registrar:register(proto, "GreetService", {
	SayHello = function(input)
		return case(input)
	end
})

case = case_one

local server = grpc.listen {
	addr = "127.0.0.1:8990",
	registrar = registrar,
}

local client

local x = crypto.randomkey(1024*1024)
local function request(index, count)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8) .. x
			}
			local body, err = client:SayHello(test)
			testaux.assertneq(body, nil, "rpc call error:" .. (err or ""))
			testaux.asserteq(test.rand, body.rand, "rpc match request/response")
		end
	end
end

local function timeoutx(index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, ack = client:SayHello(test)
			testaux.asserteq(body, nil, "rpc timeout, body is nil")
			testaux.asserteq(ack, "timeout", "rpc timeout, ack is timeout")
		end
	end
end


local function client_part()
	local conn = grpc.newclient {
		target = "127.0.0.1:8990",
	}
	client = grpc.newservice(conn, proto, "GreetService")
	local wg = waitgroup.new()
	case = case_one
	for i = 1, 2 do
		wg:fork(request(i, 1))
	end
	wg:wait()

end
testaux.module("tcp")
client_part()
server:close()
