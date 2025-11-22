local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
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
local running = task.running
local wait = task.wait
local wakeup = task.wakeup
local TIMEOUT<const> = {}

---@class silly.net.tcp
local M = {}

---@class silly.net.tcp.conn
---@field fd integer?
---@field raddr string
---@field co thread?
---@field err string?
---@field buf silly.adt.buffer
---@field buflimit integer?
---@field delim string|integer|nil
---@field readpause boolean
local conn = {}

---@class silly.net.tcp.listener
---@field fd integer
---@field accept async fun(s:silly.net.tcp.conn)
local listener = {}

--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
---@type table<integer, silly.net.tcp.conn|silly.net.tcp.listener>
local socket_pool = setmetatable({}, {__mode = "v"})

local conn_mt = {
	__index = conn,
	__gc = nil,
	__close = nil,
}

local listener_mt = {
	__index = listener,
	__gc = nil,
}

---@param fd integer
---@param addr string
---@return silly.net.tcp.conn
local function new_socket(fd, addr)
	---@type silly.net.tcp.conn
	local s = setmetatable({
		fd = fd,
		raddr = addr,
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
	local s = new_socket(fd, addr)
	local ok, err = silly.pcall(lc.accept, s)
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
		s.delim = nil
		wakeup(co, nil)
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
			local co = s.co
			s.delim = nil
			s.co = nil
			wakeup(co, dat)
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
---@field accept async fun(c:silly.net.tcp.conn)

---@param conf silly.net.tcp.listen.conf
---@return silly.net.tcp.listener?, string? error
function M.listen(conf)
	local addr = conf.addr
	local accept = conf.accept
	assert(addr, "tcp.listen missing addr")
	assert(type(accept) == "function", "tcp.listen missing accept")
	local listenid, err = net.tcplisten(addr, EVENT, conf.backlog)
	if not listenid then
		return nil, err
	end
	---@type silly.net.tcp.listener
	local s = {
		fd = listenid,
		accept = accept,
	}
	setmetatable(s, listener_mt)
	socket_pool[listenid] = s
	return s, err
end

function listener.close(s)
	local fd = s.fd
	if not fd then
		return false, "closed"
	end
	s.fd = nil
	socket_pool[fd] = nil
	return net.close(fd)
end

listener_mt.__gc = listener.close

---@class silly.net.tcp.connect.opts
---@field bind string?

---@param addr string
---@param opts silly.net.tcp.connect.opts?
---@return silly.net.tcp.conn?, string? error
function M.connect(addr, opts)
	if not addr then
		error("tcp.connect missing addr", 2)
	end
	local fd, err = net.tcpconnect(addr, EVENT, opts and opts.bind)
	if not fd then
		return nil, err
	end
	return new_socket(fd, addr), nil
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
	s.fd = nil
	socket_pool[fd] = nil
	local co = s.co
	if co then
		s.err = "active closed"
		s.co = nil
		s.delim = nil
		wakeup(co, nil)
	end
	return net.close(fd)
end
conn_mt.__gc = conn.close
conn_mt.__close = conn.close

---@param s silly.net.tcp.conn
local function read_timer(s)
	local co = s.co
	if co then
		s.co = nil
		s.delim = nil
		wakeup(co, TIMEOUT)
	end
end

---@async
---@param s silly.net.tcp.conn
---@param n integer|string
---@param timeout integer? --milliseconds
---@return string?, string? error
function conn.read(s, n, timeout)
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
		local dat
		if s.readpause then
			s.readpause = false
			readenable(s.fd, true)
		end
		s.delim = n
		assert(not s.co)
		s.co = running()
		if not timeout then
			dat = wait()
		else
			local timer = time.after(timeout, read_timer, s)
			dat = wait()
			if dat == TIMEOUT then
				return nil, "read timeout"
			end
			time.cancel(timer)
		end
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

---@param s silly.net.tcp.conn
---@return string
function conn.remoteaddr(s)
	return s.raddr
end

-- for compatibility
M.limit = conn.limit
M.close = function(s)
	return s:close()
end
M.read = conn.read
M.write = conn.write
M.isalive = conn.isalive
---@deprecated
M.readline = conn.readline
M.recvsize = conn.unreadbytes
M.sendsize = conn.unsentbytes

return M