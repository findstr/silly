local silly = require "silly"
local tcp = require "silly.net.tcp"

---@class FakeRedisServer
---@field port integer
---@field listenfd silly.net.tcp.listener
---@field clients table<silly.net.tcp.conn, boolean>
---@field handler function|nil -- Custom command handler
local M = {}

---@param port integer
function M.new(port)
	local server = {
		port = port or 16379,
		clients = {},
		handler = nil,
	}
	setmetatable(server, {__index = M})
	return server
end

function M:start()
	self.listenfd = tcp.listen {
		addr = "127.0.0.1:" .. self.port,
		callback = function(client)
			self.clients[client] = true
			silly.fork(function()
				self:handle_client(client)
			end)
		end
	}
end

function M:handle_client(client)
	local client_command_count = 0

	while true do
		-- Read command line
		local line, err = client:readline("\n")
		if err then
			self.clients[client] = nil
			client:close()
			break
		end

		-- Parse RESP protocol (simplified)
		if line:match("^%*") then
			local count = tonumber(line:match("%*(%d+)"))
			local cmd_parts = {}
			for i = 1, count do
				local len_line, err = client:readline("\n")
				if err then break end
				local len = tonumber(len_line:match("%$(%d+)"))
				local data, err = client:read(len + 2) -- +2 for \r\n
				if err then break end
				cmd_parts[i] = data:sub(1, -3) -- Remove \r\n
			end

			client_command_count = client_command_count + 1
			local cmd = cmd_parts[1] and cmd_parts[1]:upper()

			-- Call custom handler if set
			local response
			if self.handler then
				response = self.handler(cmd, cmd_parts, client_command_count, client)
			else
				-- Default simple responses
				if cmd == "PING" then
					response = "+PONG\r\n"
				elseif cmd == "SET" then
					response = "+OK\r\n"
				elseif cmd == "GET" then
					response = "$3\r\nbar\r\n"
				elseif cmd == "SELECT" then
					response = "+OK\r\n"
				elseif cmd == "AUTH" then
					response = "+OK\r\n"
				elseif cmd == "DEL" then
					response = ":1\r\n"
				elseif cmd == "FLUSHDB" then
					response = "+OK\r\n"
				else
					response = "-ERR unknown command '" .. (cmd or "nil") .. "'\r\n"
				end
			end

			-- Handle response
			if response == false then
				-- false means close connection
				client:close()
				self.clients[client] = nil
				break
			elseif response == nil then
				-- nil means don't respond (hang)
				-- Continue reading next command
			elseif type(response) == "string" then
				-- Send response
				local ok = client:write(response)
				if not ok then
					self.clients[client] = nil
					client:close()
					break
				end
			end
		end
	end
end

function M:stop()
	-- Close all client connections
	for client in pairs(self.clients) do
		client:close()
	end
	self.clients = {}

	-- Close listen socket
	if self.listenfd then
		self.listenfd:close()
		self.listenfd = nil
	end
end

---Set custom command handler
---@param handler fun(cmd: string, args: table, command_count: number, client: any): string|boolean|nil
---  - Return string: send as response
---  - Return false: close connection
---  - Return nil: don't respond (hang)
---  - Handler can also use client:write() directly for partial responses
function M:set_handler(handler)
	self.handler = handler
end

return M
