local logger = require "core.logger"
local dispatch = require "core.socketq"
local type = type
local assert = assert
local tostring = tostring
local tonumber = tonumber
local sub = string.sub
local upper = string.upper
local format = string.format

---@class core.db.redis
---@field sock core.socketq
---@field new fun(config:{addr:string, auth:string, db:integer}):core.db.redis
---@field select fun(self:core.db.redis,)
---@field [string] fun(self, ...):boolean, string|table|nil
---@field close fun(self:core.db.redis)
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
	if nr < 0 then
		return true, nil
	end
	local param = sock:read(nr + 2)
	return true, sub(param, 1, -3)
end


local function read_response(sock)
	local data = sock:readline("\r\n")
	local head = data:byte(1)
	local func = response_header[head]
	return func(sock, sub(data, 2, -3))
end

response_header[header:byte(4)] = function (sock, res)        --'*'
	local nr = tonumber(res)
	if nr < 0 then
		return true, nil
	end
	local cmd_success = true
	local cmd_res = {}
	for i = 1, nr do
		local success, data = read_response(sock)
		cmd_success = cmd_success and success
		cmd_res[i] = data
	end
	return cmd_success, cmd_res
end

local function cache_(func)
	return setmetatable({}, { __mode = "kv", __index = func })
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

local function compose(cmd, param)
	assert(type(param) == "table")
	local count = #param
	local lines = {
		cache_head[count + 1],
		cache_count[#cmd],
		cmd,
	}
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

local function composetable(cmd, out)
	local len = #cmd
	local oi = #out + 1
	out[oi] = cache_head[len]
	oi = oi + 1
	for i = 1, len do
		local v = tostring(cmd[i])
		out[oi] = cache_count[#v]
		oi = oi + 1
		out[oi] = v
		oi = oi + 1
	end
	out[oi] = "\r\n"
end

local function redis_login(auth, db)
	if not auth and not db then
		return
	end
	return function(sock)
		local ok, err
		if auth then
			local req = format("AUTH %s\r\n", auth)
			ok, err = sock:request(req, read_response)
			if not ok then
				return ok, err
			end
		end
		if db then
			local req = format("SELECT %s\r\n", db)
			ok, err = sock:request(req, read_response)
			if not ok then
				return ok, err
			end
		end
		return true
	end
end

---@param config table
---@return core.db.redis
function redis.new(config)
	local obj = {
		sock = dispatch.new {
			addr = config.addr,
			auth = redis_login(config.auth, config.db)
		},
	}
	return setmetatable(obj, redis_mt)
end

function redis:close()
	self.sock:close()
end

function redis:select()
	assert(~"please specify the dbid when redis:create")
end

setmetatable(redis, {__index = function (self, k)
	local cmd = upper(k)
	local f = function (self, p1, ...)
		local str
		if type(p1) == "table" then
			str = compose(cmd, p1)
		else
			str = compose(cmd, {p1, ...})
		end
		return self.sock:request(str, read_response)
	end
	self[k] = f
	return f
end
})

function redis:call(cmd, p1, ...)
	return self[cmd](self, p1, ...)
end
function redis:pipeline(req, ret)
	local out = {}
	local cmd_len = #req
	for i = 1, cmd_len do
		composetable(req[i], out)
	end
	if not ret then
		return self.sock:request(out, function(sock)
			local ok, res
			for i = 1, cmd_len do
				ok, res = read_response(sock)
				if not ok then
					logger.error('[redis] pipeline error',
						res
					)
				end
			end
			return ok, res
		end)
	end
	return self.sock:request(out, function(sock)
		local ok, res
		local j = 0
		for i = 1, cmd_len do
			ok, res = read_response(sock)
			j = j + 1
			ret[j] = ok
			j = j + 1
			ret[j] = res
		end
		return true, j
	end)
end

return redis


