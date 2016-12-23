local core = require "silly.core"
local socket = require "socket"
local P = require "print"
local rand = math.random
local recv_sum = 0
local send_sum = 0

local send_finish = false
local recv_nr = 0
local send_nr = 0

local data_pool = {}
local meta_str = "abcdefghijklmnopqrstuvwxyz"
local meta = {}
data_pool[1] = {}
for i = 1, #meta_str do
	meta[#meta + 1] = meta_str:sub(i, i)
end

math.randomseed(core.now())

local function randgen(sz)
	local tbl = {}
	for i = 1, sz do
		tbl[#tbl+1] = meta[rand(#meta)]
	end
	return table.concat(tbl, "") .. "\n"
end

local function sum(acc, str)
	for i = 1, #str do
		acc = acc + str:byte(i)
	end
	return acc
end

socket.listen("@8990", function(fd, addr)
	print(fd, "from", addr)
	while true do
		local n = socket.readline(fd)
		assert(n)
		recv_nr = recv_nr + #n
		recv_sum = sum(recv_sum, n)
		if send_finish and recv_nr >= send_nr then
			print(recv_sum, send_sum)
			P.bugon(recv_sum == send_sum, "!oh no, socket buffer has unkonwn bug")
			socket.write(fd, "!end\n")
			break
		end
	end
end)

local function testsend(fd, one, nr)
	print(string.format("----test packet of %d count %d-------", one, nr))
	for i = 1, nr do
		local n = randgen(one)
		send_sum = sum(send_sum, n)
		send_nr = send_nr + one
		socket.write(fd, n)
	end
end

return function()
	local fd = socket.connect("127.0.0.1@8990")
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
		core.sleep(0)
	end
	send_finish = true
	assert(socket.readline(fd) == "!end\n")
end

