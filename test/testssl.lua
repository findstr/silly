local dns = require "core.dns"
local ip = dns.lookup("www.baidu.com", dns.A)
local fd = ssl.connect(ip..":443")
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





