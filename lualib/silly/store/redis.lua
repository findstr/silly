local task = require "silly.task"
local queue = require "silly.adt.queue"
local tcp = require "silly.net.tcp"
local mutex = require "silly.sync.mutex"
local errno = require "silly.errno"
local type = type
local assert = assert
local tostring = tostring
local tonumber = tonumber
local numtype = math.type
local sub = string.sub
local upper = string.upper
local format = string.format
local qnew = queue.new
local qpush = queue.push
local qpop = queue.pop
local ECLOSED<const> = errno.CLOSED
local MAX_BULK<const> = 0x7ffffffd
local MAX_DEPTH<const> = 128

---@class silly.store.redis.session
---@field sock silly.net.tcp.conn
---@field readco thread|false
---@field waitq silly.adt.queue
---@field err string|silly.errno|nil

---@class silly.store.redis
---@field addr string
---@field auth string
---@field db integer
---@field package sock silly.net.tcp.conn|false
---@field package session silly.store.redis.session|false
---@field package connecting silly.net.tcp.conn|false
---@field package closed boolean
---@field [string] fun(self:silly.store.redis, ...):boolean, string|number|table|nil
local redis = {}
local redis_mt = {__index = redis}
local response_header = {}

local function protocol_error(reason)
	return false, "Redis protocol error: " .. reason, nil
end

local function length(res, limit)
	if res == "-1" then
		return -1
	end
	if not res:match("^%d+$") then
		return nil
	end
	local nr = tonumber(res)
	if numtype(nr) ~= "integer" or nr > limit then
		return nil
	end
	return nr
end

response_header[string.byte("+")] = function(sock, res)
	return true, true, res
end
response_header[string.byte("-")] = function(sock, res)
	return true, false, res
end
response_header[string.byte(":")] = function(sock, res)
	if not res:match("^[+-]?%d+$") then
		return protocol_error("invalid integer")
	end
	local nr = tonumber(res)
	if numtype(nr) ~= "integer" then
		return protocol_error("integer out of range")
	end
	return true, true, nr
end
response_header[string.byte("$")] = function(sock, res)
	local nr = length(res, MAX_BULK)
	if not nr then
		return protocol_error("invalid bulk length")
	end
	if nr == -1 then
		return true, true, nil
	end
	local param, err = sock:read(nr + 2)
	if not param then
		return false, err, nil
	end
	if sub(param, -2) ~= "\r\n" then
		return protocol_error("invalid bulk terminator")
	end
	return true, true, sub(param, 1, -3)
end

local function read_response(sock, depth)
	local data, err = sock:read("\n")
	if not data then
		return false, err, nil
	end
	if sub(data, -2) ~= "\r\n" then
		return protocol_error("invalid line terminator")
	end
	local func = response_header[data:byte(1)]
	if not func then
		return protocol_error("unsupported reply type")
	end
	local res = sub(data, 2, -3)
	if res:find("\r", 1, true) then
		return protocol_error("invalid line content")
	end
	return func(sock, res, depth or 0)
end

response_header[string.byte("*")] = function(sock, res, depth)
	local nr = length(res, 0x7fffffff)
	if not nr then
		return protocol_error("invalid array length")
	end
	if nr == -1 then
		return true, true, nil
	end
	if depth >= MAX_DEPTH then
		return protocol_error("array nesting limit exceeded")
	end
	local success = true
	local result = {}
	for i = 1, nr do
		local ok, item_success, data = read_response(sock, depth + 1)
		if not ok then
			return false, item_success, nil
		end
		success = success and item_success
		result[i] = data
	end
	return true, success, result
end

local unsupported = {
	SUBSCRIBE = true,
	PSUBSCRIBE = true,
	SSUBSCRIBE = true,
	UNSUBSCRIBE = true,
	PUNSUBSCRIBE = true,
	SUNSUBSCRIBE = true,
	MONITOR = true,
}

local function check_command(cmd, p1, p2)
	if unsupported[cmd] then
		return "Redis command is not supported: " .. cmd
	end
	if cmd == "HELLO" and p1 and p1 ~= "2" then
		return "Redis client only supports RESP2"
	end
	if cmd == "CLIENT" and p1 and upper(p1) == "REPLY" and p2 then
		local mode = upper(p2)
		if mode == "OFF" or mode == "SKIP" then
			return "Redis client requires command replies"
		end
	end
end

local function cache_(func)
	return setmetatable({}, {__mode = "kv", __index = func})
end

local cache_head = cache_(function(self, key)
	local s = format("*%d", key)
	self[key] = s
	return s
end)

local cache_count = cache_(function(self, key)
	local s = format("\r\n$%d\r\n", key)
	self[key] = s
	return s
end)

local function compose(cmd, param)
	local count = #param
	local lines = {cache_head[count + 1], cache_count[#cmd], cmd}
	local idx = 4
	for i = 1, count do
		local v = tostring(param[i])
		lines[idx] = cache_count[#v]
		lines[idx + 1] = v
		idx = idx + 2
	end
	lines[idx] = "\r\n"
	local err = check_command(cmd, lines[5], lines[7])
	if err then
		return nil, err
	end
	return lines
end

local function composetable(cmd, out)
	local len = #cmd
	if len == 0 then
		return "Redis command must not be empty"
	end
	local start = #out + 1
	local oi = start
	out[oi] = cache_head[len]
	oi = oi + 1
	for i = 1, len do
		local v = tostring(cmd[i])
		if i == 1 then
			v = upper(v)
		end
		out[oi] = cache_count[#v]
		out[oi + 1] = v
		oi = oi + 2
	end
	out[oi] = "\r\n"
	return check_command(out[start + 2], out[start + 4], out[start + 6])
end

local function handshake(sock, cmd, p1)
	local data = compose(cmd, {p1})
	local ok, err = sock:write(data)
	if not ok then
		return false, err
	end
	local success
	ok, success, err = read_response(sock)
	if not ok then
		return false, success
	end
	return success, err
end

---@class silly.store.redis.connect.opts
---@field addr string
---@field auth string?
---@field db integer?

---@param config silly.store.redis.connect.opts
---@return silly.store.redis
function redis.new(config)
	return setmetatable({
		sock = false,
		session = false,
		connecting = false,
		addr = config.addr,
		auth = config.auth or "",
		db = config.db or 0,
		closed = false,
	}, redis_mt)
end

---@param client silly.store.redis
---@param session silly.store.redis.session
---@param err string|silly.errno
local function close_socket(client, session, err)
	if session.err then
		return
	end
	session.err = err
	if client.session == session then
		client.session = false
		client.sock = false
	end
	session.readco = false
	-- Closing wakes a transport reader. A reader already granted the turn checks session.err.
	session.sock:close()
	while true do
		local co = qpop(session.waitq)
		if not co then
			break
		end
		task.wakeup(co, err)
	end
end

function redis:close()
	self.closed = true
	local connecting = self.connecting
	if connecting then
		self.connecting = false
		connecting:close()
	end
	local session = self.session
	if session then
		close_socket(self, session, ECLOSED)
	end
end

function redis:select()
	assert(not "please specify the db when redis.new")
end

local connect_lock = mutex.new()
---@param client silly.store.redis
---@return silly.store.redis.session?, string?
local function connect_to_redis(client)
	local l<close> = connect_lock:lock(client)
	if client.closed then
		return nil, ECLOSED
	end
	if client.session then
		return client.session
	end
	local sock, err = tcp.connect(client.addr)
	if not sock then
		return nil, client.closed and ECLOSED or err
	end
	if client.closed then
		sock:close()
		return nil, ECLOSED
	end
	client.connecting = sock
	local ok = true
	if client.auth ~= "" then
		ok, err = handshake(sock, "AUTH", client.auth)
	end
	if ok and not client.closed and client.db ~= 0 then
		ok, err = handshake(sock, "SELECT", client.db)
	end
	client.connecting = false
	if client.closed then
		ok, err = false, ECLOSED
	end
	if not ok then
		sock:close()
		return nil, err
	end
	local session = {sock = sock, readco = false, waitq = qnew()}
	client.sock = sock
	client.session = session
	return session
end

local function wait_for_read(session)
	if session.err then
		return false, session.err
	end
	local co = task.running()
	if session.readco then
		qpush(session.waitq, co)
		local err = task.wait()
		if err or session.err then
			return false, err or session.err
		end
		assert(session.readco == co)
	else
		session.readco = co
	end
	return true
end

local function wakeup_next_reader(session)
	local co = qpop(session.waitq)
	session.readco = co or false
	if co then
		task.wakeup(co)
	end
end

setmetatable(redis, {__index = function(self, k)
	local cmd = upper(k)
	local f = function(client, p1, ...)
		if client.closed then
			return false, ECLOSED
		end
		local param = type(p1) == "table" and p1 or {p1, ...}
		local data, err = compose(cmd, param)
		if not data then
			return false, err
		end
		local session = client.session
		if not session then
			session, err = connect_to_redis(client)
			if not session then
				return false, err
			end
		end
		local ok
		ok, err = session.sock:write(data)
		if not ok then
			close_socket(client, session, err)
			return false, err
		end
		ok, err = wait_for_read(session)
		if not ok then
			return false, err
		end
		local success, result
		ok, success, result = read_response(session.sock)
		if not ok or session.err then
			err = session.err or success
			close_socket(client, session, err)
			return false, err
		end
		wakeup_next_reader(session)
		return success, result
	end
	self[k] = f
	return f
end})

function redis:call(cmd, p1, ...)
	return self[cmd](self, p1, ...)
end

---@param req table[]
---@return table?, string?
function redis:pipeline(req)
	if self.closed then
		return nil, ECLOSED
	end
	local out = {}
	local count = #req
	for i = 1, count do
		local err = composetable(req[i], out)
		if err then
			return nil, err
		end
	end
	if count == 0 then
		return {}, nil
	end
	local session = self.session
	local err
	if not session then
		session, err = connect_to_redis(self)
		if not session then
			return nil, err
		end
	end
	local ok
	ok, err = session.sock:write(out)
	if not ok then
		close_socket(self, session, err)
		return nil, err
	end
	ok, err = wait_for_read(session)
	if not ok then
		return nil, err
	end
	local results = {}
	for i = 1, count do
		local success, result
		ok, success, result = read_response(session.sock)
		if not ok or session.err then
			err = session.err or success
			close_socket(self, session, err)
			return nil, err
		end
		results[2 * i - 1] = success
		results[2 * i] = result
	end
	wakeup_next_reader(session)
	return results, nil
end

return redis
