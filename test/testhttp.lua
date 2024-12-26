local dns = require "core.dns"
local json = require "core.json"
local http = require "core.http"
local testaux = require "test.testaux"
local dispatch = {}

dispatch["/"] = function(stream)
	local body = [[
		<html>
			<head>Hello Stupid</head>
			<body>
				<form action="upload" method="POST">
				<input type="text" name="Hello"/>
				<input type="submit" name="submit"/>
				</form>
			</body>
		</html>
	]]
	local head = {
		["Content-Type"] = "text/html",
	}
	stream:respond(200, head)
	stream:close(body)
end

local content = ""

dispatch["/download"] = function(stream)
	stream:respond(200, {
		["Content-Type"] = "text/plain",
		["content-length"] = #content,
	})
	stream:close(content)
end

dispatch["/upload"] = function(stream)
	if stream.form.Hello then
		content = stream.form.Hello
	end
	local body = "Upload"
	local head = {["Content-Type"] = "text/plain"}
	stream:respond(200, head)
	stream:close(body)
end

local handler = function(stream)
	local header = stream.header
	local body = stream:readall()
	print("handler", stream.path, json.encode(header), body, stream.form and json.encode(stream.form))
	local c = dispatch[stream.path]
	if c then
		c(stream)
	else
		local txt = "404 Page Not Found"
		stream:respond(200, {
			["Content-Type"] = "text/plain",
			['content-length'] = #txt,
		})
		stream:close(txt)
	end
end
local fd1 = http.listen {
	port = "127.0.0.1:8080",
	handler = handler,
}
assert(fd1, "listen 8080 fail")
local fd2 = http.listen {
	tls = true,
	port = "127.0.0.1:8081",
	certs = {
		{
			cert = "./test/cert.pem",
			cert_key = "./test/key.pem",
		},
	},
	handler = handler,
}
assert(fd2, "listen 8081 fail")
local ack, err = http.POST("http://127.0.0.1:8080/upload",
		{["Content-Type"] = "application/x-www-form-urlencoded"},
		"Hello=findstr")
if not ack then
	print("ERROR", err)
	return
end
dns.server("223.5.5.5:53")
print(ack.status, json.encode(ack.header), ack.body)
local res = http.GET("https://127.0.0.1:8081/download")
print(json.encode(res))
testaux.asserteq(res.body, "findstr", "http GET data validate")
testaux.asserteq(res.status, 200, "http GET status validate")
local res = http.GET("http://www.baidu.com")
testaux.asserteq(res.status, 200, "http GET status validate")

