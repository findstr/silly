local dispatch = require "socketdispatch"

local tostring = tostring
local tonumber = tonumber
local tinsert = table.insert
local tunpack = table.unpack
local tconcat = table.concat
local sub = string.sub
local upper = string.upper
local format = string.format

local redis = {}
local redis_mt = { __index = redis }
local header = "+-:*$"
local response_header = {}

response_header[header:byte(1)] = function (sock, res)        --'+'
	return true, res
end

response_header[header:byte(2)] = function (sock, res)        --'-'
	return false, res
end

response_header[header:byte(3)] = function (sock, res)        --':'
	return true, tonumber(res)
end

response_header[header:byte(5)] = function (sock, res)        --'$'
	local nr = tonumber(res)
	if nr == -1 then
		return false, nil
	end
	local param = sock:read(nr + 2)
	return true, sub(param, 1, -3)
end


local function read_response(sock)
	local data = sock:readline("\r\n")
	local head = data:byte(1)
	local func = response_header[head]
	return func(sock, sub(data, 2))
end

response_header[header:byte(4)] = function (sock, res)        --'*'
	local nr = tonumber(res)
	if nr ~= 1 then
		local cmd_success = true
		local cmd_res = {}
		for i = 1, nr do
			local success, data = read_response(sock)
			cmd_success = cmd_success and success
			tinsert(cmd_res, data)
		end
		return cmd_success, cmd_res
	else
		return read_response(sock)
	end
end

local function cache_(func)
	return setmetatable({}, { mode = "kv", __index = func })
end

local cache_head = cache_(function (self, key)
	local s = format("*%d", key)
	self[key] = s
	return s
end)

local cache_count = cache_(function (self, key)
	local s = format("\r\n$%d\r\n", key)
	self[key] = s
	return s
end)

local function pack_cmd(cmd, param)
	assert(type(param) == "table")
	local count = #param
	local lines = {}
	lines[1] = cache_head[count + 1]
	lines[2] = cache_count[#cmd]
	lines[3] = cmd
	local idx = 4
	for i = 1, count do
		local v = tostring(param[i])
		lines[idx] = cache_count[#v]
		idx = idx + 1
		lines[idx] = v
		idx = idx + 1
	end
	lines[idx] = "\r\n"
	return lines
end

function redis:connect(config)
	local obj = {
		addr = config.addr,
		user = config.user,
		passwd = config.passwd,
		sock = dispatch:create {
			addr = config.addr,
		},
	}
	setmetatable(obj, redis_mt)
	local ret, err = obj.sock:connect()
	if ret then
		return obj
	else
		return nil, err
	end
end

setmetatable(redis, {__index = function (self, k)
	local cmd = upper(k)
	local f = function (self, p, ...)
		if type(p) == "table" then
			local str = pack_cmd(cmd, p)
			return self.sock:request(str, read_response)
		else
			local str = pack_cmd(cmd, {p, ...})
			return self.sock:request(str, read_response)
		end
	end
	self[k] = f
	return f
end
})


return redis


