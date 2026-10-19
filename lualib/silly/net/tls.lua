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
local ipairs = ipairs
local type = type
local pairs = pairs
local setmetatable = setmetatable
local concat = table.concat
local char = string.char

global _

local wait = task.wait
local running = task.running
local readenable = tls.readenable
local free = net.free
local wakeup = task.wakeup
local monotonic = time.monotonic
local pcall = silly.pcall

local HANDSHAKE<const> = {}
local HANDSHAKE_OK<const> = 1
local HANDSHAKE_ERROR<const> = 0
local TIMEOUT<const> = {}

local EINVAL<const> = errno.INVAL
local ECLOSED<const> = errno.CLOSED
local ETIMEDOUT<const> = errno.TIMEDOUT

local client_ctx = ctx.client()

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
---@field package err silly.errno? -- saved I/O error or owner close
---@field package alpn string?
---@field package ssl any
---@field package buflimit integer?
---@field package delim string|integer|table|nil
local conn = {}

---@class silly.net.tls.listener
---@field fd integer
---@field package accept async fun(s:silly.net.tls.conn)
---@field package ctx any
---@field package conf silly.net.tls.conf
local listener = {}

---@type table<integer, silly.net.tls.conn>
local conn_pool = setmetatable({}, {__mode = "v"})
---@type table<integer, silly.net.tls.listener>
local listener_pool = {}

---@alias silly.net.tls.alpn_proto "http/1.1" | "h2"
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
---@param ctx any
---@param hostname string?
---@param alpnprotos silly.net.tls.alpn_proto[]?
---@return silly.net.tls.conn
local function new_socket(fd, remoteaddr, ctx, hostname, alpnprotos)
	local alpnstr
	if alpnprotos then
		alpnstr = wire_alpn_protos(alpnprotos)
	end
	---@type silly.net.tls.conn
	local s = setmetatable({
		fd = fd,
		remoteaddr = remoteaddr,
		co = nil,
		err = nil,
		ssl = tls.open(ctx, fd, hostname, alpnstr),
		alpn = nil,
		buflimit = nil,
		delim = nil,
	}, conn_mt)
	if conn_pool[fd] then
		error("TLS socket already registered", 2)
	end
	conn_pool[fd] = s
	return s
end

---@param s silly.net.tls.conn
---@param size integer?
local function can_pause(s, size)
	local limit = s.buflimit
	return limit and not s.co and not s.err and (size or tls.size(s.ssl)) >= limit
end

---@param s silly.net.tls.conn
---@param size integer?
local function pause_read(s, size)
	if can_pause(s, size) then
		readenable(s.ssl, false)
	end
end

---@param fd integer
---@param ctx any
---@param conf silly.net.tls.conf
---@param accept async fun(s:silly.net.tls.conn)
---@return silly.net.tls.listener
local function new_listener(fd, ctx, conf, accept)
	---@type silly.net.tls.listener
	local s = {
		fd = fd,
		ctx = ctx,
		conf = conf,
		accept = accept,
	}
	setmetatable(s, listener_mt)
	listener_pool[fd] = s
	return s
end

---@param s silly.net.tls.conn
local function read_timer(s)
	local co = s.co
	if co then
		s.co = nil
		s.delim = nil
		pause_read(s)
		wakeup(co, TIMEOUT)
	end
end

---@param s silly.net.tls.conn
---@return string?, silly.errno? error
local function block_read(s, delim, timeout)
	if s.co then
		error("TLS connection already has a reader", 2)
	end
	local err = s.err
	if not err then
		s.delim = delim
		s.co = running()
		readenable(s.ssl, true)
		local dat
		if not timeout then
			dat = wait()
		else
			local timer = time.after(timeout, read_timer, s)
			dat = wait()
			if dat == TIMEOUT then
				return nil, ETIMEDOUT
			end
			time.cancel(timer)
		end
		if dat then
			return dat, nil
		end
		err = s.err or tls.error(s.ssl)
	end
	return nil, err
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
	return block_read(s, HANDSHAKE, timeout)
end

---@type silly.net.event
local EVENT = {
accept = function(fd, listenid, addr)
	local lc = listener_pool[listenid]
	local s = new_socket(fd, addr, lc.ctx, nil, nil)
	local dat, _ = handshake(s)
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
	if s == nil then
		return
	end
	if err and not s.err then
		s.err = err
	end
	local co = s.co
	if co then
		s.co = nil
		s.delim = nil
		wakeup(co, nil)
	end
end,

data = function(fd, ptr, size)
	local s = conn_pool[fd]
	if not s then
		free(ptr)
		return
	end
	local total, err = tls.push(s.ssl, ptr, size)
	if err then
		s.err = err
	end
	local delim = s.delim
	if delim then
		local dat, readerr
		if delim ~= HANDSHAKE then
			dat, readerr = tls.read(s.ssl, delim)
		elseif not err then
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
		if dat or readerr or err then
			local co = s.co
			s.delim = nil
			s.co = nil
			if dat then
				total = total - #dat
			end
			readenable(s.ssl, true)
			wakeup(co, dat)
		end
	end
	if s.buflimit then
		pause_read(s, total)
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
	local fd, err = net.tcpconnect(addr, EVENT, bind, timeout)
	if not fd then
		return nil, err
	end
	local s = new_socket(fd, addr, client_ctx, hostname, alpnprotos)
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
local function new_server_ctx(conf)
	ctx = ctx or require "silly.tls.ctx"
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
	local certs = opts.certs
	if not addr then
		error("tls.listen missing addr", 2)
	end
	if type(accept) ~= "function" then
		error("tls.listen missing accept", 2)
	end
	if #certs == 0 then
		error("tls.listen missing certs", 2)
	end
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
	local s = new_listener(fd, tls_ctx, tls_conf, opts.accept)
	return s, nil
end

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
	if not old_conf then
		return false, EINVAL
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
	if not s.fd then
		return
	end
	readenable(s.ssl, not can_pause(s))
end

---@param s silly.net.tls.conn
---@param notify boolean?
---@return boolean, silly.errno? error
local function close(s, notify)
	local fd = s.fd
	if not fd then
		return false, ECLOSED
	end
	s.fd = nil
	conn_pool[fd] = nil
	local err = tls.close(s.ssl, notify)
	if not s.err then
		s.err = err or ECLOSED
	end
	local co = s.co
	if co then
		s.co = nil
		s.delim = nil
		wakeup(co, nil)
	end
	return net.close(fd)
end

---@param s silly.net.tls.conn
---@return boolean, silly.errno? error
function conn.close(s)
	return close(s, true)
end
-- VM finalizers may run after the socket thread has stopped.
conn_mt.__gc = close
conn_mt.__close = conn.close

---@param s silly.net.tls.conn
---@param n integer|string
---@param timeout integer? --milliseconds
---@return string?, silly.errno? error
function conn.read(s, n, timeout)
	if not s.fd then
		return nil, s.err
	end
	local r, err = tls.read(s.ssl, n)
	if r then
		if s.buflimit then
			readenable(s.ssl, not can_pause(s))
		end
		return r, nil
	elseif err then
		readenable(s.ssl, true)
		return nil, err
	end
	return block_read(s, n, timeout)
end

conn.readline = conn.read

---@param s silly.net.tls.conn
---@param data string|string[]
---@return boolean, silly.errno? error
function conn.write(s, data)
	local err = s.err
	if err then
		return false, err
	end
	local ok
	ok, err = tls.write(s.ssl, data)
	if not ok then
		s.err = err
		local co = s.co
		if co then
			s.co = nil
			s.delim = nil
			wakeup(co, nil)
		end
	end
	return ok, err
end

---@param s silly.net.tls.conn
---@return string?
function conn.alpnproto(s)
	return s.alpn
end

---@param s silly.net.tls.conn
---@return boolean
function conn.isalive(s)
	return not s.err and not tls.error(s.ssl)
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
