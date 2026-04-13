local silly = require "silly"
local task = require "silly.task"
local trace = require "silly.trace"
local lock = require "silly.sync.mutex"
local time = require "silly.time"
local net = require "silly.net"
local dns = require "silly.net.dns"
local naddr = require "silly.net.addr"
local logger = require "silly.logger"
local c = require "silly.net.cluster.c"

local assert = assert
local format = string.format
local tcp_connect = net.tcpconnect
local tcp_send = net.tcpsend
local tcp_close = net.close
local tcp_listen = net.tcplisten
local parse_addr = naddr.parse
local join_addr = naddr.join
local is_host = naddr.ishost
local pcall = silly.pcall
local after = time.after
local cancel = time.cancel
local trace_propagate = trace.propagate
local trace_attach = trace.attach
local errno = require "silly.errno"
local ETIMEDOUT<const> = errno.TIMEDOUT

---@class silly.net.cluster.peer
---@field fd integer?
---@field remoteaddr string --Remote address; set for both incoming and outgoing connections.
---@field addr string? --Set for outgoing connections; used for auto-reconnect. Incoming connections lack this field.

---@class silly.net.cluster.listener
---@field fd integer

---@alias silly.net.cluster.marshal fun(typ:"request"|"response", cmd:integer|string, obj:table):integer, string
---@alias silly.net.cluster.unmarshal fun(typ:"request"|"response", cmd:integer|string, dat:string):table?, string? error
---@alias silly.net.cluster.call fun(peer:silly.net.cluster.peer, cmd:integer, obj:table):table?
---@alias silly.net.cluster.accept fun(peer:silly.net.cluster.peer)
---@alias silly.net.cluster.close fun(peer:silly.net.cluster.peer, errno:string)

---@type silly.net.cluster.marshal
local marshal
---@type silly.net.cluster.unmarshal
local unmarshal
---@type silly.net.cluster.accept
local accept
---@type silly.net.cluster.close
local close
---@type silly.net.cluster.call
local call
---@type number
local expire

local wait_pool = {}
local fd_to_peer = {}
local connect_lock = lock.new()
---@type silly.net.cluster.context
local ctx

---@class silly.net.cluster
local M = {}
local function process()
	local fd, buf, session, cmd, traceid = c.pop(ctx)
	if not fd then
		return
	end
	local otrace = trace_attach(traceid)
	task.fork(process)
	while true do
		if cmd then	--rpc request
			local req, resp, err
			req, err = unmarshal("request", cmd, buf)
			if not req then
				logger.error("[cluster] decode fail",
					session, cmd, err)
				break
			end
			local peer = fd_to_peer[fd]
			if not peer then
				logger.error("[cluster] peer not found", fd)
				break
			end
			local ok, res = pcall(call, peer, cmd, req)
			if not ok then
				logger.error("[cluster] call error", res)
				break
			end
			local id, res_data = marshal("response", cmd, res)
			if not id then
				break
			end
			resp, err = c.response(ctx, session, res_data)
			if not resp then
				logger.error("[cluster] response cmd:", cmd, "error:", err)
				break
			end
			tcp_send(fd, resp)
		else	-- rpc response
			local co = wait_pool[session]
			wait_pool[session] = nil
			task.wakeup(co, buf)
		end
		--next
		fd, buf, session, cmd, traceid = c.pop(ctx)
		if not fd then
			break
		end
		trace_attach(traceid)
	end
	trace_attach(otrace)
end

local function close_fd(fd, errno)
	c.clear(ctx, fd)
	tcp_close(fd)
	local peer = fd_to_peer[fd]
	if peer then
		fd_to_peer[fd] = nil
		peer.fd = nil
		if close then
			local ok, err = pcall(close, peer, errno)
			if not ok then
				logger.error("[cluster] close callback fd:", fd,
					"errno:", errno, "error:", err)
			end
		end
	else
		logger.error("[cluster] close fd:", fd, "not found")
	end
end

---@param peer silly.net.cluster.peer|silly.net.cluster.listener
local function close_peer(peer)
	local fd = peer.fd
	peer.addr = nil
	if fd then
		peer.fd = nil
		tcp_close(fd)
		fd_to_peer[fd] = nil
	end
	logger.info("[cluster] close peer:", peer.remoteaddr, "fd:", fd)
end


---@type silly.net.event
local EVENT = {
accept = function(fd, addr)
	local peer = {
		fd = fd,
		remoteaddr = addr,
	}
	fd_to_peer[fd] = peer
	logger.info("[cluster] accept", fd, addr)
	if accept then
		local ok, err = pcall(accept, peer)
		if not ok then
			logger.error("[cluster] accept addr:", addr, "fd:", fd, "error:", err)
			close_peer(peer)
		end
	end
end,
close = function(fd, errno)
	logger.info("[cluster] close", fd, errno)
	close_fd(fd, errno)
end,
data = function(fd, ptr, size)
	local ok, err = c.push(ctx, fd, ptr, size)
	if not ok then
		logger.error("[cluster] push fd:", fd, "error:", err)
		close_fd(fd, err)
		return
	end
	process()
end
}

---@param peer silly.net.cluster.peer
local function connect(peer)
	local addr = peer.addr
	if not addr then
		return nil, "Peer closed"
	end
	local l<close> = connect_lock:lock(peer)
	local fd = peer.fd
	if fd then
		return fd, nil
	end
	local name, port = parse_addr(addr)
	if not name or not port then
		return nil, "Invalid address:" .. addr
	end
	if is_host(name) then
		local ip, err = dns.lookup(name, dns.A)
		if not ip then
			return nil, format("dns lookup %s failed: %s", name, err)
		end
		addr = join_addr(ip, port)
	end
	local err
	fd, err = tcp_connect(addr, EVENT)
	logger.info("[cluster] connect", addr, "fd:", fd, "err:", err)
	if not fd then
		return nil, err
	end
	-- The peer may have been closed by another coroutine while we were
	-- yielded in dns.lookup or tcp_connect. In that case peer.addr has
	-- been cleared; discard the just-established fd so we don't hand
	-- the caller a live connection on a peer it considers closed.
	if not peer.addr then
		tcp_close(fd)
		return nil, "Peer closed"
	end
	peer.fd = fd
	fd_to_peer[fd] = peer
	return fd, nil
end

---@param addr string
---@return silly.net.cluster.peer
function M.connect(addr)
	---@type silly.net.cluster.peer
	local peer = {
		fd = nil,
		addr = addr,
		remoteaddr = addr,
	}
	logger.info("[cluster] connect peer", addr)
	return peer
end

M.close = close_peer

---@param addr string
---@param backlog integer?
---@return silly.net.cluster.listener?, string? error
function M.listen(addr, backlog)
	local fd, errstr = tcp_listen(addr, EVENT, backlog)
	logger.info("[cluster] listen", addr, "fd:", fd, "err:", errstr)
	if not fd then
		return nil, errstr
	end
	local peer = {
		fd = fd,
	}
	fd_to_peer[fd] = peer
	return peer, nil
end

local timer_func = function(session)
	local co = wait_pool[session]
	if not co then
		logger.error("[rpc.client] timer error session:", session)
		return
	end
	wait_pool[session] = nil
	task.wakeup(co, nil)
end

local waitfor = function(session, cmd)
	local co = task.running()
	local timer_id = after(expire, timer_func, session)
	wait_pool[session] = co
	local body = task.wait()
	if body then
		cancel(timer_id)
		local obj, err = unmarshal("response", cmd, body)
		return obj, err
	end
	return nil, ETIMEDOUT
end

local function callx(is_send)
	---@param peer silly.net.cluster.peer
	---@param cmd string
	---@param obj table
	---@return table|boolean|nil result, string? error
	return function(peer, cmd, obj)
		local fd = peer.fd
		if not fd then
			local err
			fd, err = connect(peer)
			if not fd then
				return nil, err
			end
		end
		local cmdn, dat = marshal("request", cmd, obj)
		if not cmdn then
			return nil, dat
		end
		local traceid = trace_propagate()
		local session, body = c.request(ctx, cmdn, traceid, dat)
		if not session then
			return nil, body
		end
		local ok, err = tcp_send(fd, body)
		if not ok then
			return nil, err
		end
		if is_send then
			return true, nil
		end
		return waitfor(session, cmd)
	end
end

M.call = callx(false)
M.send = callx(true)

---@param conf {
---	timeout: integer, -- default 5000 ms
---	hardlimit: integer?, -- max body size before error (default 128MB)
---	softlimit: integer?, -- max body size before warning (default 65535)
---	marshal: silly.net.cluster.marshal,
---	unmarshal: silly.net.cluster.unmarshal,
---	call: silly.net.cluster.call,
---	accept: silly.net.cluster.accept?,
---	close:  silly.net.cluster.close?,
---}
function M.serve(conf)
	expire = conf.timeout or 5000
	marshal = assert(conf.marshal)
	unmarshal = assert(conf.unmarshal)
	call = assert(conf.call)
	accept = conf.accept
	close = conf.close
	ctx = c.create(conf.hardlimit, conf.softlimit)
end

return M
