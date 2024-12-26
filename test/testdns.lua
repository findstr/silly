local dns = require "core.dns"
local testaux = require "test.testaux"

print("testA")
dns.server("223.5.5.5:53")
local ip = dns.resolve("test.silly.gotocoding.com", dns.A)
table.sort(ip, function(a, b)
	return a < b
end)
testaux.asserteq(#ip, 2, "multi ip")
testaux.asserteq(ip[1], "127.0.0.1", "ip1")
testaux.asserteq(ip[2], "127.0.0.2", "ip2")
print("testAAAA")
local ip = dns.resolve("test.silly.gotocoding.com", dns.AAAA)
table.sort(ip, function(a, b)
	return a < b
end)
testaux.asserteq(#ip, 2, "multi ip")
testaux.asserteq(ip[1], "00:00:00:00:00:00:00:01", "ip1")
testaux.asserteq(ip[2], "00:00:00:00:00:00:00:02", "ip2")
print("testSRV")
local ip = dns.resolve("_rpc._tcp.gotocoding.com", dns.SRV)
testaux.asserteq(#ip, 2, "multi srv")
table.sort(ip, function(a, b)
	return a.priority < b.priority
end)
testaux.asserteq(ip[1].priority, 0, "srv1")
testaux.asserteq(ip[1].weight, 5, "srv1")
testaux.asserteq(ip[1].port, 5060, "srv1")
testaux.asserteq(ip[1].target, "test2.silly.gotocoding.com", "srv1")
testaux.asserteq(ip[2].priority, 1, "srv1")
testaux.asserteq(ip[2].weight, 6, "srv1")
testaux.asserteq(ip[2].port, 5061, "srv1")
testaux.asserteq(ip[2].target, "test1.silly.gotocoding.com", "srv1")
print("test guess")
testaux.asserteq(dns.isname("wwww.gotocoding.com"), true, "name")
testaux.asserteq(dns.isname("127.0.0.1"), false, "name")

