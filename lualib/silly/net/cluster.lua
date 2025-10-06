local silly = require "silly"
local lock = require "silly.sync.mutex"
local time = require "silly.time"
local net = require "silly.net"
local dns = require "silly.net.dns"
local logger = require "silly.logger"
local c = require "silly.net.cluster.c"

local assert = assert
local format = string.format
local tcp_connect = net.tcpconnect
local tcp_send = net.tcpsend
local tcp_close = net.close
local tcp_listen = net.tcplisten
local pcall = silly.pcall
local after = time.after
local cancel = time.cancel

---@class silly.net.cluster.peer
---@field fd integer
---@field addr string? --Incoming connections lack an address and cannot be auto-reconnected.

---@class silly.net.cluster.listener
---@field fd integer

---@alias silly.net.cluster.marshal fun(typ:"request"|"response", cmd:string, obj:table):integer, string
---@alias silly.net.cluster.unmarshal fun(typ:"request"|"response", cmd:integer|string, dat:string):table?, string? error
---@alias silly.net.cluster.call fun(peer:silly.net.cluster.peer, cmd:integer, obj:table):table?
---@alias silly.net.cluster.accept fun(peer:silly.net.cluster.peer, addr:string)
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
local addr_to_peer = {}
local ctx = c.create()
local connect_lock = lock.new()

---@class silly.net.cluster
local M = {}
local function process()
	local fd, buf, session, cmd, traceid = c.pop(ctx)
	if not fd then
		return
	end
	local otrace = silly.trace(traceid)
	silly.fork(process)
	while true do
		if cmd then	--rpc request
			local body, err = unmarshal("request", cmd, buf)
			if not body then
				logger.error("[cluster] decode fail",
					session, cmd, err)
				break
			end
			local peer = fd_to_peer[fd]
			if not peer then
				logger.error("[cluster] peer not found", fd)
				break
			end
			local ok, res = pcall(call, peer, cmd, body)
			if not ok then
				logger.error("[cluster] call error", res)
				break
			end
			local id, res_data = marshal("response", cmd, res)
			if not id then
				return
			end
			tcp_send(fd, c.response(session, res_data))
		else	-- rpc response
			local co = wait_pool[session]
			wait_pool[session] = nil
			silly.wakeup(co, buf)
		end
		--next
		fd, buf, session, cmd, traceid = c.pop(ctx)
		if not fd then
			return
		end
		silly.trace(traceid)
	end
	silly.trace(otrace)
end

---@type silly.net.event
local EVENT = {
accept = function(fd, addr)
	local peer = {
		fd = fd,
	}
	fd_to_peer[fd] = peer
	logger.info("[cluster] accept", fd, addr)
	if accept then
		local ok, err = pcall(accept, peer, addr)
		if not ok then
			logger.error("[cluster] accept:", addr, "fd:", fd, "error", err)
			tcp_close(fd)
			fd_to_peer[fd] = nil
			addr_to_peer[addr] = nil
		end
	end
end,
close = function(fd, errno)
	logger.info("[cluster] close", fd, errno)
	c.clear(ctx, fd)
	tcp_close(fd)
	local peer = fd_to_peer[fd]
	if peer then
		fd_to_peer[fd] = nil
		peer.fd = nil
		local addr = peer.addr
		if addr then
			addr_to_peer[addr] = nil
		end
		if close then
			local ok, err = pcall(close, peer, errno)
			if not ok then
				logger.error("[cluster] close:", fd, "addr:", addr, "error", err)
			end
		end
	else
		logger.error("[cluster] close", fd, "not found")
	end
end,
data = function(fd, ptr, size)
	c.push(ctx, fd, ptr, size)
	process()
end
}

local function connect(addr)
	local l<close> = connect_lock:lock(addr)
	local name, port = addr:match("([^:]+):(%d+)")
	if dns.isname(name) then
		local ip = dns.lookup(name, dns.A)
		if not ip then
			return nil, format("dns lookup:%s fail", name)
		end
		addr = ip .. ":" .. port
	end
	local fd, errstr = tcp_connect(addr, EVENT)
	logger.info("[cluster] connect", addr, "fd:", fd, "err:", errstr)
	return fd, errstr
end

---@param addr string
---@return silly.net.cluster.peer?, string? error
function M.connect(addr)
	local peer = addr_to_peer[addr]
	if peer then
		return peer, nil
	end
	local fd, errstr = connect(addr)
	if not fd then
		return nil, errstr
	end
	peer = {
		fd = fd,
		addr = addr,
	}
	logger.info("[cluster] connect", addr, "fd:", fd)
	fd_to_peer[fd] = peer
	addr_to_peer[addr] = peer
	return peer, errstr
end

---@param peer silly.net.cluster.peer|silly.net.cluster.listener
function M.close(peer)
	local fd = peer.fd
	if fd then
		peer.fd = nil
		tcp_close(fd)
		fd_to_peer[fd] = nil
	end
	local addr = peer.addr
	if addr then
		addr_to_peer[addr] = nil
	end
	logger.info("[cluster] close", addr, "fd:", fd)
end


---@param addr string
---@param backlog integer?
---@return silly.net.cluster.listener?, string? error
function M.listen(addr, backlog)
	local fd, errstr = tcp_listen(addr, EVENT, backlog)
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
	silly.wakeup(co, nil)
end

local waitfor = function(session, cmd)
	local co = silly.running()
	local timer_id = after(expire, timer_func, session)
	wait_pool[session] = co
	local body = silly.wait()
	if body then
		cancel(timer_id)
		local obj, err = unmarshal("response", cmd, body)
		return obj, err
	end
	return nil, "timeout"
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
			local addr = peer.addr
			if not addr then
				return nil, "peer closed"
			end
			fd, err = connect(addr)
			if not fd then
				return nil, err
			end
			peer.fd = fd
			fd_to_peer[fd] = peer
		end
		local cmdn, dat = marshal("request", cmd, obj)
		if not cmdn then
			return nil, dat
		end
		local traceid = silly.tracepropagate()
		local session, body = c.request(cmdn, traceid, dat)
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
end

return M
