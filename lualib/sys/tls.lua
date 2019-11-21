local core = require "sys.core"
local type = type
local assert = assert

local socket_pool = {}
local M = {}
local EVENT = {}

local ctx
local tls
local client_ctx

local function new_socket(fd, ctx)
	local s = {
		fd = fd,
		delim = false,
		co = false,
		ssl = false
	}
	s.ssl = tls.open(ctx, fd)
	assert(socket_pool[fd] == nil,
		"new_socket incorrect" .. fd .. "not be closed")
	socket_pool[fd] = s
	return s
end

local function suspend(s)
	assert(not s.co)
	local co = core.running()
	s.co = co
	return core.wait(co)
end

local function handshake(s)
	local ok = tls.handshake(s.ssl)
	if ok then
		return fd
	end
	s.delim = "~"
	return suspend(s)
end

function EVENT.accept(fd, _, portid, addr)
	local lc = socket_pool[portid];
	local s = new_socket(fd, lc.ctx)
	local ok = handshake(s)
	if not ok then
		return
	end
	local ok, err = core.pcall(lc.disp, fd, addr)
	if not ok then
		core.log(err)
		M.close(fd)
	end
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
	tls.message(s.ssl, message)
	if not s.delim then	--non suspend read
		assert(not s.co)
		return
	end
	if type(s.delim) == "number" then
		assert(s.co)
		local dat = tls.read(s.ssl, s.delim)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	elseif s.delim == "\n" then
		assert(s.co)
		local dat = tls.readline(s.ssl)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	elseif s.delim == "~" then
		assert(s.co)
		local ok = tls.handshake(s.ssl)
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


local function connect_normal(ip, bind)
	local fd = core.connect(ip, socket_dispatch, bind)
	if not fd then
		return nil
	end
	assert(fd >= 0)
	local s = new_socket(fd, client_ctx)
	local ok = handshake(s)
	if ok then
		return fd
	end
	M.close(fd)
	return nil
end

function M.connect(ip, bind)
	tls = require "sys.tls.tls"
	ctx = require "sys.tls.ctx"
	client_ctx = ctx.client()
	M.connect = connect_normal
	return connect_normal(ip, bind)
end

function M.listen(conf)
	assert(conf.port)
	assert(conf.disp)
	local portid = core.listen(conf.port, socket_dispatch, conf.backlog)
	if not portid then
		return
	end
	tls = require "sys.tls.tls"
	ctx = ctx or require "sys.tls.ctx"
	socket_pool[portid] = {
		fd = portid,
		disp = conf.disp,
		co = false,
		ctx = ctx.server(conf.cert, conf.key, conf.ciphers),
	}
	return portid
end

function M.close(fd)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	if s.so then
		core.wakeup(s.so, false)
	end
	tls.close(s.ssl)
	socket_pool[fd] = nil
	core.close(fd)
end

function M.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	if n <= 0 then
		return ""
	end
	local r = tls.read(s.ssl, n)
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

function M.readline(fd)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	local r = tls.readline(s.ssl)
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

function M.write(fd, str)
	local s = socket_pool[fd]
	if not s then
		return false, "already closed"
	end
	tls.write(s.ssl, str)
	return true
end

return M

