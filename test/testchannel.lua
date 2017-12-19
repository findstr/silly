local core = require "sys.core"
local channel = require "sys.channel"
local testaux = require "testaux"
local c1 = channel.channel()

local queue = {}

local function test()
	local n1, n2, n3, n4 = c1:pop2()
	local dat = table.remove(queue, 1)
	core.fork(test)
	testaux.asserteq(n1, dat[1], "channel test dat[1]")
	testaux.asserteq(n2, dat[2], "channel test dat[2]")
	testaux.asserteq(n3, dat[3], "channel test dat[3]")
	testaux.asserteq(n4, dat[4], "channel test dat[4]")
	core.sleep(1)
end

core.fork(test)

return function()
	local a, b, c, d
	core.sleep(10)
	for i = 1, 3 do
		a = "hello" .. i
		b = nil
		c = "world" .. i
		d = nil
		table.insert(queue, table.pack(a, b, c, d))
		c1:push2(a, b, c, d)
	end
	core.sleep(1000)
	for i = 4, 6 do
		a = "hello" .. i
		b = nil
		c = "world" .. i
		d = nil
		table.insert(queue, table.pack(a, b, c, d))
		c1:push2(a, b, c, d)
		core.sleep(1)
	end
end

