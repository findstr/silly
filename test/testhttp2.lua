local core = require "core"
local time = require "core.time"
local http = require "core.http"
local transport = require "core.http.transport"
local crypto = require "core.crypto.utils"
local waitgroup = require "core.sync.waitgroup"
local testaux = require "test.testaux"

local f<const> = io.open("./a.txt", "w")

local data = crypto.randomkey(65*1024)

local alpn_protos = {"http/1.1", "h2"}
local function POST(url, header, body, check_window_size)
	if body then
		header = header or {}
		header["content-length"] = #body * 2
	end
	local stream<close>, err = http.request("POST", url, header, false, alpn_protos)
	if not stream then
		return nil, err
	end
	local version = stream.version
	if version == "HTTP/2" then
		stream:write(body)
		stream:close(body)
	else
		stream:write(body)
	end
	local status, header = stream:readheader()
	if not status then
		return nil, header
	end
	if check_window_size then
		testaux.asserteq(stream.channel.window_size, 65535, "http2.client window_size")
	end
	local body = stream:readall()
	return {
		status = status,
		header = header,
		body = body,
	}
end

local server = http.listen {
	tls = true,
	addr = "127.0.0.1:8082",
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
		testaux.assertneq(stream.remoteaddr, nil, "http2.server remoteaddr")
		testaux.asserteq(stream.version, "HTTP/2", "http2.server version")
		testaux.asserteq(stream.query.foo, "bar", "http2.server query")
		time.sleep(math.random(1, 300))
		local status, header = stream:readheader()
		testaux.asserteq(stream.method, "POST", "http2.server method")
		testaux.asserteq(stream.path, "/test", "http2.server path")
		testaux.asserteq(header['hello'], "world", "http2.server header")
		local body = stream:readall()
		testaux.asserteq(body, data .. data, "http2 body")
		stream:respond(200, {["foo"] = header['foo']})
		stream:close("http2")
	end
}
local n = 0
print("test http2 client")
--[[ disable test http2 client for temporary
local wg = waitgroup.new()
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
--[[
local ack, err = http.GET("https://http2cdn.cdnsun.com/")
testaux.asserteq(ack.status, 200, "http2.client status")
testaux.asserteq(ack.body, "Hello\n", "http2.body")
]]

print("test http2 server")
local wg = waitgroup.new()
for i = 1, 2000 do
	wg:fork(function()
		local key = crypto.randomkey(1028)
		local ack, err = POST("https://127.0.0.1:8082/test?foo=bar", {
			['hello'] = 'world',
			['foo'] = key,
		}, data)
		assert(ack, err)
		testaux.asserteq(ack.status, 200, "http2.client status")
		testaux.asserteq(ack.header['foo'], key, "http2.client header")
		testaux.asserteq(ack.body, 'http2', "http2.client body")
	end)
end
wg:wait()
local ack, err = POST("https://127.0.0.1:8082/test?foo=bar", {
	['hello'] = 'world',
	['foo'] = "bar",
}, data, true)
assert(ack, err)
testaux.asserteq(ack.status, 200, "http2.client status")
testaux.asserteq(ack.header['foo'], "bar", "http2.client header")
testaux.asserteq(ack.body, 'http2', "http2.client body")
print("test http2 done")
server:close()
for _, ch in pairs(transport.channels()) do
	testaux.asserteq(next(ch.streams), nil, "all stream is closed")
	ch:close()
end