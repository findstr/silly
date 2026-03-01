local addr = require "silly.net.addr"
local testaux = require "test.testaux"

---------- parse ----------

testaux.case("Test 1: parse IPv4 with port", function()
	local host, port = addr.parse("127.0.0.1:8080")
	testaux.asserteq(host, "127.0.0.1", "Test 1.1: host")
	testaux.asserteq(port, "8080", "Test 1.2: port")
end)

testaux.case("Test 2: parse IPv4 without port", function()
	local host, port = addr.parse("192.168.1.1")
	testaux.asserteq(host, "192.168.1.1", "Test 2.1: host")
	testaux.asserteq(port, nil, "Test 2.2: port nil")
end)

testaux.case("Test 3: parse hostname with port", function()
	local host, port = addr.parse("example.com:443")
	testaux.asserteq(host, "example.com", "Test 3.1: host")
	testaux.asserteq(port, "443", "Test 3.2: port")
end)

testaux.case("Test 4: parse hostname without port", function()
	local host, port = addr.parse("example.com")
	testaux.asserteq(host, "example.com", "Test 4.1: host")
	testaux.asserteq(port, nil, "Test 4.2: port nil")
end)

testaux.case("Test 5: parse bracketed IPv6 with port", function()
	local host, port = addr.parse("[::1]:8080")
	testaux.asserteq(host, "::1", "Test 5.1: host")
	testaux.asserteq(port, "8080", "Test 5.2: port")
end)

testaux.case("Test 6: parse bracketed IPv6 without port", function()
	local host, port = addr.parse("[::1]")
	testaux.asserteq(host, "::1", "Test 6.1: host")
	testaux.asserteq(port, nil, "Test 6.2: port nil")
end)

testaux.case("Test 7: parse full IPv6 with port", function()
	local host, port = addr.parse("[2001:db8::1]:80")
	testaux.asserteq(host, "2001:db8::1", "Test 7.1: host")
	testaux.asserteq(port, "80", "Test 7.2: port")
end)

testaux.case("Test 8: parse edge cases", function()
	-- empty host with port
	local host, port = addr.parse(":8080")
	testaux.asserteq(host, nil, "Test 8.1: empty host is nil")
	testaux.asserteq(port, "8080", "Test 8.2: port")

	-- 0.0.0.0 with port
	host, port = addr.parse("0.0.0.0:0")
	testaux.asserteq(host, "0.0.0.0", "Test 8.3: all-zero host")
	testaux.asserteq(port, "0", "Test 8.4: zero port")

	-- named port (underscore/alphanumeric pattern)
	host, port = addr.parse("localhost:http_s")
	testaux.asserteq(host, "localhost", "Test 8.5: host with named port")
	testaux.asserteq(port, "http_s", "Test 8.6: named port")

	-- single char host
	host, port = addr.parse("a:80")
	testaux.asserteq(host, "a", "Test 8.7: single char host")
	testaux.asserteq(port, "80", "Test 8.8: port")

	-- subdomain with port
	host, port = addr.parse("a.b.c.d:9999")
	testaux.asserteq(host, "a.b.c.d", "Test 8.9: subdomain host")
	testaux.asserteq(port, "9999", "Test 8.10: port")
end)

testaux.case("Test 9: parse bracketed IPv6 edge cases", function()
	-- empty brackets with port
	local host, port = addr.parse("[]:80")
	testaux.asserteq(host, nil, "Test 9.1: empty bracket host is nil")
	testaux.asserteq(port, "80", "Test 9.2: port")

	-- empty brackets without port
	host, port = addr.parse("[]")
	testaux.asserteq(host, nil, "Test 9.3: empty bracket host no port is nil")
	testaux.asserteq(port, nil, "Test 9.4: port nil")

	-- full IPv6 address
	host, port = addr.parse("[fe80::1%25eth0]:443")
	testaux.asserteq(host, "fe80::1%25eth0", "Test 9.5: IPv6 with zone ID")
	testaux.asserteq(port, "443", "Test 9.6: port")

	-- bracket without closing (starts with '[' but no ']')
	host, port = addr.parse("[broken")
	testaux.asserteq(host, nil, "Test 9.7: malformed bracket returns nil host")
	testaux.asserteq(port, nil, "Test 9.8: malformed bracket returns nil port")

	-- bracket with content but no closing bracket and colon port
	host, port = addr.parse("[::1:80")
	testaux.asserteq(host, nil, "Test 9.9: unclosed bracket nil host")
	testaux.asserteq(port, nil, "Test 9.10: unclosed bracket nil port")
end)

---------- join ----------

testaux.case("Test 10: join IPv4", function()
	local result = addr.join("127.0.0.1", "8080")
	testaux.asserteq(result, "127.0.0.1:8080", "Test 10.1: IPv4 join")
end)

testaux.case("Test 11: join hostname", function()
	local result = addr.join("example.com", "443")
	testaux.asserteq(result, "example.com:443", "Test 11.1: hostname join")
end)

testaux.case("Test 12: join IPv6 auto-brackets", function()
	local result = addr.join("::1", "8080")
	testaux.asserteq(result, "[::1]:8080", "Test 12.1: IPv6 gets brackets")

	result = addr.join("2001:db8::1", "80")
	testaux.asserteq(result, "[2001:db8::1]:80", "Test 12.2: full IPv6 gets brackets")
end)

testaux.case("Test 13: join already-bracketed IPv6", function()
	local result = addr.join("[::1]", "8080")
	testaux.asserteq(result, "[::1]:8080", "Test 13.1: no double brackets")
end)

testaux.case("Test 14: join empty host", function()
	local result = addr.join("", "8080")
	testaux.asserteq(result, ":8080", "Test 14.1: empty host")

	result = addr.join(nil, "8080")
	testaux.asserteq(result, ":8080", "Test 14.2: nil host")
end)

testaux.case("Test 15: join round-trip with parse", function()
	-- IPv4
	local host, port = addr.parse("10.0.0.1:3306")
	local result = addr.join(host, port)
	testaux.asserteq(result, "10.0.0.1:3306", "Test 15.1: IPv4 round-trip")

	-- hostname
	host, port = addr.parse("redis.local:6379")
	result = addr.join(host, port)
	testaux.asserteq(result, "redis.local:6379", "Test 15.2: hostname round-trip")

	-- bracketed IPv6
	host, port = addr.parse("[::1]:5432")
	result = addr.join(host, port)
	testaux.asserteq(result, "[::1]:5432", "Test 15.3: IPv6 round-trip")
end)

---------- isv4 ----------

testaux.case("Test 16: isv4", function()
	testaux.asserteq(addr.isv4("127.0.0.1"), true, "Test 16.1: loopback")
	testaux.asserteq(addr.isv4("192.168.1.1"), true, "Test 16.2: private")
	testaux.asserteq(addr.isv4("0.0.0.0"), true, "Test 16.3: all zeros")
	testaux.asserteq(addr.isv4("255.255.255.255"), true, "Test 16.4: broadcast")
	testaux.asserteq(addr.isv4("1"), false, "Test 16.5: single digit")

	testaux.asserteq(addr.isv4("::1"), false, "Test 16.6: IPv6 is not v4")
	testaux.asserteq(addr.isv4("example.com"), false, "Test 16.7: hostname is not v4")
	testaux.asserteq(addr.isv4(""), false, "Test 16.8: empty string")
	testaux.asserteq(addr.isv4("192.168.1.1a"), false, "Test 16.9: trailing alpha")
end)

---------- isv6 ----------

testaux.case("Test 17: isv6", function()
	testaux.asserteq(addr.isv6("::1"), true, "Test 17.1: loopback")
	testaux.asserteq(addr.isv6("2001:db8::1"), true, "Test 17.2: full address")
	testaux.asserteq(addr.isv6("fe80::1"), true, "Test 17.3: link-local")
	testaux.asserteq(addr.isv6("::"), true, "Test 17.4: all zeros")
	testaux.asserteq(addr.isv6("1"), false, "Test 17.5: single digit")

	testaux.asserteq(addr.isv6("127.0.0.1"), false, "Test 17.6: IPv4 is not v6")
	testaux.asserteq(addr.isv6("example.com"), false, "Test 17.7: hostname is not v6")
	testaux.asserteq(addr.isv6(""), false, "Test 17.8: empty string")
end)

---------- ishost ----------

testaux.case("Test 18: ishost", function()
	testaux.asserteq(addr.ishost("example.com"), true, "Test 18.1: domain")
	testaux.asserteq(addr.ishost("localhost"), true, "Test 18.2: localhost")
	testaux.asserteq(addr.ishost("a.b.c"), true, "Test 18.3: subdomain")
	testaux.asserteq(addr.ishost("host123"), true, "Test 18.4: alphanumeric")
	testaux.asserteq(addr.ishost("my-host"), true, "Test 18.5: with hyphen")
	testaux.asserteq(addr.ishost("1-2-3"), true, "Test 18.6: digits with hyphen")
	testaux.asserteq(addr.ishost("12345"), true, "Test 18.7: pure digits is host")

	testaux.asserteq(addr.ishost("127.0.0.1"), false, "Test 18.8: IPv4 is not host")
	testaux.asserteq(addr.ishost("::1"), false, "Test 18.9: IPv6 is not host")
	testaux.asserteq(addr.ishost(""), false, "Test 18.10: empty string")
end)

---------- iptype ----------

testaux.case("Test 19: iptype", function()
	testaux.asserteq(addr.iptype("127.0.0.1"), 4, "Test 19.1: IPv4 loopback")
	testaux.asserteq(addr.iptype("0.0.0.0"), 4, "Test 19.2: IPv4 all-zeros")
	testaux.asserteq(addr.iptype("255.255.255.255"), 4, "Test 19.3: IPv4 broadcast")
	testaux.asserteq(addr.iptype("::1"), 6, "Test 19.4: IPv6 loopback")
	testaux.asserteq(addr.iptype("2001:db8::1"), 6, "Test 19.5: IPv6 full")
	testaux.asserteq(addr.iptype("::"), 6, "Test 19.6: IPv6 all-zeros")
	testaux.asserteq(addr.iptype("example.com"), 0, "Test 19.7: hostname is 0")
	testaux.asserteq(addr.iptype("localhost"), 0, "Test 19.8: localhost is 0")
	testaux.asserteq(addr.iptype("999.999.999.999"), 0, "Test 19.9: invalid IPv4 is 0")
	testaux.asserteq(addr.iptype("cafe:babe"), 0, "Test 19.10: invalid IPv6 is 0")
	testaux.asserteq(addr.iptype(""), 0, "Test 19.11: empty string is 0")
end)
