local rp = require "netstream"

return function()

	print("test rawpacket module")
	local pack1, sz1 = rp.pack("hello")
	print("pack first", "hello")
	local pack2, sz2 = rp.pack("a")
	print("pack first", "a")
	local pack3, sz3 = rp.pack("\rworld\ntail\r\n");
	print("pack second", "\\rworld\\ntail\\r\\n")

	local sb

	sb = rp.tpush(sb, 3, pack1, sz1)
	sb = rp.tpush(sb, 3, pack2, sz2)
	sb = rp.tpush(sb, 3, pack3, sz3)

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

