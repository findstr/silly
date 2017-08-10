local rp = require "netstream"

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
	print("read 1 byte:", data)
	data = rp.readline(sb, "a\r")
	print("read line terminated by 'a\\r'", data)
	print("terminated", data:byte(#data))
	print("====================")
	data = rp.readline(sb, "\n")
	print("read line terminated by '\\n'", data, "terminated", data:byte(#data))
	print("====================")
	data = rp.readline(sb, "\r\n")
	print("read line terminated by '\\r\\n'", data, "terminated", data:byte(#data - 1), data:byte(#data))
	print("====================")
end

