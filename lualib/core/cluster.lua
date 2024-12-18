local core = require "core"
local dns = require "core.dns"
local logger = require "core.logger"
local np = require "core.netpacket"
local type = type
local pairs = pairs
local assert = assert
local format = string.format
local tcp_connect = core.tcp_connect
local tcp_send = core.tcp_send
local tcp_close = core.socket_close
local tcp_listen = core.tcp_listen
local pcall = core.pcall
local timeout = core.timeout
local timercancel = core.timercancel
local setmetatable = setmetatable

local mt = {
	__gc = function(self)
		local fdaddr = self.__fdaddr
		for k, _ in pairs(fdaddr) do
			if type(k) == "number" then
				tcp_close(k)
			end
			fdaddr[k] = nil
		end
	end,
}

local function connect_wrapper(self)
	local fdaddr = self.__fdaddr
	return function(addr)
		local newaddr = addr
		local name, port = addr:match("([^:]+):(%d+)")
		if dns.isname(name) then
			local ip = dns.lookup(name, dns.A)
			if ip then
				newaddr = ip .. ":" .. port
			else
				return nil, format("dns lookup:%s fail", name)
			end
		end
		local fd, errstr = tcp_connect(newaddr, self.__event)
		if not fd then
			return fd, errstr
		end
		fdaddr[fd] = addr
		return fd, "ok"
	end
end

local function listen_wrapper(self)
	return function(addr, backlog)
		local fd, errno = tcp_listen(addr, self.__event, backlog)
		if not fd then
			return fd, errno
		end
		self.__fdaddr[fd] = addr
		return fd, nil
	end
end

local function close_wrapper(self)
	return function(fd)
		local fdaddr = self.__fdaddr
		if not fdaddr[fd] then
			return false, "closed"
		end
		fdaddr[fd] = nil
		core.socket_close(fd)
		return true, "connected"
	end
end

local function nop() end

local function init_event(self, conf)
	local waitpool = self.__waitpool
	local waitcmd = self.__waitcmd
	local fdaddr = self.__fdaddr
	local ctx = self.__ctx
	local call = assert(conf.call, "call")
	local close = assert(conf.close, "close")
	local marshal = assert(conf.marshal, "marshal")
	local unmarshal = assert(conf.unmarshal, "unmarshal")
	local accept = conf.accept or nop
	local EVENT = {}
	function EVENT.accept(fd, _, addr)
		fdaddr[fd] = addr
		local ok, err = pcall(accept, fd, addr)
		if not ok then
			logger.error("[rpc.server] EVENT.accept", err)
			np.clear(ctx, fd)
			core.socket_close(fd)
		end
	end

	function EVENT.close(fd, errno)
		fdaddr[fd] = nil
		local ok, err = pcall(close, fd, errno)
		if not ok then
			logger.error("[rpc.server] EVENT.close", err)
		end
		np.clear(ctx, fd)
	end

	function EVENT.data()
		local fd, buf, size, session, cmd, traceid = np.pop(ctx)
		if not fd then
			return
		end
		local otrace = core.trace(traceid)
		core.fork(EVENT.data)
		while true do
			if cmd then	--rpc request
				local body = unmarshal("request", cmd, buf, size)
				np.drop(buf)
				if not body then
					logger.error("[rpc.server] decode fail",
						session, cmd)
					break
				end
				local ok, res = pcall(call, body, cmd, fd)
				if not ok then
					logger.error("[rpc.server] call error", res)
					break
				end
				local id, res_data, res_size = marshal("response", cmd, res)
				if not id then
					return
				end
				tcp_send(fd, np.response(session, res_data, res_size))
			else	-- rpc response
				local req = waitcmd[session]
				if not req then --timeout
					np.drop(buf)
					logger.warn("[rpc.client] late session",
						session)
					break
				end
				local body = unmarshal("response", req, buf, size)
				np.drop(buf)
				if not body then
					logger.error("[rpc.server] decode fail",
						session)
					break
				end
				local co = waitpool[session]
				waitpool[session] = nil
				core.wakeup(co, body)
			end
			--next
			fd, buf, size, session, cmd, traceid = np.pop(ctx)
			if not fd then
				return
			end
			core.trace(traceid)
		end
		core.trace(otrace)
	end
	return function(typ, fd, message, ...)
		np.message(ctx, message)
		assert(EVENT[typ])(fd, ...)
	end
end

local function call_wrapper(self, conf)
	local expire = conf.timeout or 5000
	local waitpool = self.__waitpool
	local waitcmd = self.__waitcmd
	local fdaddr = self.__fdaddr
	local marshal = assert(conf.marshal, "marshal")
	local timer_func = function(session)
		local co = waitpool[session]
		if not co then
			logger.error("[rpc.client] timer error session:", session)
			return
		end
		waitpool[session] = nil
		waitcmd[session] = "timeout"
		core.wakeup(co, nil)
	end
	local waitfor = function(session, cmd)
		local co = core.running()
		local timer_id = timeout(expire, timer_func, session)
		waitpool[session] = co
		waitcmd[session] = cmd
		local body = core.wait()
		local err
		if body then
			timercancel(timer_id)
		else
			err = waitcmd[session]
		end
		waitcmd[session] = nil
		return body, err
	end
	local fn = function(fd, cmd, obj)
		if not fdaddr[fd] then
			return nil, "closed"
		end
		local traceid = core.tracepropagate()
		local cmdn, dat, sz = marshal("request", cmd, obj)
		local session, body, size = np.request(cmdn, traceid, dat, sz)
		local ok, err = tcp_send(fd, body, size)
		if not ok then
			return nil, err
		end
		return waitfor(session, cmd)
	end
	return fn
end

local function send_wrapper(self, conf)
	local fdaddr = self.__fdaddr
	local marshal = assert(conf.marshal, "marshal")
	local fn = function(fd, cmd, obj)
		if not fdaddr[fd] then
			return nil, "closed"
		end
		local traceid = core.tracepropagate()
		local cmdn, dat, sz = marshal("request", cmd, obj)
		local _, body, size = np.request(cmdn, traceid, dat, sz)
		return tcp_send(fd, body, size)
	end
	return fn
end

local M = {}
---@return core.cluster
function M.new(conf)
	---@class core.cluster
	local obj = {
		__ctx = np.create(),
		__fdaddr = {},
		__waitpool = {},
		__waitcmd = {},
		__waitfor = nil,
		__event = nil,
		---@type async fun(addr:string):number?,string?
		connect = nil,
		---@type fun(addr:string, backlog?:number):number?,string?
		listen = nil,
		---@type fun(addr:string|integer):boolean,string?
		close = nil,
		---@type fun(fd:number, cmd:string, obj:any):any?,string?
		call = nil,
		---@type fun(fd:number, cmd:string, obj:any):boolean,string?
		send = nil,
	}
	obj.connect = connect_wrapper(obj)
	obj.listen = listen_wrapper(obj)
	obj.close = close_wrapper(obj)
	obj.__event = init_event(obj, conf)
	obj.send = send_wrapper(obj, conf)
	obj.call = call_wrapper(obj, conf)
	return setmetatable(obj, mt)
end

return M
