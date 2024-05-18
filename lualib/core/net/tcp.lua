local core = require "core"
local logger = require "core.logger"
local ns = require "core.netstream"
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
	return core.wait()
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
	local portid = core.tcp_listen(port, socket_dispatch, backlog)
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
	local fd = core.tcp_connect(ip, socket_dispatch, bind)
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
	core.socket_close(fd)
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

socket.write = core.tcp_send
socket.sendsize = core.sendsize

function socket.isalive(fd)
	local s = socket_pool[fd]
	if s and not s.closing then
		return true
	end
	return false
end

return socket

