local core = require "core"
local logger = require "core.logger"
local ns = require "core.netstream"
local assert = assert

--when luaVM destroyed, all process will be exit
--so no need to clear socket connection
local socket_pool = {}
---@class core.net.tcp
---@field fd integer
---@field delim boolean
---@field co thread|nil
---@field closing boolean
local socket = {}

local EVENT = {}

local type = type
local assert = assert

---@param fd integer
local function new_socket(fd)
	local s = {
		fd = fd,
		delim = false,
		---@type thread|nil
		co = nil,
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

---@param s core.net.tcp
---@return string?, string? error
local function suspend(s)
	assert(not s.co)
	local co = core.running()
	s.co = co
	local dat = core.wait()
	if not dat then
		return nil, "closed"
	end
	return dat, nil
end

---@param dat string?
local function wakeup(s, dat)
	local co = s.co
	s.co = nil
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
		wakeup(s, nil)
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

---@param addr string
---@param disp async fun(fd:integer, addr:string)
---@param backlog integer|nil
---@return integer|nil, string|nil
function socket.listen(addr, disp, backlog)
	assert(addr)
	assert(disp)
	local portid, err = core.tcp_listen(addr, socket_dispatch, backlog)
	if portid then
		socket_pool[portid] = {
			fd = portid,
			disp = disp,
			co = false
		}
	end
	return portid, err
end

---@async
---@param ip string
---@param bind string|nil
---@return integer|nil, string? error
function socket.connect(ip, bind)
	local fd, err = core.tcp_connect(ip, socket_dispatch, bind)
	if fd then
		assert(fd >= 0)
		new_socket(fd)
	end
	return fd, err
end

---@param fd integer
---@param limit integer
---@return integer|boolean
function socket.limit(fd, limit)
	local s = socket_pool[fd]
	if s == nil then
		return false
	end
	return ns.limit(s.sbuffer, limit)
end

---@param fd integer
---@return boolean, string? error
function socket.close(fd)
	local s = socket_pool[fd]
	if s == nil then
		return false, "socket closed"
	end
	if s.co then
		wakeup(s, nil)
	end
	del_socket(s)
	core.socket_close(fd)
	return true, nil
end

---@async
---@param fd integer
---@param n integer
---@return string?, string? error
function socket.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local r = ns.read(s.sbuffer, n)
	if r then
		return r, nil
	end
	if s.closing then
		del_socket(s)
		return nil, "socket closing"
	end
	s.delim = n
	return suspend(s)
end

---@param fd integer
---@param max integer|nil
---@return string?, string? error
function socket.readall(fd, max)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local r = ns.readall(s.sbuffer, max)
	if r == "" and s.closing then
		del_socket(s)
		return nil, "socket closing"
	end
	return r, nil
end

---@async
---@param fd integer
---@param delim string|nil
---@return string?, string? error
function socket.readline(fd, delim)
	delim = delim or "\n"
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local r = ns.readline(s.sbuffer, delim)
	if r then
		return r, nil
	end
	if s.closing then
		del_socket(s)
		return nil, "socket closing"
	end
	s.delim = delim
	return suspend(s)
end

---@param fd integer
---@return integer
function socket.recvsize(fd)
	local s = socket_pool[fd]
	if not s then
		return 0
	end
	return ns.size(s.sbuffer)
end

socket.write = core.tcp_send
socket.sendsize = core.sendsize

---@param fd integer
---@return boolean
function socket.isalive(fd)
	local s = socket_pool[fd]
	return s and not s.closing
end

return socket

