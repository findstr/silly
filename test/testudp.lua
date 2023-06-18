local core = require "sys.core"
local udp = require "sys.net.udp"
local crypto = require "sys.crypto"
local testaux = require "testaux"

local server_fd
local client_fd
local recvidx = 0
local queue = {}

local function udp_server(data, addr)
	core.sleep(100)
	udp.send(server_fd, data, addr)
end

local function udp_client(data, addr)
	recvidx = recvidx + 1
	testaux.asserteq(data, queue[recvidx], "udp data validate")
end

return function()
	server_fd = udp.bind(":8989", udp_server)
	testaux.asserteq(not server_fd, false, "upd bind")
	client_fd = udp.connect("127.0.0.1:8989", udp_client)
	testaux.asserteq(not client_fd, false, "udp bridge")
	for i = 1, 20 do
		local d = crypto.randomkey(8)
		queue[i] = d
		udp.send(client_fd, d)
		core.sleep(150)
	end
end

