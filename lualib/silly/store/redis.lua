local task = require "silly.task"
local queue = require "silly.adt.queue"
local tcp = require "silly.net.tcp"
local mutex = require "silly.sync.mutex"
local type = type
local pairs = pairs
local assert = assert
local tostring = tostring
local tonumber = tonumber
local sub = string.sub
local upper = string.upper
local format = string.format
local qnew = queue.new
local qpush = queue.push
local qpop = queue.pop

---@class silly.store.redis
---@field addr string
---@field auth string
---@field db integer
---@field sock silly.net.tcp.conn|false
---@field readco thread|false
---@field waitq userdata
---@field new fun(config:{addr:string, auth:string, db:integer}):silly.store.redis
---@field select fun(self:silly.store.redis,)
---@field [string] fun(self, ...):boolean, string|table|nil
---@field close fun(self:silly.store.redis)
---@field closed boolean
local redis = {}
local redis_mt = { __index = redis }
local header = "+-:*$"
local response_header = {}
response_header[header:byte(1)] = function (sock, res)        --'+'
	return true, true, res
end
response_header[header:byte(2)] = function (sock, res)        --'-'
	return true, false, res
end
response_header[header:byte(3)] = function (sock, res)        --':'
	return true, true, tonumber(res)
end
response_header[header:byte(5)] = function (sock, res)        --'$'
	local nr = tonumber(res)
	if nr < 0 then
		return true, true, nil
	end
	local param = sock:read(nr + 2)
	return true, true, sub(param, 1, -3)
end
local function read_response(sock)
	local data, err = sock:read("\n")
	if err then
		return false, err, nil
	end
	local head = data:byte(1)
	local func = response_header[head]
	return func(sock, sub(data, 2, -3))
end

response_header[header:byte(4)] = function (sock, res)        --'*'
	local nr = tonumber(res)
	if nr < 0 then
		return true, true, nil
	end
	local cmd_success = true
	local cmd_res = {}
	for i = 1, nr do
		local ok, success, data = read_response(sock)
		if not ok then
			return false, success, nil
		end
		cmd_success = cmd_success and success
		cmd_res[i] = data
	end
	return true, cmd_success, cmd_res
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

local function handshake(sock, cmd, p1)
	local data = compose(cmd, {p1})
	local ok, err = sock:write(data)
	if not ok then
		return false, err
	end
	local ok, success, err = read_response(sock)
	if not ok then
		return false, success
	end
	return success, err
end

---@class silly.store.redis.connect.opts
---@field addr string
---@field auth string?
---@field db integer?

---@param config table
---@return silly.store.redis
function redis.new(config)
	local obj = {
		sock = false,
		addr = config.addr,
		auth = config.auth or "",
		db = config.db or 0,
		readco = false,
		waitq = qnew(),
		closed = false,
	}
	return setmetatable(obj, redis_mt)
end

function redis:close()
	if self.sock then
		self.sock:close()
		self.sock = false
	end
	self.closed = true
end

function redis:select()
	assert(not "please specify the db when redis.new")
end

local connect_lock = mutex.new()
---@param redis silly.store.redis
local function connect_to_redis(redis)
	local ok
	local l<close> = connect_lock:lock(redis)
	local sock = redis.sock
	if sock then
		return sock, nil
	end
	if redis.closed then
		return nil, "active closed"
	end
	local sock, err = tcp.connect(redis.addr)
	if not sock then
		return nil, err
	end
	local auth = redis.auth
	local db = redis.db
	if auth ~= "" then
		ok, err = handshake(sock, "AUTH", auth)
		if not ok then
			sock:close()
			return nil, err
		end
	end
	if db ~= 0 then
		ok, err = handshake(sock, "SELECT", db)
		if not ok then
			sock:close()
			return nil, err
		end
	end
	return sock, nil
end

---@param redis silly.store.redis
---@param err string
local function close_socket(redis, err)
	err = err or "unknown error"
	local sock = redis.sock
	if sock then
		sock:close()
		redis.sock = false
	end
	-- close_socket must be called by redis.readco
	-- so just directly set readco to nil
	assert(redis.readco == task.running())
	redis.readco = false
	local waitq = redis.waitq
	while true do
		local wco = qpop(waitq)
		if not wco then
			break
		end
		task.wakeup(wco, err)
	end
end

---@param redis silly.store.redis
local function wait_for_read(redis)
	local co = task.running()
	if redis.readco then -- already exist readco, enqueue for wait
		qpush(redis.waitq, co)
		local err = task.wait()
		if err then
			-- The socket is not closed here.
			-- because the waker handles errors and closes socket.
			return false, err
		end
		assert(redis.readco == co)
	else
		redis.readco = co
	end
	return true, nil
end

local function wakeup_next_reader(redis)
	local co = qpop(redis.waitq)
	if co then
		redis.readco = co
		task.wakeup(co)
	else
		redis.readco = false
	end
end

setmetatable(redis, {__index = function(self, k)
	local cmd = upper(k)
	local f = function (self, p1, ...)
		local ok, err
		local sock = self.sock
		if not sock then
			sock, err = connect_to_redis(self)
			if not sock then
				return false, err
			end
			self.sock = sock
		end
		local str
		if type(p1) == "table" then
			str = compose(cmd, p1)
		else
			str = compose(cmd, {p1, ...})
		end
		ok, err = sock:write(str)
		if not ok then
			close_socket(self, err)
			return false, err
		end
		ok, err =wait_for_read(self)
		if not ok then
			return false, err
		end
		local ok, success, res = read_response(sock)
		if not ok then
			close_socket(self, success)
			return false, success
		end
		wakeup_next_reader(self)
		return success, res
	end
	self[k] = f
	return f
end
})

function redis:call(cmd, p1, ...)
	return self[cmd](self, p1, ...)
end

---@param req table[]
---@return table[]?, string?
function redis:pipeline(req)
	local ok, err, res
	local sock = self.sock
	if not sock then
		sock, err = connect_to_redis(self)
		if not sock then
			return nil, err
		end
		self.sock = sock
	end
	local out = {}
	local cmd_len = #req
	for i = 1, cmd_len do
		composetable(req[i], out)
	end
	ok, err = self.sock:write(out)
	if not ok then
		return nil, err
	end
	ok, err = wait_for_read(self)
	if not ok then
		return nil, err
	end
	local results = {}
	local j = 1
	for i = 1, cmd_len do
		local ok, success, res = read_response(sock)
		if not ok then
			close_socket(self, success)
			return nil, success
		end
		results[j] = success
		results[j + 1] = res
		j = j + 2
	end
	wakeup_next_reader(self)
	return results, nil
end

return redis


