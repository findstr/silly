local core = require "core"
local logger = require "core.logger"
local type = type
local concat = table.concat
local assert = assert

local socket_pool = {}


---@class core.net.tls
---@field fd integer
---@field delim string|number|nil
---@field co thread|nil
---@field closing boolean
---@field alpnproto string?
---@field ctx any?
---@field ssl any?
---@field disp fun(fd:integer, addr:string)?
local M = {}

local EVENT = {}

local ctx
local tls
local client_ctx

---@alias core.net.tls.alpn_proto "http/1.1" | "h2"
local char = string.char
local alpnwired = setmetatable({}, {__index = function(t, k)
	local v = char(#k) .. k
	t[k] = v
	return v
end})

---@param alpnprotos core.net.tls.alpn_proto[]
local function wire_alpn_protos(alpnprotos)
	local buf = {}
	for _, v in ipairs(alpnprotos) do
		buf[#buf+1] = alpnwired[v]
	end
	return concat(buf)
end

---@param fd integer
---@param hostname string?
---@param alpnprotos core.net.tls.alpn_proto[]?
local function new_socket(fd, ctx, hostname, alpnprotos)
	local alpnstr
	if alpnprotos then
		alpnstr = wire_alpn_protos(alpnprotos)
	end
	local s = {
		fd = fd,
		delim = false,
		---@type thread|nil
		co = nil,
		ssl = tls.open(ctx, fd, hostname, alpnstr),
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

---@param dat string?
local function wakeup(s, dat)
	local co = s.co
	s.co = nil
	core.wakeup(co, dat)
end

---@return string?, string? error
local function suspend(s)
	assert(not s.co)
	s.co = core.running()
	local dat = core.wait()
	if not dat then
		return nil, "closed"
	end
	return dat, nil
end

---@return string?, string? error
local function handshake(s)
	local ok, alpnproto = tls.handshake(s.ssl)
	if ok then
		s.alpnproto = alpnproto
		return "", nil
	end
	s.delim = "~"
	return suspend(s)
end

function EVENT.accept(fd, _, portid, addr)
	local lc = socket_pool[portid]
	local s = new_socket(fd, lc.ctx, nil, nil)
	local dat, _ = handshake(s)
	if not dat then
		return
	end
	local ok, err = core.pcall(lc.disp, fd, addr)
	if not ok then
		logger.error(err)
		M.close(fd)
	end
end

---@param fd integer
---@param errno integer?
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
			wakeup(s, "")
		end
	end
end

local function socket_dispatch(type, fd, message, ...)
	EVENT[type](fd, message, ...)
end

---@param ip string
---@param bind string|nil
---@param hostname string|nil
---@param alpnprotos core.net.tls.alpn_proto[]|nil
---@return integer?, string? error
local function connect_normal(ip, bind, hostname, alpnprotos)
	local fd, err = core.tcp_connect(ip, socket_dispatch, bind)
	if not fd then
		return nil, err
	end
	local s = new_socket(fd, client_ctx, hostname, alpnprotos)
	local ok, err = handshake(s)
	if ok then
		return fd, nil
	end
	M.close(fd)
	return nil, err
end

---@param ip string
---@param bind string|nil
---@param hostname string|nil
---@param alpn core.net.tls.alpn_proto[]|nil
---@return integer?, string? error
function M.connect(ip, bind, hostname, alpn)
	tls = require "core.tls.tls"
	ctx = require "core.tls.ctx"
	client_ctx = ctx.client()
	M.connect = connect_normal
	return connect_normal(ip, bind, hostname, alpn)
end

---@param conf {
---	addr:string,
---	disp:fun(fd:integer, addr:string),
---	ciphers:string,
---	certs:{cert:string, cert_key:string}[],
---	alpnprotos:core.net.tls.alpn_proto[]|nil, backlog:integer|nil,
---}
---@return integer?, string? error
function M.listen(conf)
	assert(conf.addr)
	assert(conf.disp)
	assert(#conf.certs > 0)
	local portid, err = core.tcp_listen(conf.addr, socket_dispatch, conf.backlog)
	if not portid then
		return nil, err
	end
	tls = require "core.tls.tls"
	ctx = ctx or require "core.tls.ctx"
	local alpns = conf.alpnprotos
	local alpnstr
	if alpns then
		alpnstr = wire_alpn_protos(alpns)
	end
	local c, err = ctx.server(conf.certs, conf.ciphers, alpnstr)
	assert(c, err)
	local s = new_socket(portid, c, nil, nil)
	s.ctx = c
	s.disp = conf.disp
	return portid, nil
end

---@param fd integer
---@return boolean, string? error
function M.close(fd)
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

---@param d string
---@return string?, string? error
local function readuntil(s, d)
	local buf = {d}
	while s.delim do
		local r = suspend(s)
		if not r then
			return nil, "socket closed"
		end
		if r ~= "" then
			buf[#buf+1] = r
		end
	end
	return concat(buf)
end

---@async
---@param fd integer
---@param n integer
---@return string?, string? error
function M.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local d = tls.read(s.ssl, n)
	if #d == n then
		return d, nil
	end
	if s.closing then
		del_socket(s)
		return nil, "socket closing"
	end
	s.delim = n - #d
	return readuntil(s, d)
end

---@param fd integer
---@return string?, string? error
function M.readall(fd)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local r = tls.readall(s.ssl)
	if r == "" and s.closing then
		del_socket(s)
		return nil, "socket closing"
	end
	return r, nil
end

---@param fd integer
---@return string?, string? error
function M.readline(fd)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local d, ok
	d, ok = tls.readline(s.ssl)
	if ok then
		return d, nil
	end
	s.delim = "\n"
	return readuntil(s, d)
end

---@param fd integer
---@param str string
---@return boolean, string? error
function M.write(fd, str)
	local s = socket_pool[fd]
	if not s then
		return false, "socket closed"
	end
	if s.closing then
		return false, "socket closing"
	end
	return tls.write(s.ssl, str), nil
end

---@param fd integer
---@return string?
function M.alpnproto(fd)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	return s.alpnproto
end

---@param fd integer
---@return boolean
function M.isalive(fd)
	local s = socket_pool[fd]
	return s and not s.closing
end

return M
