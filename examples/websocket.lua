local core = require "sys.core"
local crypto = require "sys.crypto"
local websocket = require "http.websocket"

websocket.listen {
	port = "127.0.0.1:9999",
	tls_port = "127.0.0.1:8888",
	tls_cert = "test/cert.pem",
	tls_key = "test/key.pem",
	handler = function(sock)
		local dat, typ = sock:read()
		print("server read:", dat, typ)
		sock:write(dat, "pong")
		sock:close()
	end
}

core.start(function()
	local sock, err = websocket.connect("http://127.0.0.1:9999")
	local txt = crypto.randomkey(5)
	print("client", sock, "send", txt)
	local ok = sock:write(txt, "ping")
	local dat, typ = sock:read()
	print("client", sock, "read", dat, typ)
	local sock, err = websocket.connect("https://127.0.0.1:8888")
	local txt = crypto.randomkey(5)
	print("client", sock, "send", txt)
	local ok = sock:write(txt, "ping")
	local dat, typ = sock:read()
	print("client", sock, "read", dat, typ)
end)

