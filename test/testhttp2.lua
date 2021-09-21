local http2 = require "http2"
local core = require "sys.core"
local crypto = require "sys.crypto"
local json = require "sys.json"
local waitgroup = require "sys.waitgroup"
local testaux = require "testaux"

local f<const> = io.open("./a.txt", "w")

return function()
	if not crypto.digestsign then
		print("not enable openssl")
		return
	end
	http2.listen {
		tls_port = ":8081",
		tls_cert= "test/cert.pem",
		tls_key = "test/key.pem",
		handler = function(stream)
			core.sleep(math.random(1, 300))
			local header = stream:read()
			testaux.asserteq(stream.method, "POST", "http2.server method")
			testaux.asserteq(stream.path, "/test", "http2.server path")
			testaux.asserteq(header['hello'], "world", "http2.server header")
			local body = stream:readall()
			testaux.asserteq(body, "http2", "http2 body")
			stream:ack(200, {["foo"] = header['foo']})
			stream:write("http2")
			stream:close()
		end
	}
	local n = 0
	print("test http2 client")
	local wg = waitgroup:create()
	for i = 1, 2000 do
		wg:fork(function()
			local key = crypto.randomkey(1028)
			local status, header, body = http2.POST("https://http2.golang.org/reqinfo", {
				['hello'] = 'world',
				['foo'] = key,
			}, "http2")
			n = n + 1
			print("test", n)
			testaux.asserteq(status, 200, "http2.client status")
			testaux.assertneq(body:find("Foo: " .. key), nil, "http2.header key")
			testaux.assertneq(body:find("Hello: world"), nil, "http2.header key")
		end)
	end
	wg:wait()
	print("test http2 server")
	local wg = waitgroup:create()
	for i = 1, 2000 do
		wg:fork(function()
			local key = crypto.randomkey(1028)
			local status, header, body = http2.POST("https://127.0.0.1:8081/test", {
				['hello'] = 'world',
				['foo'] = key,
			}, "http2")
			testaux.asserteq(status, 200, "http2.client status")
			testaux.asserteq(header['foo'], key, "http2.client header")
			testaux.asserteq(body, 'http2', "http2.client body")
		end)
	end
	wg:wait()
end

