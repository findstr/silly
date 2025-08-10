local core = require "core"
local crypto = require "core.crypto"
local socket = require "core.net.tcp"

socket.listen("127.0.0.1:9999", function(fd, addr)
	print("accept", fd, addr)
	while true do
		local l, err = socket.readline(fd)
		if not l then
			print("read from", fd, "error:", err or "closed")
			break
		end
		local ok, werr = socket.write(fd, l)
		if not ok then
			print("write to", fd, "error:", werr)
			break
		end
	end
	print("close", fd)
	socket.close(fd)
end)

core.start(function()
	for i = 1, 3 do
		core.fork(function()
			local fd, err = socket.connect("127.0.0.1:9999")
			if not fd then
				print("connect error:", err)
				return
			end
		-- run 5 times for test
		for _ = 1, 5 do
			local r = crypto.randomkey(5) .. "\n"
			print("send", fd, r)
			local ok, werr = socket.write(fd, r)
			if not ok then
				print("write to", fd, "error:", werr)
				break
			end
			local l, rerr = socket.readline(fd)
			if not l then
				print("read from", fd, "error:", rerr or "closed")
				break
			end
			print("recv", fd, l)
			assert(l == r)
			core.sleep(1000)
		end
		print("close", fd)
		socket.close(fd)
		end)
	end
end)

