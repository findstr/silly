local http = require "core.http"
local core = require "core"
local crypto = require "core.crypto"
local waitgroup = require "core.sync.waitgroup"
local testaux = require "test.testaux"

local f<const> = io.open("./a.txt", "w")

if not crypto.digestsign then
	print("not enable openssl")
	return
end
http.listen {
	tls = true,
	port = ":8082",
	alpnprotos = {
		"h2",
	},
	certs = {
		{
			cert = "test/cert.pem",
			cert_key = "test/key.pem",
		}
	},
	handler = function(stream)
		core.sleep(math.random(1, 300))
		local status, header = stream:readheader()
		testaux.asserteq(stream.method, "POST", "http2.server method")
		testaux.asserteq(stream.path, "/test", "http2.server path")
		testaux.asserteq(header['hello'], "world", "http2.server header")
		local body = stream:readall()
		testaux.asserteq(body, "http2", "http2 body")
		stream:respond(200, {["foo"] = header['foo']})
		stream:close("http2")
	end
}
local n = 0
print("test http2 client")
--[[ disable test http2 client for temporary
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
]]
local ack, err = http.GET("https://http2cdn.cdnsun.com/")
testaux.asserteq(ack.status, 200, "http2.client status")
testaux.asserteq(ack.body, "Hello\n", "http2.body")

print("test http2 server")
local wg = waitgroup:create()
for i = 1, 2000 do
	wg:fork(function()
		local key = crypto.randomkey(1028)
		local ack, err = http.POST("https://localhost:8082/test", {
			['hello'] = 'world',
			['foo'] = key,
		}, "http2")
		testaux.asserteq(ack.status, 200, "http2.client status")
		testaux.asserteq(ack.header['foo'], key, "http2.client header")
		testaux.asserteq(ack.body, 'http2', "http2.client body")
	end)
end
wg:wait()
print("test http2 done")

