local core = require "core"
local json = require "core.json"
local http = require "core.http"

http.listen {
	addr = "127.0.0.1:8080",
	handler = function(stream)
		local html = [[
<html>
	<head>Hello World</head>
	<body>
		Hello,World!
	</body>
</html>
]]
		stream:respond(200, {
			["Conteng-Type"] = "text/html",
			["content-length"] = #html,
		})
		stream:close(html, true)
	end
}

core.start(function()
	local res, err = http.GET("http://127.0.0.1:8080")
	print(res and res.body, err)
end)
