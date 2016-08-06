local core = require "silly.core"
local dns = require "dns"

core.start(function()
        local ip = dns.query("www.baidu.com")
        print("domain: www.baidu.com", ip)
end)

return dns

