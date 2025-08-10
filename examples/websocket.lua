local core = require "core"
local crypto = require "core.crypto.utils"
local websocket = require "core.websocket"

local handler = function(sock)
	local dat, typ = sock:read()
	print("server read:", dat, typ)
	sock:write(dat, "pong")
	sock:close()
end


websocket.listen {
	addr = "127.0.0.1:9999",
	handler = handler
}

websocket.listen {
	tls = true,
	addr = "127.0.0.1:8888",
	certs = {
		{
			cert = "test/cert.pem",
			cert_key = "test/key.pem",
		}
	},
	handler = handler,
}

core.start(function()
	local sock, err = websocket.connect("http://127.0.0.1:9999")
	assert(sock, err)
	local txt = crypto.randomkey(5)
	print("client", sock, "send", txt)
	local ok = sock:write(txt, "ping")
	local dat, typ = sock:read()
	print("client", sock, "read", dat, typ)
	sock:close()

	local sock, err = websocket.connect("https://127.0.0.1:8888")
	assert(sock, err)
	local txt = crypto.randomkey(5)
	print("client", sock, "send", txt)
	local ok = sock:write(txt, "ping")
	local dat, typ = sock:read()
	print("client", sock, "read", dat, typ)
	sock:close()
end)

