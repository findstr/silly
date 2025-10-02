local dns = require "core.dns"
local hive = require "core.hive"
local tls = require "core.net.tls"
local testaux = require "test.testaux"

-- Test 1: Connect to www.baidu.com
do
	local ip = dns.lookup("www.baidu.com", dns.A)
	local fd = tls.connect(ip..":443")
	tls.write(fd, "GET https://www.baidu.com/ HTTP/1.1\r\n" ..
		   "User-Agent: Fiddler\r\n" ..
		   "Host: www.baidu.com\r\n\r\n")
	local d
	while not d do
		d = tls.readline(fd)
		print(d)
	end
end

-- Test 2: Reload certs
do
	local tlsfd = tls.listen {
		addr = "127.0.0.1:10003",
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		disp = function(fd, addr)
			local body = "testssl ok"
			local resp = "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
			tls.write(fd, resp)
			tls.close(fd)
		end
	}
	local bee = hive.spawn [[
		return function()
			local handle = io.popen("curl -v -s https://localhost:10003 --insecure 2>&1")
			assert(handle)
			local result = handle:read("*a")
			handle:close()
			return result
		end
	]]
	local result = hive.invoke(bee)
	local cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost", "certA")
	tls.reload(tlsfd, {
		certs = {
			{
				cert = testaux.CERT_B,
				key = testaux.KEY_B,
			},
		},
	})
	result = hive.invoke(bee)
	cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost2", "certB")
end







