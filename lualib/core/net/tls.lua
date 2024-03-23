local core = require "core"
local time = require "core.time"
local logger = require "core.logger"
local type = type
local concat = table.concat
local assert = assert

local socket_pool = {}
local M = {}
local EVENT = {}

local ctx
local tls
local client_ctx

--"http/1.1"
--"h2"
local char = string.char
local alpnwired = setmetatable({}, {__index = function(t, k)
	local v = char(#k) .. k
	t[k] = v
	return v
end})

local function wire_alpn_protos(alpnprotos)
	local buf = {}
	for _, v in ipairs(alpnprotos) do
		buf[#buf+1] = alpnwired[v]
	end
	return concat(buf)
end

local function new_socket(fd, ctx, hostname, alpnprotos)
	if alpnprotos then
		alpnprotos = wire_alpn_protos(alpnprotos)
	end
	local s = {
		nil,
		fd = fd,
		delim = false,
		co = false,
		ssl = tls.open(ctx, fd, hostname, alpnprotos),
		closing = false,
		alpnproto = nil,
	}
	socket_pool[fd] = s
	return s
end

local function del_socket(s)
	tls.close(s.ssl)
	socket_pool[s.fd] = nil
end

local function wakeup(s, dat)
	local co = s.co
	s.co = false
	core.wakeup(co, dat)
end

local function suspend(s)
	assert(not s.co)
	s.co = core.running()
	return core.wait()
end

local function handshake(s)
	local ok, alpnproto = tls.handshake(s.ssl)
	if ok then
		s.alpnproto = alpnproto
		return ok
	end
	s.delim = "~"
	return suspend(s)
end

function EVENT.accept(fd, _, portid, addr)
	local lc = socket_pool[portid]
	local s = new_socket(fd, lc.ctx, nil, nil)
	local ok = handshake(s)
	if not ok then
		return
	end
	local ok, err = core.pcall(lc.disp, fd, addr)
	if not ok then
		logger.error(err)
		M.close(fd)
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
	local delim = s.delim
		tls.message(s.ssl, message)
	if not delim then	--non suspend read
		return
	end
	if type(delim) == "number" then
		local dat = tls.read(s.ssl, delim)
		if dat then
			local n = delim - #dat
			if n == 0 then
				s.delim = false
			else
				s.delim = n
			end
			wakeup(s, dat)
		end
	elseif delim == "\n" then
		local dat, ok = tls.readline(s.ssl)
		if dat ~= "" then
			if ok then
				s.delim = false
			end
			wakeup(s, dat)
		end
	elseif delim == "~" then
		local ok, alpnproto = tls.handshake(s.ssl)
		if ok then
			s.alpnproto = alpnproto
			s.delim = false
			wakeup(s, true)
		end
	end
end

local function socket_dispatch(type, fd, message, ...)
	EVENT[type](fd, message, ...)
end


local function connect_normal(ip, bind, hostname, alpnprotos)
	local fd = core.tcp_connect(ip, socket_dispatch, bind)
	if not fd then
		return nil
	end
	local s = new_socket(fd, client_ctx, hostname, alpnprotos)
	local ok = handshake(s)
	if ok then
		return fd
	end
	M.close(fd)
	return nil
end

function M.connect(ip, bind, hostname, alpn)
	tls = require "core.tls.tls"
	ctx = require "core.tls.ctx"
	client_ctx = ctx.client()
	M.connect = connect_normal
	return connect_normal(ip, bind, hostname, alpn)
end

function M.listen(conf)
	assert(conf.port)
	assert(conf.disp)
	assert(#conf.certs > 0)
	local portid = core.tcp_listen(conf.port, socket_dispatch, conf.backlog)
	if not portid then
		return nil
	end
	tls = require "core.tls.tls"
	ctx = ctx or require "core.tls.ctx"
	local alpns = conf.alpnprotos
	if alpns then
		alpns = wire_alpn_protos(alpns)
	end
	local c, err = ctx.server(conf.certs, conf.ciphers, alpns)
	assert(c, err)
	local s = new_socket(portid, c, nil, nil)
	s.ctx = c
	s.disp = conf.disp
	return portid
end

function M.close(fd)
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

local function readuntil(s, d)
	local buf = {d}
	while s.delim do
		local r = suspend(s)
		if not r then
			return false
		end
		if r ~= "" then
			buf[#buf+1] = r
		end
	end
	return concat(buf)
end

function M.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local d = tls.read(s.ssl, n)
	if #d == n then
		return d
	end
	if s.closing then
		del_socket(s)
		return false
	end
	s.delim = n - #d
	return readuntil(s, d)
end

function M.readall(fd)
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local r = tls.readall(s.ssl)
	if r == "" and s.closing then
		del_socket(s)
		return false
	end
	return r
end


function M.readline(fd)
	local s = socket_pool[fd]
	if not s then
		return false
	end
	local d, ok
	d, ok = tls.readline(s.ssl)
	if ok then
		return d
	end
	s.delim = "\n"
	return readuntil(s, d)
end

function M.write(fd, str)
	local s = socket_pool[fd]
	if not s or s.closing then
		return false, "already closed"
	end
	return tls.write(s.ssl, str)
end

function M.alpnproto(fd)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	return s.alpnproto
end

return M
