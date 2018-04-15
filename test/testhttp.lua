local server = require "http.server"
local client = require "http.client"
local testaux = require "testaux"
local write = server.write
local dispatch = {}

dispatch["/"] = function(fd, reqeust, body)
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
		"Content-Type: text/html",
		}

	write(fd, 200, head, body)
end

local content = ""

dispatch["/download"] = function(fd, request, body)
	write(fd, 200, {"Content-Type: text/plain"}, content)
end

dispatch["/upload"] = function(fd, request, body)
	if request.form.Hello then
		content = request.form.Hello
	end
	local body = "Upload"
	local head = {
		"Content-Type: text/plain",
		}
	write(fd, 200, head, body)
end


server.listen(":8080", function(fd, request, body)
	local c = dispatch[request.uri]
	if c then
		c(fd, request, body)
	else
		print("Unsupport uri", request.uri)
		write(fd, 404, {"Content-Type: text/plain"}, "404 Page Not Found")
	end
end)


--client part

return function()
	local status, head, body = client.POST("http://127.0.0.1:8080/upload",
				{"Content-Type: application/x-www-form-urlencoded"},
				"Hello=findstr&")
	local status, head, body = client.GET("http://127.0.0.1:8080/download")
	testaux.asserteq(body, "findstr", "http GET data validate")
	testaux.asserteq(status, 200, "http GET status validate")
end

