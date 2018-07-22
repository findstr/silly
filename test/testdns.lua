local core = require "sys.core"
local socket = require "sys.socket"
local dns = require "sys.dns"
local testaux = require "testaux"

return function()
	local ip = dns.resolve("smtp.sina.com.cn")
	testaux.assertneq(ip, nil, "dns resolve ip")
	local fd = socket.connect(string.format("%s:%s", ip, 25))
	testaux.assertneq(fd, nil, "dns resolve ip validate")
	local l = socket.readline(fd)
	testaux.assertneq(l, nil, "dns resolve ip validate")
	local f = l:find("220")
	testaux.assertneq(f, nil, "dns resolve ip validate")
end

