local silly = require "silly"
local net = require "silly.net"
local tls = require "silly.tls.tls"
local ctx = require "silly.tls.ctx"
local logger = require "silly.logger"

local type = type
local pairs = pairs
local assert = assert
local concat = table.concat
local setmetatable = setmetatable

local readenable = net.readenable
local twakeup = silly.wakeup

local HANDSHAKE<const> = {}
local HANDSHAKE_OK<const> = 1
local HANDSHAKE_ERROR<const> = 0

local client_ctx = ctx.client()

---@class silly.net.tls.conf
---@field ciphers string?
---@field certs {cert:string, key:string}[]?
---@field alpnprotos silly.net.tls.alpn_proto[]?

---@class silly.net.tls
local M = {}

---@class silly.net.tls.listener
---@field fd integer
---@field callback async fun(s:silly.net.tls.conn, addr:string)
---@field ctx any
---@field conf silly.net.tls.conf

---@class silly.net.tls.conn
---@field fd integer?
---@field co thread?
---@field err string?
---@field alpnproto string?
---@field ssl any
---@field buflimit integer?
---@field delim string|integer|table|nil
---@field readpause boolean
local conn = {}
local listener = {}

---@type table<integer, silly.net.tls.conn|silly.net.tls.listener>
local socket_pool = {}

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

local function gc(s)
	local fd = s.fd
	if fd then
		socket_pool[fd] = nil
		s.fd = nil
		return net.close(fd)
	end
	return false, "socket closed"
end

local conn_mt = {
	__index = conn,
	__gc = gc,
	__close = nil,
}

local listener_mt = {
	__index = listener,
	__gc = gc,
}

---@param fd integer
---@param hostname string?
---@param alpnprotos silly.net.tls.alpn_proto[]?
---@return silly.net.tls.conn
local function new_socket(fd, ctx, hostname, alpnprotos)
	local alpnstr
	if alpnprotos then
		alpnstr = wire_alpn_protos(alpnprotos)
	end
	---@type silly.net.tls.conn
	local s = setmetatable({
		fd = fd,
		co = nil,
		err = nil,
		ssl = tls.open(ctx, fd, hostname, alpnstr),
		alpnproto = nil,
		buflimit = nil,
		delim = nil,
		readpause = false,
	}, conn_mt)
	assert(not socket_pool[fd])
	socket_pool[fd] = s
	return s
end

local function check_limit(s, buflimit, size)
	local readpause = s.readpause
	if readpause then
		if size < buflimit then
			s.readpause = false
			readenable(s.fd, true)
		end
	else
		if size >= buflimit then
			s.readpause = true
			readenable(s.fd, false)
		end
	end
end

---@param fd integer
---@param ctx any
---@param conf silly.net.tls.conf
---@param callback async fun(s:silly.net.tls.conn, addr:string)
---@return silly.net.tls.listener
local function new_listener(fd, ctx, conf, callback)
	---@type silly.net.tls.listener
	local s = setmetatable({
		fd = fd,
		ctx = ctx,
		conf = conf,
		callback = callback,
	}, listener_mt)
	assert(not socket_pool[fd])
	socket_pool[fd] = s
	return s
end

---@param s silly.net.tls.conn
---@return string?, string? error
local function block_read(s, delim)
	local err = s.err
	if not err then
		s.delim = delim
		assert(not s.co)
		s.co = silly.running()
		local dat = silly.wait()
		if dat then
			return dat, nil
		end
		err = s.err
	end
	if #err == 0 then
		return "", "end of file"
	end
	return nil, err
end

---@param s silly.net.tls.conn
---@return string?, string? error
local function handshake(s)
	local ret, alpnproto = tls.handshake(s.ssl)
	if ret == HANDSHAKE_OK then
		s.alpnproto = alpnproto
		return "", nil
	elseif ret == HANDSHAKE_ERROR then
		s.err = alpnproto
		return nil, alpnproto
	end
	return block_read(s, HANDSHAKE)
end

local EVENT = {
accept = function(fd, listenid, addr)
	local lc = socket_pool[listenid]
	local s = new_socket(fd, lc.ctx, nil, nil)
	local dat, _ = handshake(s)
	if not dat then
		s:close()
		return
	end
	local ok, err = silly.pcall(lc.callback, s, addr)
	if not ok then
		logger.error(err)
		s:close()
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
	local co = s.co
	if co then
		s.co = nil
		twakeup(co, nil)
	end
end,

data = function(fd, ptr, size)
	local s = socket_pool[fd]
	if not s then
		return
	end
	local total_size = tls.push(s.ssl, ptr, size)
	local delim = s.delim
	if delim == HANDSHAKE then
		local ret, alpnproto = tls.handshake(s.ssl)
		-- 1:success 0:error <0:continue
		if ret >= 0 then
			local res
			if ret == 1 then -- success
				res = ""
				s.alpnproto = alpnproto
			else
				s.err = alpnproto
			end
			s.delim = nil
			local co = s.co
			s.co = nil
			twakeup(co, res)
		end
	elseif delim then
		local dat
		dat, total_size = tls.read(s.ssl, delim)
		if dat then
			s.delim = nil
			local co = s.co
			s.co = nil
			twakeup(co, dat)
		end
	end
	local limit = s.buflimit
	if limit then
		check_limit(s, limit, total_size)
	end
end
}

---@class silly.net.tls.connect.opts
---@field bind string?
---@field hostname string?
---@field alpnprotos silly.net.tls.alpn_proto[]?

---@param addr string
---@param opts silly.net.tls.connect.opts?
---@return silly.net.tls.conn?, string? error
local function connect_normal(addr, opts)
	local bind, hostname, alpnprotos
	local addr = assert(addr, "tls.connect missing addr")
	if opts then
		bind = opts.bind
		hostname = opts.hostname
		alpnprotos = opts.alpnprotos
	end
	local fd, err = net.tcpconnect(addr, EVENT, bind)
	if not fd then
		return nil, err
	end
	local s = new_socket(fd, client_ctx, hostname, alpnprotos)
	local ok, err = handshake(s)
	if not ok then
		s:close()
		return nil, err
	end
	return s, nil
end

---@param addr string
---@param opts silly.net.tls.connect.opts?
---@return silly.net.tls.conn?, string? error
function M.connect(addr, opts)
	M.connect = connect_normal
	return connect_normal(addr, opts)
end

---@param conf silly.net.tls.conf
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

---@class silly.net.tls.listen.opts : silly.net.tls.conf
---@field addr string
---@field backlog integer?
---@field callback async fun(s:silly.net.tls.conn, addr:string)

---@param opts silly.net.tls.listen.opts
---@return silly.net.tls.listener?, string? error
function M.listen(opts)
	local addr = opts.addr
	local callback = opts.callback
	local certs = opts.certs
	assert(addr, "tls.listen missing addr")
	assert(callback and type(callback) == "function", "tls.listen missing callback")
	assert(#certs > 0, "tls.listen missing certs")
	local fd, err = net.tcplisten(addr, EVENT, opts.backlog)
	if not fd then
		return nil, err
	end
	tls = require "silly.tls.tls"
	local tls_ctx = new_server_ctx(opts)
	local tls_conf = {
		certs = opts.certs,
		ciphers = opts.ciphers,
		alpnprotos = opts.alpnprotos,
	}
	local s = new_listener(fd, tls_ctx, tls_conf, opts.callback)
	return s, nil
end

listener.close = gc

---@param l silly.net.tls.listener
---@param conf silly.net.tls.conf?
---@return boolean, string? error
function listener.reload(l, conf)
	if not l.fd then
		return false, "socket closed"
	end
	local old_conf = l.conf
	if not old_conf then
		return false, "not listen socket"
	end
	if conf then
		for k, v in pairs(conf) do
			old_conf[k] = v
		end
	end
	l.ctx = new_server_ctx(old_conf)
	return true, nil
end

---@param s silly.net.tls.conn
---@param limit integer|nil
function conn.limit(s, limit)
	s.buflimit = limit
	if limit then
		check_limit(s, limit, tls.size(s.ssl))
	elseif s.readpause then
		s.readpause = false
		readenable(s.fd, true)
	end
end

---@param s silly.net.tls.conn
---@return boolean, string? error
function conn.close(s)
	local fd = s.fd
	if not fd then
		return false, "socket closed"
	end
	local co = s.co
	if co then
		s.co = nil
		s.err = "active closed"
		twakeup(co, nil)
	end
	return gc(s)
end
conn_mt.__close = conn.close

---@param s silly.net.tls.conn
---@param n integer|string
---@return string?, string? error
function conn.read(s, n)
	if not s.fd then
		return nil, "socket closed"
	end
	local r, size = tls.read(s.ssl, n)
	if r then
		local limit = s.buflimit
		if limit then
			check_limit(s, limit, size)
		end
		return r, nil
	end
	local err = s.err
	if not err then
		if s.readpause then
			s.readpause = false
			readenable(s.fd, true)
		end
		s.delim = n
		assert(not s.co)
		s.co = silly.running()
		local dat = silly.wait()
		if dat then
			return dat, nil
		end
		err = s.err
	end
	if #err == 0 then
		return "", "end of file"
	end
	return nil, err
end

conn.readline = conn.read

---@param s silly.net.tls.conn
---@param data string|string[]
---@return boolean, string? error
function conn.write(s, data)
	if not s.fd then
		return false, "socket closed"
	end
	return tls.write(s.ssl, data)
end

---@param s silly.net.tls.conn
---@return string?
function conn.alpnproto(s)
	return s.alpnproto
end

---@param s silly.net.tls.conn
---@return boolean
function conn.isalive(s)
	return s.fd and (not s.err)
end

---@param s silly.net.tls.conn
---@return integer
function conn.unreadbytes(s)
	return tls.size(s.ssl)
end

---@param s silly.net.tls.conn
---@return integer
function conn.unsentbytes(s)
	local fd = s.fd
	if not fd then
		return 0
	end
	return net.sendsize(fd)
end

-- for compatibility
M.close = function(s)
	return s:close()
end
M.reload = function(l, conf)
	return l:reload(conf)
end
M.read = conn.read
M.write = conn.write
M.limit = conn.limit
M.isalive = conn.isalive
M.readline = conn.readline
M.recvsize = conn.unreadbytes
M.sendsize = conn.unsentbytes
M.alpnproto = conn.alpnproto

return M