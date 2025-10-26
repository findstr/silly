local silly = require "silly"
local net = require "silly.net"
local logger = require "silly.logger"
local ns = require "silly.netstream"
local type = type
local assert = assert
local setmetatable = setmetatable

---@class silly.net.tcp
local M = {}

---@class silly.net.tcp.conn
---@field fd integer
---@field delim boolean|string|integer|nil
---@field co thread?
---@field err string?
---@field sbuffer any
local conn = {}

---@class silly.net.tcp.listener
---@field fd integer
---@field callback async fun(s:silly.net.tcp.conn, addr:string)
local listener = {}

--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
---@type table<integer, silly.net.tcp.conn|silly.net.tcp.listener>
local socket_pool = {}

local function gc(s)
	local fd = s.fd
	if fd then
		socket_pool[fd] = nil
		s.fd = nil
		return net.close(fd)
	end
	return false, "socket closed"
end

local conn_mt = {
	__index = conn,
	__gc = gc,
	__close = nil,
}

local listener_mt = {
	__index = listener,
	__gc = gc,
}

---@param fd integer
---@return silly.net.tcp.conn
local function new_socket(fd)
	---@type silly.net.tcp.conn
	local s = setmetatable({
		fd = fd,
		delim = false,
		co = nil,
		err = nil,
		sbuffer = ns.new(fd),
	}, conn_mt)
	assert(not socket_pool[fd])
	socket_pool[fd] = s
	return s
end

---@param s silly.net.tcp.conn
---@return string?, string? error
local function block_read(s, delim)
	local err = s.err
	if not err then
		s.delim = delim
		assert(not s.co)
		s.co = silly.running()
		local dat = silly.wait()
		if dat then
			return dat, nil
		end
		err = s.err
	end
	if #err == 0 then
		return "", "end of file"
	end
	return nil, err
end

---@param s silly.net.tcp.conn
---@param dat string?
local function wakeup(s, dat)
	local co = s.co
	s.co = nil
	silly.wakeup(co, dat)
end

local EVENT = {

accept = function(fd, listenid, addr)
	local lc = socket_pool[listenid];
	local s = new_socket(fd)
	local ok, err = silly.pcall(lc.callback, s, addr)
	if not ok then
		logger.error(err)
		s:close()
	end
end,

close = function(fd, errno)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	s.err = errno
	if s.co then
		wakeup(s, nil)
	end
end,

data = function(fd, ptr, chunk_size)
	local s = socket_pool[fd]
	if not s then
		return
	end
	local sbuffer = s.sbuffer
	local size = ns.push(sbuffer, ptr, chunk_size)
	local delim = s.delim
	local typ = type(delim)
	if typ == "number" then
		if size >= delim then
			local dat = ns.read(sbuffer, delim)
			s.delim = false
			wakeup(s, dat)
		end
	elseif typ == "string" then
		local dat = ns.readline(sbuffer, delim)
		if dat then
			s.delim = false
			wakeup(s, dat)
			return
		end
	end
end
}

---@class silly.net.tcp.listen.conf
---@field addr string
---@field backlog integer?
---@field callback async fun(c:silly.net.tcp.conn, addr:string)

---@param conf silly.net.tcp.listen.conf
---@return silly.net.tcp.listener?, string? error
function M.listen(conf)
	local addr = conf.addr
	local callback = conf.callback
	assert(addr, "tcp.listen missing addr")
	assert(callback and type(callback) == "function", "tcp.listen missing callback")
	local listenid, err = net.tcplisten(addr, EVENT, conf.backlog)
	if not listenid then
		return nil, err
	end
	local s = setmetatable({
		fd = listenid,
		callback = callback,
	}, listener_mt)
	socket_pool[listenid] = s
	return s, err
end

listener.close = gc

---@class silly.net.tcp.connect.opts
---@field bind string?

---@param addr string
---@param opts silly.net.tcp.connect.opts?
---@return silly.net.tcp.conn?, string? error
function M.connect(addr, opts)
	assert(addr, "tcp.connect missing addr")
	local fd, err = net.tcpconnect(addr, EVENT, opts and opts.bind)
	if not fd then
		return nil, err
	end
	return new_socket(fd), nil
end

---@param s silly.net.tcp.conn
---@param limit integer
---@return boolean
function conn.limit(s, limit)
	return ns.limit(s.sbuffer, limit)
end

---@param s silly.net.tcp.conn
---@return boolean, string? error
function conn.close(s)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	if s.co then
		s.err = "active closed"
		wakeup(s, nil)
	end
	return gc(s)
end
conn_mt.__close = conn.close



---@async
---@param s silly.net.tcp.conn
---@param n integer
---@return string?, string? error
function conn.read(s, n)
	if not s.fd then
		return nil, "socket closed"
	end
	local r = ns.read(s.sbuffer, n)
	if r then
		return r, nil
	end
	return block_read(s, n)
end

---@async
---@param s silly.net.tcp.conn
---@param delim string?
---@return string?, string? error
function conn.readline(s, delim)
	if not s.fd then
		return nil, "socket closed"
	end
	delim = delim or "\n"
	local r = ns.readline(s.sbuffer, delim)
	if r then
		return r, nil
	end
	return block_read(s, delim)
end

---@param s silly.net.tcp.conn
---@param data string|string[]
---@return boolean, string? error
function conn.write(s, data)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	return net.tcpsend(fd, data)
end

---@param s silly.net.tcp.conn
---@return boolean
function conn.isalive(s)
	return s.fd and (not s.err)
end

---@param s silly.net.tcp.conn
---@return integer
function conn.unreadbytes(s)
	return ns.size(s.sbuffer)
end

---@param s silly.net.tcp.conn
---@return integer
function conn.unsentbytes(s)
	local fd = s.fd
	if not fd then
		return 0
	end
	return net.sendsize(fd)
end

-- for compatibility
M.limit = conn.limit
M.close = function(s)
	return s:close()
end
M.read = conn.read
M.write = conn.write
M.isalive = conn.isalive
M.readline = conn.readline
M.recvsize = conn.unreadbytes
M.sendsize = conn.unsentbytes

return M

