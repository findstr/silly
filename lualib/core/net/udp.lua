local core = require "core"
local net = require "core.net"
local ns = require "core.netstream"
local assert = assert
local tremove = table.remove

--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
---@type table<integer, core.net.udp>
local socket_pool = {}

---@class core.net.udp.packet
---@field addr string
---@field data string

---@class core.net.udp
---@field fd integer
---@field co thread|nil
---@field err string|nil
---@field packets core.net.udp.packet[]
local udp = {}

---@param fd integer
local function new_socket(fd)
	local s = {
		fd = fd,
		---@type thread|nil
		co = nil,
		err = nil,
		packets = {},
	}
	assert(not socket_pool[fd])
	socket_pool[fd] = s
end

---@param s core.net.udp
local function del_socket(s)
	socket_pool[s.fd] = nil
end

---@param s core.net.udp
---@return string?, string? error_or_addr
local function suspend(s)
	assert(not s.co)
	local co = core.running()
	s.co = co
	local dat = core.wait()
	if not dat then
		return nil, s.err
	end
	return dat.data, dat.addr
end

---@param packet core.net.udp.packet?
local function wakeup(s, packet)
	local co = s.co
	s.co = nil
	core.wakeup(co, packet)
end

local EVENT = {
	data = function(fd, ptr, size, addr)
		local s = socket_pool[fd]
		if not s then
			return
		end
		local data = ns.todata(ptr, size)
		local packet = {
			addr = addr,
			data = data,
		}
		if s.co then
			wakeup(s, packet)
		else
			local packets = s.packets
			packets[#packets + 1] = packet
		end
	end,
	close = function(fd, errno)
		local s = socket_pool[fd]
		if not s then
			return
		end
		s.err = errno
		if s.co then
			wakeup(s, nil)
		end
	end,
}

---@param addr string
---@return integer|nil, string? error
function udp.bind(addr)
	local fd, err = net.udp_bind(addr, EVENT)
	if fd then
		new_socket(fd)
	end
	return fd, err
end

---@param addr string
---@param bindip string|nil
---@return integer|nil, string? error
function udp.connect(addr, bindip)
	local fd, err = net.udp_connect(addr, EVENT, bindip)
	if fd then
		new_socket(fd)
	end
	return fd, err
end

---@async
---@param fd integer
---@return string?, string? error_or_addr
function udp.recvfrom(fd)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local packets = s.packets
	if #packets > 0 then
		local packet = packets[1]
		tremove(packets, 1)
		return packet.data, packet.addr
	end
	if s.err then
		return nil, s.err
	end
	return suspend(s)
end

---@param fd integer
---@return boolean, string? error
function udp.close(fd)
	local s = socket_pool[fd]
	if not s then
		return false, "socket closed"
	end
	if s.co then
		s.err = "active closed"
		wakeup(s, nil)
	end
	del_socket(s)
	net.socket_close(fd)
	return true, nil
end

---@param fd integer
---@return boolean
function udp.isalive(fd)
	local s = socket_pool[fd]
	return s and not s.err
end

udp.sendto = net.udp_send
udp.sendsize = net.sendsize

return udp

