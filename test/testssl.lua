local core = require "sys.core"
local ssl = require "sys.ssl"

return function()
	local fd = ssl.connect("14.215.177.37:443")
	print("connect", fd)
	ssl.write(fd, "GET https://www.baidu.com/ HTTP/1.1\r\n" ..
		   "User-Agent: Fiddler\r\n" ..
		   "Host: www.baidu.com\r\n\r\n")
	local d
	while not d do
		d = ssl.readline(fd)
		print(d)
	end
	print("testssl ok")
end





