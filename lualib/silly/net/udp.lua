local task = require "silly.task"
local time = require "silly.time"
local net = require "silly.net"
local queue = require "silly.adt.queue"
local assert = assert
local setmetatable = setmetatable
local qnew = queue.new
local qpop = queue.pop
local qpush = queue.push
local wait = task.wait
local running = task.running
local wakeup = task.wakeup
local TIMEOUT<const> = {}

---@class silly.net.udp
local udp = {}

---@class silly.net.udp.packet
---@field addr string
---@field data string

---@class silly.net.udp.conn
---@field fd integer?
---@field co thread?
---@field err string?
---@field stash_bytes integer
---@field stash_packets userdata
local conn = {}
local conn_mt = {
	__index = conn,
	__gc = function(self)
		self:close()
	end,
	__close = function(self)
		self:close()
	end,
}

--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
---@type table<integer, silly.net.udp.conn>
local socket_pool = {}

---@param fd integer
---@return silly.net.udp.conn
local function new_socket(fd)
	---@type silly.net.udp.conn
	local s = setmetatable({
		fd = fd,
		co = nil,
		err = nil,
		stash_bytes = 0,
		stash_packets = qnew(),
	}, conn_mt)
	assert(not socket_pool[fd])
	socket_pool[fd] = s
	return s
end

---@param s silly.net.udp.conn
local function recvfrom_timer(s)
	local co = s.co
	if co then
		s.co = nil
		wakeup(co, TIMEOUT)
	end
end

local EVENT = {
	data = function(fd, ptr, size, addr)
		local s = socket_pool[fd]
		if not s then
			return
		end
		local data = net.tostring(ptr, size)
		local packet = {
			addr = addr,
			data = data,
		}
		local co = s.co
		if co then
			s.co = nil
			wakeup(co, packet)
		else
			qpush(s.stash_packets, packet)
			s.stash_bytes = s.stash_bytes + size
		end
	end,
	close = function(fd, errno)
		local s = socket_pool[fd]
		if not s then
			return
		end
		s.err = errno
		local co = s.co
		if s.co then
			s.co = nil
			wakeup(co, nil)
		end
	end,
}

---@param addr string
---@return silly.net.udp.conn?, string? error
function udp.bind(addr)
	assert(addr, "udp.bind missing addr")
	local fd, err = net.udpbind(addr, EVENT)
	if not fd then
		return nil, err
	end
	return new_socket(fd), nil
end

---@class silly.net.udp.connect.opts
---@field bindaddr string

---@param addr string
---@param opts silly.net.udp.connect.opts?
---@return silly.net.udp.conn?, string? error
function udp.connect(addr, opts)
	assert(addr, "udp.connect missing addr")
	local bindip = opts and opts.bindaddr
	local fd, err = net.udpconnect(addr, EVENT, bindip)
	if not fd then
		return nil, err
	end
	return new_socket(fd), nil
end

---@param s silly.net.udp.conn
---@param timeout integer? --milliseconds
---@return string?, string? error_or_addr
function conn.recvfrom(s, timeout)
	if not s.fd then
		return nil, "socket closed"
	end
	local packet = qpop(s.stash_packets)
	if packet then
		local data = packet.data
		s.stash_bytes = s.stash_bytes - #data
		return data, packet.addr
	end
	if s.err then
		return nil, s.err
	end
	assert(not s.co)
	s.co = running()
	local dat
	if not timeout then
		dat = wait()
	else
		local timer = time.after(timeout, recvfrom_timer, s)
		dat = wait()
		if dat == TIMEOUT then
			return nil, "read timeout"
		end
		time.cancel(timer)
	end
	if dat then
		return dat.data, dat.addr
	end
	return nil, s.err
end

---@param s silly.net.udp.conn
---@return boolean, string? error
function conn.close(s)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	s.err = "active closed"
	local co = s.co
	if co then
		s.co = nil
		wakeup(co, nil)
	end
	socket_pool[fd] = nil
	s.fd = nil
	net.close(fd)
	return true, nil
end

---@param s silly.net.udp.conn
---@return boolean
function conn.isalive(s)
	return s.fd and not s.err
end

---@param s silly.net.udp.conn
---@param data string
---@param addr string?
---@return boolean, string? error
function conn.sendto(s, data, addr)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	return net.udpsend(fd, data, addr)
end

function conn.unreadbytes(s)
	return s.stash_bytes
end

---@param s silly.net.udp.conn
---@return integer
function conn.unsentbytes(s)
	local fd = s.fd
	if not fd then
		return 0
	end
	return net.sendsize(fd)
end

-- for compatibility
udp.recvfrom = conn.recvfrom
udp.close = conn.close
udp.isalive = conn.isalive
udp.sendto = conn.sendto

return udp