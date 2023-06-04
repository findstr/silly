local server = require "http.server"
local client = require "http.client"
local json = require "sys.json"
local testaux = require "testaux"
local write = server.write
local dispatch = {}

dispatch["/"] = function(req)
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
	write(req.sock, 200, head, body)
end

local content = ""

dispatch["/download"] = function(req)
	write(req.sock, 200, {["Content-Type"] = "text/plain"}, content)
end

dispatch["/upload"] = function(req)
	if req.form.Hello then
		content = req.form.Hello
	end
	local body = "Upload"
	local head = {["Content-Type"] = "text/plain"}
	write(req.sock, 200, head, body)
end

return function()
	server.listen {
		port = ":8080",
		handler = function(req)
			local c = dispatch[req.uri]
			if c then
				c(req)
			else
				print("Unsupport uri", req.uri)
				write(req.sock, 404,
					{["Content-Type"] = "text/plain"},
					"404 Page Not Found")
			end
		end
	}
	local res = client.POST("http://localhost:8080/upload",
			{["Content-Type"] = "application/x-www-form-urlencoded"},
			"Hello=findstr&")
	local res = client.GET("http://localhost:8080/download")
	print(json.encode(res))
	testaux.asserteq(res.body, "findstr", "http GET data validate")
	testaux.asserteq(res.status, 200, "http GET status validate")
	local res = client.GET("http://www.baidu.com")
	testaux.asserteq(res.status, 200, "http GET status validate")
end

