local core = require "core"
local websocket = require "core.websocket"
local testaux = require "test.testaux"

local handler = function(sock)
	local dat, typ = sock:read()
	testaux.asserteq(typ, "ping", "server read type `ping`")
	testaux.asserteq(dat, "hello", "server read data `hello`")
	sock:write("world", "pong")
	sock:close()
end

websocket.listen {
	port = "127.0.0.1:10003",
	handler = handler,
}

websocket.listen {
	tls = true,
	port = "127.0.0.1:10004",
	certs = {
		{
			cert = "test/cert.pem",
			cert_key = "test/key.pem",
		}
	},
	handler = handler,
}

local function client(scheme, port)
	local sock, err = websocket.connect(scheme .. "://127.0.0.1" .. port)
	testaux.assertneq(sock, nil, "connect ws[s]://127.0.0.1" .. port)
	local ok = sock:write("hello", "ping")
	testaux.asserteq(ok, true, "PING hello")
	local dat, typ = sock:read()
	testaux.asserteq(typ, "pong", "PONG hello")
	testaux.asserteq(dat, "world", "PONG hello")
	local dat, typ = sock:read()
	testaux.asserteq(typ, "close", "CLOSE")
	testaux.asserteq(dat, "", '""')
	core.sleep(1)
	local ok = sock:close()
	testaux.asserteq(ok, true, "close sock")
	local ok = sock:close()
	testaux.asserteq(ok, false, "close dummy")
end

testaux.module("socket")
client("ws", ":10003")
testaux.module("tls")
client("wss", ":10004")

