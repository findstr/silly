local core = require "silly.core"
local dns = require "dns"

return function()
	local ip = dns.query("www.baidu.com")
	print("domain: www.baidu.com", ip)
end

