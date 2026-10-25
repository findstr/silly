local silly = require "silly"
local pcall = silly.pcall
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

---@class FakeRedisServer
---@field addr string
---@field listenfd silly.net.tcp.listener?
---@field clients table<silly.net.tcp.conn, boolean>
---@field handler function
---@field connections integer
---@field active integer
---@field accepted silly.sync.channel
---@field done silly.sync.channel
---@field errors string[]
local M = {}
M.__index = M

local function readcommand(client)
	local line, err = client:read("\n")
	if not line then
		return nil, err
	end
	local count = tonumber(line:match("^%*(%d+)\r\n$"))
	assert(count and count > 0, "invalid Redis request array")
	local parts = {}
	for i = 1, count do
		line, err = client:read("\n")
		if not line then
			return nil, err
		end
		local size = tonumber(line:match("^%$(%d+)\r\n$"))
		assert(size, "invalid Redis request bulk length")
		local data
		data, err = client:read(size + 2)
		if not data then
			return nil, err
		end
		assert(data:sub(-2) == "\r\n", "invalid Redis request bulk terminator")
		parts[i] = data:sub(1, -3)
	end
	return parts
end

function M.new(port)
	return setmetatable({
		addr = "127.0.0.1:" .. port,
		clients = {},
		connections = 0,
		active = 0,
		accepted = channel.new(),
		done = channel.new(),
		errors = {},
		handler = function()
			error("unexpected Redis request")
		end,
	}, M)
end

function M:handle_client(client, connection)
	local count = 0
	while true do
		local args = readcommand(client)
		if not args then
			return
		end
		count = count + 1
		local response = self.handler(args[1], args, count, client, connection)
		if response == false then
			return
		elseif response ~= nil then
			assert(type(response) == "string", "Redis peer must return wire bytes, nil or false")
			local ok = client:write(response)
			if not ok then
				return
			end
		end
	end
end

function M:start()
	local listener, err = tcp.listen {
		addr = self.addr,
		accept = function(client)
			self.connections = self.connections + 1
			self.active = self.active + 1
			self.clients[client] = true
			self.accepted:push(self.connections)
			local ok, failure = pcall(self.handle_client, self, client, self.connections)
			client:close()
			self.clients[client] = nil
			self.active = self.active - 1
			if not ok then
				self.errors[#self.errors + 1] = failure
			end
			self.done:push(true)
		end,
	}
	assert(listener, err)
	self.listenfd = listener
end

function M:stop()
	if self.listenfd then
		self.listenfd:close()
		self.listenfd = nil
	end
	for client in pairs(self.clients) do
		client:close()
	end
	while self.active > 0 do
		testaux.await(self.done, "Redis peer reader completed")
	end
	assert(#self.errors == 0, self.errors[1])
end

---The callback sees exact command bytes, including command-name case.
---Return wire bytes to reply, nil to keep reading, or false to close.
---@param handler fun(cmd:string, args:string[], count:integer, client:silly.net.tcp.conn, connection:integer):string|boolean|nil
function M:set_handler(handler)
	self.handler = handler
end

return M
