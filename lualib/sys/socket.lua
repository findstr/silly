local core = require "sys.core"
local logger = require "sys.logger"
local ns = require "sys.netstream"
local assert = assert
--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
local socket_pool = {}
local socket = {}

local EVENT = {}

local type = type
local assert = assert

local function new_socket(fd)
	local s = {
		fd = fd,
		delim = false,
		co = false,
		closing = false,
		sbuffer = ns.new(fd),
	}
	assert(not socket_pool[fd])
	socket_pool[fd] = s
end

local function del_socket(s)
	ns.free(s.sbuffer)
	socket_pool[s.fd] = nil
end

local function suspend(s)
	assert(not s.co)
	local co = core.running()
	s.co = co
	return core.wait(co)
end

local function wakeup(s, dat)
	local co = s.co
	s.co = false
	core.wakeup(co, dat)
end

function EVENT.accept(fd, _, portid, addr)
	local lc = socket_pool[portid];
	new_socket(fd)
	local ok, err = core.pcall(lc.disp, fd, addr)
	if not ok then
		logger.error(err)
		socket.close(fd)
	end
end

function EVENT.close(fd, _, errno)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	s.closing = true
	if s.co then
		wakeup(s, false)
		del_socket(s)
	end
end

function EVENT.data(fd, message)
	local s = socket_pool[fd]
	if not s then
		return
	end
	local sbuffer = s.sbuffer
	local size = ns.push(sbuffer, message)
	local delim = s.delim
	local typ = type(delim)
	if typ == "number" then
		if size >= delim then
			local dat = ns.read(sbuffer, delim)
			s.delim = false
			wakeup(s, dat)
		end
	else
		if typ == "string" then
			local dat = ns.readline(sbuffer, delim)
			if dat then
				s.delim = false
				wakeup(s, dat)
				return
			end
		end
	end
end

local function socket_dispatch(typ, fd, message, ...)
	EVENT[typ](fd, message, ...)
end

function socket.listen(port, disp, backlog)
	assert(port)
	assert(disp)
	local portid = core.listen(port, socket_dispatch, backlog)
	if portid then
		socket_pool[portid] = {
			fd = portid,
			disp = disp,
			co = false
		}
	end
	return portid
end

function socket.connect(ip, bind)
	local fd = core.connect(ip, socket_dispatch, bind)
	if fd then
		assert(fd >= 0)
		new_socket(fd)
	end
	return fd
end

function socket.limit(fd, limit)
	local s = socket_pool[fd]
	if s == nil then
		return false
	end
	return ns.limit(s.sbuffer, limit)
end

function socket.close(fd)
	local s = socket_pool[fd]
	if s == nil then
		return false
	end
	if s.co then
		wakeup(s, false)
	end
	del_socket(s)
	core.close(fd)
	return true
end

function socket.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local r = ns.read(s.sbuffer, n)
	if r then
		return r
	end
	if s.closing then
		del_socket(s)
		return false
	end
	s.delim = n
	return suspend(s)
end

function socket.readall(fd, max)
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local r = ns.readall(s.sbuffer, max)
	if r == "" and s.closing then
		del_socket(s)
		return false
	end
	return r
end

function socket.readline(fd, delim)
	delim = delim or "\n"
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local r = ns.readline(s.sbuffer, delim)
	if r then
		return r
	end
	if s.closing then
		del_socket(s)
		return false
	end
	s.delim = delim
	return suspend(s)
end

function socket.recvsize(fd)
	local s = socket_pool[fd]
	if not s then
		return 0
	end
	return ns.size(s.sbuffer)
end

socket.write = core.write
socket.sendsize = core.sendsize

---------udp
local function new_udp(fd, callback)
	local s = {
		fd = fd,
		callback = callback,
	}
	socket_pool[fd] = s
end

--udp client can be closed(because it use connect)
local function udp_dispatch(typ, fd, message, addr)
	local data
	local cb = socket_pool[fd].callback
	if typ == "udp" then
		data = ns.todata(message)
		cb(data, addr)
	elseif typ == "close" then
		cb()
		socket_pool[fd] = nil
	else
		assert(false, "type must be 'udp' or 'close'")
	end
end

function socket.bind(addr, callback)
	local fd = core.bind(addr, udp_dispatch)
	if fd  then
		new_udp(fd, callback)
	end
	return fd
end

function socket.udp(addr, callback, bindip)
	local fd = core.udp(addr, udp_dispatch, bindip)
	if fd  then
		new_udp(fd, callback)
	end
	return fd
end

socket.udpwrite = core.udpwrite

return socket

