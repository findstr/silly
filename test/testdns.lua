local core = require "sys.core"
local socket = require "sys.socket"
local dns = require "sys.dns"
local testaux = require "testaux"

return function()
	dns.server("223.5.5.5:53")
	local ip = dns.query("smtp.sina.com.cn")
	testaux.assertneq(ip, nil, "dns query ip")
	local fd = socket.connect(string.format("%s:%s", ip, 25))
	testaux.assertneq(fd, nil, "dns query ip validate")
	local l = socket.readline(fd)
	testaux.assertneq(l, nil, "dns query ip validate")
	local f = l:find("220")
	testaux.assertneq(f, nil, "dns query ip validate")
end

