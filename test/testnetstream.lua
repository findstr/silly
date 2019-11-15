local ns = require "sys.netstream"
local testaux = require "testaux"

local function build(n)
	local tbl = {}
	for i = 1, n do
		tbl[i] = "a"
	end
	return table.concat(tbl)
end

return function()
	local sb
	local fd = 3
	sb = ns.new(fd)
	print("push", "hello")
	ns.tpush(sb, fd, "hello")
	print("push", "a")
	ns.tpush(sb, fd, "a")
	print("push", "\\rworld\\ntail\\r\\n")
	ns.tpush(sb, fd, "\rworld\ntail\r\n")

	local data = ns.read(sb, 1)
	print("read 1 byte:", data)
	testaux.asserteq(data, "a", "data == 'a'")

	data = ns.readline(sb, "a\r")
	print("read line terminated by 'a\\r'", data)
	testaux.asserteq(data, "elloa\r", "data == 'elloa\r'")

	data = ns.readline(sb, "\n")
	print("read line terminated by '\\n'", data)
	testaux.asserteq(data, "world\n", "data == 'world\n'")

	data = ns.readline(sb, "\r\n")
	print("read line terminated by '\\r\\n'", data)
	testaux.asserteq(data, "tail\r\n", "data == 'tail\r\n'")

	local push = {}
	for i = 1, 2 * 1024 * 64 do
		local dat = build(math.random(1, 33))
		push[#push + 1] = dat
		ns.tpush(sb, fd, dat)
	end
	local r1 = ns.read(sb, 1)
	local r2 = ns.read(sb, math.random(1, 1024))
	local r3 = ns.readall(sb)
	testaux.asserteq(table.concat(push), r1 .. r2 .. r3,
		"table.concat(push) == r1 .. r2 .. r3")
end

