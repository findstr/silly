local core = require "silly.core"
local socket = require "socket"
local crypt = require "crypt"
local server_fd
local client_fd

local D = nil

local function udp_server(data, addr)
	print("#server", data, #addr)
	core.sleep(100)
	socket.udpwrite(server_fd, data, addr)
end

local function udp_client(data, addr)
	print("#client", data, #addr)
	assert(data == D)
end

return function()
	server_fd = socket.bind("@8989", udp_server)
	assert(server_fd)
	client_fd = socket.udp("127.0.0.1@8989", udp_client)
	assert(client_fd)
	for i = 1, 20 do
		D = crypt.randomkey()
		socket.udpwrite(client_fd, D)
		core.sleep(150)
	end
	print("testudp ok")
end

