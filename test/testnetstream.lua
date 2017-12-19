local rp = require "sys.netstream"
local testaux = require "testaux"

return function()
	print("test rawpacket module")
	print("pack first", "hello")
	print("pack first", "a")
	print("pack second", "\\rworld\\ntail\\r\\n")

	local sb

	sb = rp.tpush(sb, 3, "hello")
	sb = rp.tpush(sb, 3, "a")
	sb = rp.tpush(sb, 3, "\rworld\ntail\r\n")

	local data = rp.read(sb, 1)
	testaux.asserteq(data, "h", "netstream read 1 byte")
	data = rp.readline(sb, "a\r")
	testaux.asserteq(data, "elloa\r", "netstream read line terminated by 'a\\r'")
	data = rp.readline(sb, "\n")
	testaux.asserteq(data, "world\n", "netstream read line terminated by '\\n'")
	data = rp.readline(sb, "\r\n")
	testaux.asserteq(data, "tail\r\n", "netstream read line terminated by '\\r\\n'")
end

