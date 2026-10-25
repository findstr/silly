local require = require
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local net = require "silly.net"
local tls = require "silly.tls.tls"
local ctx = require "silly.tls.ctx"
local logger = require "silly.logger"
local errno = require "silly.errno"

local error = error
local assert = assert
local ipairs = ipairs
local type = type
local pairs = pairs
local setmetatable = setmetatable
local concat = table.concat
local char = string.char

global _

local free = net.free

local wait = task.wait
local running = task.running
local wakeup = task.wakeup

local monotonic = time.monotonic
local pcall = silly.pcall

local HANDSHAKE<const> = {}
local HANDSHAKE_OK<const> = 1
local HANDSHAKE_ERROR<const> = 0
local TIMEOUT<const> = {}

local ECLOSED<const> = errno.CLOSED
local EEOF<const> = errno.EOF
local ETLS<const> = errno.TLS
local ETIMEDOUT<const> = errno.TIMEDOUT

local client_ctx = assert(ctx.client())

---@class silly.net.tls.conf
---@field ciphers string?
---@field certs {cert:string, key:string}[]?
---@field alpnprotos silly.net.tls.alpn_proto[]?

---@class silly.net.tls
local M = {}

---@class silly.net.tls.conn
---@field fd integer?
---@field remoteaddr string
---@field package co thread?
---@field package err silly.errno? -- first read-side error or owner close
---@field package alpn string?
---@field package ssl silly.tls.tls
---@field package delim string|integer|table|nil
local conn = {}

---@class silly.net.tls.listener
---@field fd integer?
---@field package accept async fun(s:silly.net.tls.conn)
---@field package ctx silly.tls.CTX
---@field package conf silly.net.tls.conf
local listener = {}

---@type table<integer, silly.net.tls.conn>
local conn_pool = setmetatable({}, {__mode = "v"})
---@type table<integer, silly.net.tls.listener>
local listener_pool = {}

---@alias silly.net.tls.alpn_proto string
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

local conn_mt = {
	__index = conn,
	__gc = nil,
	__close = nil,
}

local listener_mt = {
	__index = listener,
}

---@param fd integer
---@param remoteaddr string
---@param ctx silly.tls.CTX
---@param hostname string?
---@param alpnstr string?
---@return silly.net.tls.conn?, silly.errno? error
local function new_socket(fd, remoteaddr, ctx, hostname, alpnstr)
	if conn_pool[fd] then
		error("TLS socket already registered", 2)
	end
	local ssl, err = tls.open(ctx, fd, hostname, alpnstr)
	if not ssl then
		net.close(fd)
		return nil, err
	end
	---@type silly.net.tls.conn
	local s = setmetatable({
		fd = fd,
		remoteaddr = remoteaddr,
		co = nil,
		err = nil,
		ssl = ssl,
		alpn = nil,
		delim = nil,
	}, conn_mt)
	conn_pool[fd] = s
	return s
end

---@param s silly.net.tls.conn
---@param data string|table|nil
local function read_wakeup(s, data)
	local co = s.co
	if not co then
		return
	end
	s.co = nil
	s.delim = nil
	wakeup(co, data)
end

---@param s silly.net.tls.conn
local function read_timer(s)
	tls.readcancel(s.ssl)
	read_wakeup(s, TIMEOUT)
end

---@param s silly.net.tls.conn
local function handshake_timer(s)
	read_wakeup(s, TIMEOUT)
end

---@param s silly.net.tls.conn
---@param delim integer|string|table
---@param timeout integer?
---@param timerf fun(s:silly.net.tls.conn)
---@return string?, silly.errno? error
local function block_read(s, delim, timeout, timerf)
	s.delim = delim
	s.co = running()
	local dat
	if not timeout then
		dat = wait()
	else
		local timer = time.after(timeout, timerf, s)
		dat = wait()
		if dat == TIMEOUT then
			return nil, ETIMEDOUT
		end
		time.cancel(timer)
	end
	if dat then
		return dat, nil
	end
	return nil, s.err
end

---@param s silly.net.tls.conn
---@param timeout integer? --milliseconds
---@return string?, silly.errno? error
local function handshake(s, timeout)
	local ret, alpnproto = tls.handshake(s.ssl)
	if ret == HANDSHAKE_OK then
		s.alpn = alpnproto
		return "", nil
	elseif ret == HANDSHAKE_ERROR then
		s.err = alpnproto
		return nil, alpnproto
	end
	return block_read(s, HANDSHAKE, timeout, handshake_timer)
end

---@type silly.net.event
local EVENT = {
accept = function(fd, listenid, addr)
	local lc = listener_pool[listenid]
	if not lc then
		net.close(fd)
		return
	end
	local s = new_socket(fd, addr, lc.ctx, nil, nil)
	if not s then
		return
	end
	local dat = handshake(s)
	if not dat then
		s:close()
		return
	end
	local ok, err = pcall(lc.accept, s)
	if not ok then
		logger.error(err)
		s:close()
	end
end,

---@param fd integer
---@param err silly.errno
close = function(fd, err)
	local s = conn_pool[fd]
	if not s then
		return
	end
	if not s.err then
		s.err = err
	end
	read_wakeup(s, nil)
end,

data = function(fd, ptr, size)
	local s = conn_pool[fd]
	if not s or s.err then
		free(ptr)
		return
	end
	local err = tls.push(s.ssl, ptr, size)
	if err then
		s.err = err
	end
	local dat
	local delim = s.delim
	if not delim then
		return
	end
	if delim ~= HANDSHAKE then
		dat = tls.read(s.ssl, delim)
	elseif not err or err == EEOF then
		-- Finished and close_notify may arrive in the same input.
		local ret, alpnproto = tls.handshake(s.ssl)
		if ret == HANDSHAKE_ERROR then
			err = alpnproto
			s.err = err
		elseif ret == HANDSHAKE_OK then
			dat = ""
			s.alpn = alpnproto
		end
	end
	if dat or err then
		read_wakeup(s, dat)
	end
end
}

---@class silly.net.tls.connect.opts
---@field bind string?
---@field hostname string?
---@field timeout integer? --milliseconds
---@field alpnprotos silly.net.tls.alpn_proto[]?

---@param addr string
---@param opts silly.net.tls.connect.opts?
---@return silly.net.tls.conn?, silly.errno? error
function M.connect(addr, opts)
	local bind, hostname, alpnprotos, timeout
	if not addr then
		error("tls.connect missing addr", 2)
	end
	local deadline
	if opts then
		bind = opts.bind
		hostname = opts.hostname
		alpnprotos = opts.alpnprotos
		timeout = opts.timeout
		if timeout then
			deadline = monotonic() + timeout
		end
	end
	local alpnstr
	if alpnprotos then
		alpnstr = wire_alpn_protos(alpnprotos)
	end
	local fd, err = net.tcpconnect(addr, EVENT, bind, timeout)
	if not fd then
		return nil, err
	end
	local s, err = new_socket(fd, addr, client_ctx, hostname, alpnstr)
	if not s then
		return nil, err
	end
	if deadline then
		timeout = deadline - monotonic()
		if timeout <= 0 then
			s:close()
			return nil, ETIMEDOUT
		end
	end
	local ok, err = handshake(s, timeout)
	if not ok then
		s:close()
		return nil, err
	end
	return s, nil
end

---@param conf silly.net.tls.conf
---@return silly.tls.CTX
local function new_server_ctx(conf)
	local alpns = conf.alpnprotos
	local alpnstr
	if alpns then
		alpnstr = wire_alpn_protos(alpns)
	end
	local c, err = ctx.server(conf.certs, conf.ciphers, alpnstr)
	if not c then
		error(err, 2)
	end
	return c
end

---@class silly.net.tls.listen.opts : silly.net.tls.conf
---@field addr string
---@field backlog integer?
---@field accept async fun(s:silly.net.tls.conn)

---@param opts silly.net.tls.listen.opts
---@return silly.net.tls.listener?, silly.errno? error
function M.listen(opts)
	local addr = opts.addr
	local accept = opts.accept
	if not addr then
		error("tls.listen missing addr", 2)
	end
	if type(accept) ~= "function" then
		error("tls.listen missing accept", 2)
	end
	local tls_ctx = new_server_ctx(opts)
	local fd, err = net.tcplisten(addr, EVENT, opts.backlog)
	if not fd then
		return nil, err
	end
	---@type silly.net.tls.listener
	local s = setmetatable({
		fd = fd,
		ctx = tls_ctx,
		conf = {
			certs = opts.certs,
			ciphers = opts.ciphers,
			alpnprotos = opts.alpnprotos,
		},
		accept = accept,
	}, listener_mt)
	listener_pool[fd] = s
	return s, nil
end

---@param s silly.net.tls.listener
---@return boolean, silly.errno? error
function listener.close(s)
	local fd = s.fd
	if not fd then
		return false, ECLOSED
	end
	s.fd = nil
	listener_pool[fd] = nil
	return net.close(fd)
end

---@param l silly.net.tls.listener
---@param conf silly.net.tls.conf?
---@return boolean, silly.errno? error
function listener.reload(l, conf)
	if not l.fd then
		return false, ECLOSED
	end
	local old_conf = l.conf
	local new_conf = {}
	for k, v in pairs(old_conf) do
		new_conf[k] = v
	end
	if conf then
		for k, v in pairs(conf) do
			new_conf[k] = v
		end
	end
	local context = new_server_ctx(new_conf)
	l.conf = new_conf
	l.ctx = context
	return true, nil
end

---@param s silly.net.tls.conn
---@param limit integer? byte count from 0 to 2^31-1; nil removes the receive limit
function conn.limit(s, limit)
	if s.fd then
		tls.limit(s.ssl, limit)
	end
end

---@param s silly.net.tls.conn
---@return boolean, silly.errno? error
function conn.close(s)
	local fd = s.fd
	if not fd then
		return false, ECLOSED
	end
	s.fd = nil
	conn_pool[fd] = nil
	local err = tls.close(s.ssl)
	if not s.err then
		s.err = err or ECLOSED
	end
	read_wakeup(s, nil)
	return net.close(fd)
end

conn_mt.__gc = conn.close
conn_mt.__close = conn.close

---@param s silly.net.tls.conn
---@param n integer|string byte count from 0 to 2^31-1, or a single-byte delimiter; 0 returns an empty string
---@param timeout integer? --milliseconds
---@return string?, silly.errno? error
function conn.read(s, n, timeout)
	if not s.fd then
		return nil, s.err
	end
	if s.co then
		error("TLS connection already has a reader", 2)
	end
	local r = tls.read(s.ssl, n)
	if r then
		return r, nil
	end
	local err = s.err
	if err then
		return nil, err
	end
	err = tls.readwait(s.ssl)
	if err then
		s.err = err
		return nil, err
	end
	return block_read(s, n, timeout, read_timer)
end

conn.readline = conn.read

---Success means the data was accepted for sending and may still be buffered; it does not confirm peer delivery.
---A failed write may have already queued a prefix of the data.
---Fatal TLS errors are saved for readers even when no read is pending.
---@param s silly.net.tls.conn
---@param data string|string[]
---@return boolean, silly.errno? error
function conn.write(s, data)
	if not s.fd then
		return false, s.err
	end
	local ok, err = tls.write(s.ssl, data)
	if err == ETLS then
		if not s.err then
			s.err = err
		end
		read_wakeup(s, nil)
	end
	return ok, err
end

---Return the negotiated ALPN protocol; an empty string means none was negotiated.
---@param s silly.net.tls.conn
---@return string protocol
function conn.alpnproto(s)
	return s.alpn
end

---@param s silly.net.tls.conn
---@return boolean
function conn.isalive(s)
	return not s.err
end

---@param s silly.net.tls.conn
---@return integer
function conn.unreadbytes(s)
	return tls.size(s.ssl)
end

---@param s silly.net.tls.conn
---@return integer
function conn.unsentbytes(s)
	return tls.sendsize(s.ssl)
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
