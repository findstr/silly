local core = require "sys.core"
local socket = require "sys.socket"
local testaux = require "testaux"

local wait = true
local a,b,c

socket.listen(":10005", function(fd, addr)
	print("s:accept", fd)
	socket.limit(fd, 0xffffffff)
	socket.readctrl(fd, "disable")
	print("s:readctrl", fd, "disable")
	core.sleep(10000)
	local dat = socket.readall(fd)
	print("s:read first", fd, ":", #dat, "$")
	socket.readctrl(fd, "enable")
	core.sleep(5000)
	local dat = socket.readall(fd)
	print("s:read second", fd, ":", #dat, "$")
	testaux.asserteq(dat, a..b..c, "s:verify")
	wait = false
end)

return function()
	local fd = socket.connect("127.0.0.1:10005")
	print("c:connect", fd)
	core.sleep(1000)
	a = testaux.randomdata(1024*1024*20)
	b = testaux.randomdata(1024*1024*20)
	c = testaux.randomdata(1024*1024*20)
	socket.write(fd, a)
	print("c:send", fd, #a)
	socket.write(fd, b)
	print("c:send", fd, #b)
	socket.write(fd, c)
	print("c:send", fd, #c)
	core.sleep(10)
	local m = core.sendsize(fd)
	print("c:m", m)
	testaux.assertle(1, m, "c:send size first="..m)
	core.sleep(2000)
	local n = core.sendsize(fd)
	print("c:n", n)
	testaux.assertle(0, n, "c:send size second="..n)
	core.sleep(1000)
	socket.close(fd)
	while wait do
		core.sleep(100)
	end
end

