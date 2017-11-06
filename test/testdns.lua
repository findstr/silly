local core = require "sys.core"
local dns = require "sys.dns"

return function()
	local ip = dns.query("www.baidu.com")
	print("domain: www.baidu.com", ip)
end

