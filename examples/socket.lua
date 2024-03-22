local core = require "core"
local crypto = require "core.crypto"
local socket = require "core.net.tcp"

socket.listen("127.0.0.1:9999", function(fd, addr)
	print("accept", fd, addr)
	while true do
		local l = socket.readline(fd)
		if l then
			socket.write(fd, l)
		else
			break
		end
	end
end)

core.start(function()
	for i = 1, 3 do
		core.fork(function()
			local fd = socket.connect("127.0.0.1:9999")
			assert(fd)
			while true do
				local r = crypto.randomkey(5) .. "\n"
				print("send", fd, r)
				socket.write(fd, r)
				local l = socket.readline(fd)
				print("recv", fd, l)
				assert(l == r)
				core.sleep(1000)
			end
		end)
	end
end)

