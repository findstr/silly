local silly = require "silly"
local task = require "silly.task"
local trace = require "silly.trace"
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

---@class silly.net.cluster.listener
---@field fd integer

---@alias silly.net.cluster.call fun(peer:silly.net.cluster.peer, data:string):string?
---@alias silly.net.cluster.accept fun(peer:silly.net.cluster.peer)
---@alias silly.net.cluster.close fun(peer:silly.net.cluster.peer, errno:string)

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
---@type silly.net.cluster.context
local ctx

---@class silly.net.cluster
local M = {}
local function process()
	local fd, buf, session, traceid = c.pop(ctx)
	if not fd then
		return
	end
	task.fork(process)
	while true do
		if traceid then	--rpc request
			local peer = fd_to_peer[fd]
			if not peer then
				logger.error("[cluster] peer not found", fd)
			else
				local otrace = trace_attach(traceid)
				local ok, res = pcall(call, peer, buf)
				if not ok then
					logger.error("[cluster] call error", res)
				elseif res then
					local resp, err = c.response(ctx, session, res)
					if not resp then
						logger.error("[cluster] response error:", err)
					else
						tcp_send(fd, resp)
					end
				end
				trace_attach(otrace)
			end
		else	-- rpc response
			local co = wait_pool[session]
			if co then
				wait_pool[session] = nil
				task.wakeup(co, buf)
			else
				logger.debug("[cluster] late response session:", session)
			end
		end
		--next
		fd, buf, session, traceid = c.pop(ctx)
		if not fd then
			break
		end
	end
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

---@param addr string
---@return silly.net.cluster.peer?, string? error
function M.connect(addr)
	local name, port = parse_addr(addr)
	if not name or not port then
		return nil, "Invalid address: " .. addr
	end
	local resolved = addr
	if is_host(name) then
		local ip, err = dns.lookup(name, dns.A)
		if not ip then
			return nil, format("dns lookup %s failed: %s", name, err)
		end
		resolved = join_addr(ip, port)
	end
	local fd, err = tcp_connect(resolved, EVENT)
	logger.info("[cluster] connect", addr, "fd:", fd, "err:", err)
	if not fd then
		return nil, err
	end
	local peer = {
		fd = fd,
		remoteaddr = addr,
	}
	fd_to_peer[fd] = peer
	return peer, nil
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

local waitfor = function(session)
	local co = task.running()
	local timer_id = after(expire, timer_func, session)
	wait_pool[session] = co
	local body = task.wait()
	if body then
		cancel(timer_id)
		return body, nil
	end
	return nil, ETIMEDOUT
end

local function callx(is_send)
	---@param peer silly.net.cluster.peer
	---@param data string
	---@return string|boolean|nil result, string? error
	return function(peer, data)
		local fd = peer.fd
		if not fd then
			return nil, "Peer closed"
		end
		local traceid = trace_propagate()
		local session, body = c.request(ctx, traceid, data)
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
		return waitfor(session)
	end
end

M.call = callx(false)
M.send = callx(true)

---@param conf {
---	timeout: integer?, -- default 5000 ms
---	hardlimit: integer?, -- max body size before error (default 128MB)
---	softlimit: integer?, -- max body size before warning (default 65535)
---	call: silly.net.cluster.call,
---	accept: silly.net.cluster.accept?,
---	close:  silly.net.cluster.close?,
---}
function M.serve(conf)
	expire = conf.timeout or 5000
	call = assert(conf.call)
	accept = conf.accept
	close = conf.close
	ctx = c.create(conf.hardlimit, conf.softlimit)
end

return M
