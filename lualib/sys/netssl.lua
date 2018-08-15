local core = require "sys.core"
local netssl = require "sys.netssl.c"
local type = type
local assert = assert

local socket_pool = {}

local ssl = {}

local EVENT = {}

local function new_socket(fd)
	local s = {
		fd = fd,
		delim = false,
		co = false,
		sslbuff = false
	}
	s.sslbuff = netssl.create(fd)
	assert(socket_pool[fd] == nil,
		"new_socket incorrect" .. fd .. "not be closed")
	socket_pool[fd] = s
end

function EVENT.accept(fd, _, portid, addr)
	assert(false, "ssl don't support accept")
end

function EVENT.close(fd, _, errno)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	if s.co then
		local co = s.co
		s.co = false
		core.wakeup(co, false)
	end
	socket_pool[fd] = nil
end

function EVENT.data(fd, message)
	local s = socket_pool[fd]
	if not s then
		return
	end
	s.sslbuff = netssl.message(s.sslbuff, message)
	if not s.delim then	--non suspend read
		assert(not s.co)
		return
	end
	if type(s.delim) == "number" then
		assert(s.co)
		local dat = netssl.read(s.sslbuff, s.delim)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	elseif s.delim == "\n" then
		assert(s.co)
		local dat = netssl.readline(s.sslbuff)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	elseif s.delim == "~" then
		assert(s.co)
		local ok = netssl.handshake(s.sslbuff)
		if ok then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, true)
		end
	end
end

local function socket_dispatch(type, fd, message, ...)
	assert(EVENT[type])(fd, message, ...)
end


local function suspend(s)
	assert(not s.co)
	local co = core.running()
	s.co = co
	return core.wait(co)
end

function ssl.connect(ip, bind)
	local fd = core.connect(ip, socket_dispatch, bind)
	if not fd then
		return nil
	end
	assert(fd >= 0)
	new_socket(fd)
	local s = socket_pool[fd]
	local ok = netssl.handshake(s.sslbuff)
	if ok then
		return fd
	end
	s.delim = "~"
	ok = suspend(s)
	if ok then
		return fd
	end
	ssl.close(fd)
	return nil
end

function ssl.close(fd)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	if s.so then
		core.wakeup(s.so, false)
	end
	socket_pool[fd] = nil
	core.close(fd)
end

function ssl.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	if n <= 0 then
		return ""
	end
	local r = netssl.read(s.sslbuff, n)
	if r then
		return r
	end
	s.delim = n
	local ok = suspend(s)
	if not ok then	--occurs error
		return nil
	end
	return ok
end

function ssl.readline(fd)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	local r = netssl.readline(s.sslbuff)
	if r then
		return r
	end
	s.delim = "\n"
	local ok = suspend(s)
	if not ok then	--occurs error
		return nil
	end
	return ok
end

function ssl.write(fd, str)
	local s = socket_pool[fd]
	if not s then
		return false, "already closed"
	end
	netssl.write(s.sslbuff, str)
	return true
end

return ssl

