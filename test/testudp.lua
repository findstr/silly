local core = require "sys.core"
local socket = require "sys.socket"
local crypt = require "sys.crypt"
local testaux = require "testaux"

local server_fd
local client_fd
local recvidx = 0
local queue = {}

local function udp_server(data, addr)
	core.sleep(100)
	socket.udpwrite(server_fd, data, addr)
end

local function udp_client(data, addr)
	recvidx = recvidx + 1
	testaux.asserteq(data, queue[recvidx], "udp data validate")
end

return function()
	server_fd = socket.bind(":8989", udp_server)
	testaux.asserteq(not server_fd, false, "upd bind")
	client_fd = socket.udp("127.0.0.1:8989", udp_client)
	testaux.asserteq(not client_fd, false, "udp bridge")
	for i = 1, 20 do
		local d = crypt.randomkey()
		queue[i] = d
		socket.udpwrite(client_fd, d)
		core.sleep(150)
	end
end

