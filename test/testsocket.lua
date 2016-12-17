local core = require "silly.core"
local socket = require "socket"

socket.listen("@8990", function(fd, addr)
	print(fd, "from", addr)
	while true do
		local n = socket.readline(fd)
		if not n then
			break
		end
		print(n)
		socket.write(fd, n)
	end
end)

return function()
	local fd = socket.connect("127.0.0.1@8990")
	if not fd then
		print("connect fail:", fd)
		return
	end
	assert(fd >= 0)
	socket.write(fd, "helloworld\n")
	local p = socket.read(fd, 2)
	assert(p == "he")
	p = socket.read(fd, 5)
	assert(p == "llowo")
	p = socket.read(fd, 2)
	assert(p == "rl")
	p = socket.readline(fd)
	assert(p == "d\n", p)
	core.close(fd)
	print("test ok")
end

