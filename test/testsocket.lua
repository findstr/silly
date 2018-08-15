local core = require "sys.core"
local socket = require "sys.socket"
local testaux = require "testaux"

local recv_sum = 0
local send_sum = 0
local recv_nr = 0
local send_nr = 0

local WAIT

local function testsend(fd, one, nr)
	print(string.format("-----test packet of %d count %d-----", one, nr))
	for i = 1, nr do
		local n = testaux.randomdata(one - 1) .. "\n"
		send_sum = testaux.checksum(send_sum, n)
		send_nr = send_nr + #n
		socket.write(fd, n)
	end
end

return function()
	local listenfd = socket.listen(":8990", function(fd, addr)
		while true do
			local n = socket.readline(fd)
			assert(n)
			recv_nr = recv_nr + #n
			recv_sum = testaux.checksum(recv_sum, n)
			if recv_nr == send_nr then
				if WAIT then
					core.wakeup(WAIT)
					return
				end
			end
		end
	end)
	local fd = socket.connect("127.0.0.1:8990")
	if not fd then
		print("connect fail:", fd)
		return
	end
	socket.limit(fd, 1024 * 1024 * 1024)
	assert(fd >= 0)
	local start = 8
	local total = 32 * 1024 * 1024
	for i = 1, 4 do
		local nr = total // start
		if nr > 1024 then
			nr = 1024
		end
		testsend(fd, start, nr)
		start = start * start
		if i ~= 4 then
			core.sleep(0)
		end
	end
	WAIT = core.running()
	core.wait(WAIT)
	testaux.asserteq(recv_nr, send_nr, "test socket send type count")
	testaux.asserteq(recv_sum, send_sum, "test socket send checksum")
	socket.close(listenfd)
	socket.close(fd)
end

