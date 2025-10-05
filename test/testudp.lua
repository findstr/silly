local silly = require "silly"
local time = require "silly.time"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"
local crypto = require "silly.crypto.utils"
local testaux = require "test.testaux"

local server_fd
local client_fd

local wg = waitgroup.new()

server_fd = udp.bind("127.0.0.1:8989")
wg:fork(function()
	while true do
		local data, addr = udp.recvfrom(server_fd)
		if not data then
			break
		end
		time.sleep(200)
		udp.sendto(server_fd, data, addr)
	end
end)
testaux.asserteq(not server_fd, false, "upd bind")
client_fd = udp.connect("127.0.0.1:8989")
testaux.asserteq(not client_fd, false, "udp bridge")
local buf = {}
for i = 1, 20 do
	local d = crypto.randomkey(8)
	udp.sendto(client_fd, d)
	buf[i] = d
end
for i = 1, 20 do
	local data = udp.recvfrom(client_fd)
	testaux.asserteq(data, buf[i], "udp data validate")
	time.sleep(150)
end

wg:fork(function()
	local fd = udp.connect("127.0.0.1:1998")
	local ok = udp.sendto(fd, "Hello, UDP!")
	print("Sent data to", ok)
	time.sleep(1000)
	local ok = udp.sendto(fd, "Hello, UDP!")
	print("Sent data to", ok)
end)

udp.close(client_fd)
udp.close(server_fd)
wg:wait()
print("testudp ok")