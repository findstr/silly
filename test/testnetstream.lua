local ns = require "sys.netstream"

local function build(n)
	local tbl = {}
	for i = 1, n do
		tbl[i] = "a"
	end
	return table.concat(tbl)
end

return function()
	print("test rawpacket module")
	print("pack first", "hello")
	print("pack first", "a")
	print("pack second", "\\rworld\\ntail\\r\\n")

	local sb
	local fd = 3
	sb = ns.new(fd)
	ns.tpush(sb, fd, "hello")
	ns.tpush(sb, fd, "a")
	ns.tpush(sb, fd, "\rworld\ntail\r\n")

	local data = ns.read(sb, 1)
	print("read 1 byte:", data)
	data = ns.readline(sb, "a\r")
	print("read line terminated by 'a\\r'", data)
	print("terminated", data:byte(#data))
	print("====================")
	data = ns.readline(sb, "\n")
	print("read line terminated by '\\n'", data, "terminated", data:byte(#data))
	print("====================")
	data = ns.readline(sb, "\r\n")
	print("read line terminated by '\\r\\n'", data, "terminated", data:byte(#data - 1), data:byte(#data))
	print("====================")
	local push = {}
	for i = 1, 2 * 1024 * 64 do
		local dat = build(math.random(1, 33))
		push[#push + 1] = dat
		ns.tpush(sb, fd, dat)
		print("push", i)
	end
	local r1 = ns.read(sb, 1)
	local r2 = ns.readall(sb)
	assert(table.concat(push) == r1 .. r2)
end

