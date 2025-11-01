local silly = require "silly"
local net = require "silly.net"
local logger = require "silly.logger"
local buffer = require "silly.adt.buffer"
local type = type
local assert = assert
local setmetatable = setmetatable

local bnew = buffer.new
local bappend = buffer.append
local bread = buffer.read
local bsize = buffer.size
local readenable = net.readenable
local twakeup = silly.wakeup

---@class silly.net.tcp
local M = {}

---@class silly.net.tcp.conn
---@field fd integer
---@field co thread?
---@field err string?
---@field buf userdata
---@field buflimit integer?
---@field delim string|integer|nil
---@field readpause boolean
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
		co = nil,
		err = nil,
		delim = nil,
		readpause = false,
		buf = bnew(),
		buflimit = nil,
	}, conn_mt)
	assert(not socket_pool[fd])
	socket_pool[fd] = s
	return s
end

local function check_limit(s, buflimit, size)
	local readpause = s.readpause
	if readpause then
		if size < buflimit then
			s.readpause = false
			readenable(s.fd, true)
		end
	else
		if size >= buflimit then
			s.readpause = true
			readenable(s.fd, false)
		end
	end
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
	local co = s.co
	if co then
		s.co = nil
		twakeup(co, nil)
	end
end,

data = function(fd, ptr, chunk_size)
	local s = socket_pool[fd]
	if not s then
		return
	end
	local buf = s.buf
	local size = bappend(buf, ptr, chunk_size)
	local delim = s.delim
	if delim then
		local dat
		dat, size = bread(buf, delim)
		if dat then
			s.delim = nil
			local co = s.co
			s.co = nil
			twakeup(co, dat)
		end
	end
	local limit = s.buflimit
	if limit then
		check_limit(s, limit, size)
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
---@param limit integer|nil
function conn.limit(s, limit)
	s.buflimit = limit
	if limit then
		check_limit(s, limit, bsize(s.buf))
	else
		if s.readpause then
			s.readpause = false
			readenable(s.fd, true)
		end
	end
end

---@param s silly.net.tcp.conn
---@return boolean, string? error
function conn.close(s)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	local co = s.co
	if co then
		s.co = nil
		s.err = "active closed"
		twakeup(co, nil)
	end
	return gc(s)
end
conn_mt.__close = conn.close

---@async
---@param s silly.net.tcp.conn
---@param n integer|string
---@return string?, string? error
function conn.read(s, n)
	if not s.fd then
		return nil, "socket closed"
	end
	local r, size = bread(s.buf, n)
	if r then
		local limit = s.buflimit
		if limit then
			check_limit(s, limit, size)
		end
		return r, nil
	end
	local err = s.err
	if not err then
		if s.readpause then
			s.readpause = false
			readenable(s.fd, true)
		end
		s.delim = n
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

---@deprecated
conn.readline = conn.read

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
	return bsize(s.buf)
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

