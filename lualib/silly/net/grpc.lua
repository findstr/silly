local conn = require "silly.net.grpc.client.conn"
local service = require "silly.net.grpc.client.service"
local server = require "silly.net.grpc.server"

local M = {
	newclient = conn.new,
	newservice = service,
	listen = server,
}

return M

