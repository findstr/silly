local core = require "core"
local protoc = require "protoc"
local grpc = require "core.grpc"
local crypto = require "core.crypto"
local testaux = require "test.testaux"
local waitgroup = require "core.sync.waitgroup"
local registrar = require "core.grpc.registrar":new()
local h2stream = require "core.http.h2stream"

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
	return msg, nil
end

local function case_two(msg)
	core.sleep(100)
	return msg, nil
end

local function case_three(msg)
	core.sleep(8000)
	return msg
end

local proto = p.loaded["greetpb.proto"]
registrar:register(proto, {
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

local function request(index, count)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, err = client.SayHello(test)
			testaux.assertneq(body, nil, "rpc timeout:" .. (err or ""))
			testaux.asserteq(test.rand, body.rand, "rpc match request/response")
		end
	end
end

local function timeout(index, count, cmd)
	return function()
		for i = 1, count do
			local test = {
				name = "hello",
				age = index,
				rand = crypto.randomkey(8),
			}
			local body, ack = client.SayHello(test)
			testaux.asserteq(body, nil, "rpc timeout, body is nil")
			testaux.asserteq(ack, "timeout", "rpc timeout, ack is timeout")
		end
	end
end


local function client_part()
	client = grpc.newclient {
		service = "GreetService",
		endpoints = {"127.0.0.1:8990"},
		proto = proto,
		timeout = 5000,
	}
	local wg = waitgroup:create()
	case = case_one
	for i = 1, 2 do
		wg:fork(request(i, 5))
	end
	wg:wait()
	print("case one finish")
	case  = case_two
	for i = 1, 20 do
		wg:fork(request(i, 50))
		core.sleep(100)
	end
	wg:wait()
	print("case two finish")
	case = case_three
	for i = 1, 20 do
		wg:fork(timeout(i, 2))
		core.sleep(10)
	end
	wg:wait()
	print("case three finish")
end

client_part()
server:close()

for _, ch in pairs(h2stream.channels()) do
	testaux.asserteq(next(ch.streams), nil, "all stream is closed")
end
