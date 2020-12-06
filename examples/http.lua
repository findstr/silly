local core = require "sys.core"
local httpd = require "http.server"
local httpc = require "http.client"

httpd.listen {
	port = "127.0.0.1:8080",
	handler = function(req)
		local html = [[
<html>
	<head>Hello World</head>
	<body>
		Hello,World!
	</body>
</html>
]]
		httpd.write(req.sock, 200, {"Conteng-Type:text/html"}, html)
	end
}

core.start(function()
	local res = httpc.GET("http://127.0.0.1:8080")
	print(res.body)
end)

