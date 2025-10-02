local silly = require "silly"
local net = require "silly.net"
local logger = require "silly.logger"
local type = type
local pairs = pairs
local assert = assert
local concat = table.concat

local socket_pool = {}

---@class silly.net.tls.context_conf
---@field ciphers string|nil
---@field certs {cert:string, key:string}[]|nil
---@field alpnprotos silly.net.tls.alpn_proto[]|nil

---@class silly.net.tls.listen_conf : silly.net.tls.context_conf
---@field addr string
---@field backlog integer|nil
---@field disp fun(fd:integer, addr:string)

---@class silly.net.tls
---@field fd integer
---@field delim string|number|nil
---@field co thread|nil
---@field err string|nil
---@field alpnproto string?
---@field ctx any?
---@field ssl any?
---@field disp fun(fd:integer, addr:string)?
---@field conf silly.net.tls.context_conf?
local M = {}

local ctx
local tls
local client_ctx

---@alias silly.net.tls.alpn_proto "http/1.1" | "h2"
local char = string.char
local alpnwired = setmetatable({}, {__index = function(t, k)
	local v = char(#k) .. k
	t[k] = v
	return v
end})

---@param alpnprotos silly.net.tls.alpn_proto[]
local function wire_alpn_protos(alpnprotos)
	local buf = {}
	for _, v in ipairs(alpnprotos) do
		buf[#buf+1] = alpnwired[v]
	end
	return concat(buf)
end

---@param fd integer
---@param hostname string?
---@param alpnprotos silly.net.tls.alpn_proto[]?
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
		err = nil,
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
	silly.wakeup(co, dat)
end

---@return string?, string? error
local function suspend(s)
	assert(not s.co)
	s.co = silly.running()
	local dat = silly.wait()
	if not dat then
		return nil, s.err
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

local EVENT = {
accept = function(fd, listenid, addr)
	local lc = socket_pool[listenid]
	local s = new_socket(fd, lc.ctx, nil, nil)
	local dat, _ = handshake(s)
	if not dat then
		return
	end
	local ok, err = silly.pcall(lc.disp, fd, addr)
	if not ok then
		logger.error(err)
		M.close(fd)
	end
end,

---@param fd integer
---@param errno string?
close = function(fd, errno)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	s.err = errno
	if s.co then
		wakeup(s, nil)
	end
end,

data = function(fd, ptr, size)
	local s = socket_pool[fd]
	if not s then
		return
	end
	local delim = s.delim
	tls.push(s.ssl, ptr, size)
	if not delim then	--non suspend read
		return
	end
	if type(delim) == "number" then
		local dat = tls.read(s.ssl, delim)
		if dat then
			s.delim = false
			wakeup(s, dat)
		end
	elseif delim == "\n" then
		local dat = tls.readline(s.ssl)
		if dat then
			s.delim = false
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
}

---@param ip string
---@param bind string|nil
---@param hostname string|nil
---@param alpnprotos silly.net.tls.alpn_proto[]|nil
---@return integer?, string? error
local function connect_normal(ip, bind, hostname, alpnprotos)
	local fd, err = net.tcpconnect(ip, EVENT, bind)
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
---@param alpn silly.net.tls.alpn_proto[]|nil
---@return integer?, string? error
function M.connect(ip, bind, hostname, alpn)
	tls = require "silly.tls.tls"
	ctx = require "silly.tls.ctx"
	client_ctx = ctx.client()
	M.connect = connect_normal
	return connect_normal(ip, bind, hostname, alpn)
end

---@param conf silly.net.tls.context_conf
local function new_server_ctx(conf)
	ctx = ctx or require "silly.tls.ctx"
	local alpns = conf.alpnprotos
	local alpnstr
	if alpns then
		alpnstr = wire_alpn_protos(alpns)
	end
	local c, err = ctx.server(conf.certs, conf.ciphers, alpnstr)
	assert(c, err)
	return c
end

---@param conf silly.net.tls.listen_conf
---@return integer?, string? error
function M.listen(conf)
	assert(conf.addr)
	assert(conf.disp)
	assert(#conf.certs > 0)
	local portid, err = net.tcplisten(conf.addr, EVENT, conf.backlog)
	if not portid then
		return nil, err
	end
	tls = require "silly.tls.tls"
	local tls_ctx = new_server_ctx(conf)
	local s = new_socket(portid, tls_ctx, nil, nil)
	s.ctx = tls_ctx
	s.conf = {
		certs = conf.certs,
		ciphers = conf.ciphers,
		alpnprotos = conf.alpnprotos,
	}
	s.disp = conf.disp
	return portid, nil
end

---@param conf silly.net.tls.context_conf?
---@return boolean, string? error
function M.reload(fd, conf)
	local s = socket_pool[fd]
	if not s then
		return false, "socket closed"
	end
	local old_conf = s.conf
	if not old_conf then
		return false, "not listen socket"
	end
	if conf then
		for k, v in pairs(conf) do
			old_conf[k] = v
		end
	end
	s.ctx = new_server_ctx(old_conf)
	return true, nil
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
	return net.close(fd)
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
	if d then
		return d, nil
	end
	if s.err then
		return nil, s.err
	end
	s.delim = n
	return suspend(s)
end

---@param fd integer
---@return string?, string? error
function M.readall(fd)
	local s = socket_pool[fd]
	if not s then
		return nil, "socket closed"
	end
	local r = tls.readall(s.ssl)
	if r == "" and s.err then
		return nil, s.err
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
	local d = tls.readline(s.ssl)
	if d then
		return d, nil
	end
	s.delim = "\n"
	return suspend(s)
end

---@param fd integer
---@param str string
---@return boolean, string? error
function M.write(fd, str)
	local s = socket_pool[fd]
	if not s then
		return false, "socket closed"
	end
	return tls.write(s.ssl, str)
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
	return s and not s.err
end

return M
