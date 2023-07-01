local core = require "sys.core"
local logger = require "sys.logger"
local np = require "sys.netpacket"
local zproto = require "zproto"
local type = type
local pairs = pairs
local assert = assert
local pack = string.pack
local unpack = string.unpack
local tcp_send = core.tcp_send
local queue = np.create()
local NIL = {}
local rpc = {}

local function gc(obj)
	if not obj.fd then
		return
	end
	local fd = obj.fd
	obj.fd = false
	if fd < 0 then
		return
	end
	core.socket_close(fd)
end

-----------server
local server = {}
local servermt = {__index = server}

local function server_listen(self)
	local EVENT = {}
	local accept = assert(self.accept, "accept")
	local close = assert(self.close, "close")
	local call = assert(self.call, "call")
	local proto = self.proto
	function EVENT.accept(fd, portid, addr)
		local ok, err = core.pcall(accept, fd, addr)
		if not ok then
			logger.error("[rpc.server] EVENT.accept", err)
			np.clear(queue, fd)
			core.socket_close(fd)
		end
	end

	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close, fd, errno)
		if not ok then
			logger.error("[rpc.server] EVENT.close", err)
		end
		np.clear(queue, fd)
	end

	function EVENT.data()
		local fd, buf, size, cmd, session, traceid = np.rpcpop(queue)
		if not fd then
			return
		end
		local otrace = core.trace(traceid)
		core.fork(EVENT.data)
		while true do
			local dat
			--parse
			dat, size = proto:unpack(buf, size, true)
			np.drop(buf)
			local body = proto:decode(cmd, dat, size)
			if not body then
				logger.error("[rpc.server] decode fail",
					session, cmd)
				return
			end
			local ok, ret, res = core.pcall(call, body, cmd, fd)
			if not ok then
				logger.error("[rpc.server] call error", ret)
				return
			end
			if not ret then
				return
			end
			--ack
			res = res or NIL
			if type(ret) == "string" then
				ret = proto:tag(ret)
			end
			local bodydat, sz = proto:encode(ret, res, true)
			bodydat, sz = proto:pack(bodydat, sz, true)
			tcp_send(fd, np.rpcpack(bodydat, sz, ret, session, traceid))
			--next
			fd, buf, size, cmd, session, traceid = np.rpcpop(queue)
			if not fd then
				return
			end
			core.trace(traceid)
		end
		core.trace(otrace)
	end
	local callback = function(type, fd, message, ...)
		np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
	local fd, errno = core.tcp_listen(self.addr, callback, self.backlog)
	self.fd = fd
	return fd, errno
end

function server.close(self)
	gc(self)
end

-------client
local client = {}
local clientmt = {__index = client, __gc = gc}

local function wakeup_all_timeout(self)
	local timeout = self.timeout
	local waitpool = self.waitpool
	local ackcmd = self.ackcmd
	for _, wk in pairs(timeout) do
		for k, v in pairs(wk) do
			local co = waitpool[v]
			if co then
				logger.info("[rpc.client] wakeupall session", v)
				ackcmd[v] = "closed"
				core.wakeup(co)
				waitpool[v] = nil
			end
			wk[k] = nil
		end
	end
end

local function clienttimer(self)
	local wheel
	wheel = function()
		if self.closed then
			return
		end
		core.timeout(1000, wheel)
		local idx = self.nowwheel + 1
		idx = idx % self.totalwheel
		self.nowwheel = idx
		local wk = self.timeout[idx]
		if not wk then
			return
		end
		local waitpool = self.waitpool
		local ackcmd = self.ackcmd
		for k, v in pairs(wk) do
			local co = waitpool[v]
			if co then
				logger.warn("[rpc.client] timeout session", v)
				ackcmd[v] = "timeout"
				core.wakeup(co)
				waitpool[v] = nil
			end
			wk[k] = nil
		end
	end
	core.timeout(1000, wheel)
end


local function wakeup_all_connect(self)
	local q = self.connectqueue
	for k, v in pairs(q) do
		core.wakeup(v)
		q[k] = nil
	end
end

local function doconnect(self)
	local EVENT = {}
	local addr  = self.__addr
	local close = self.__close
	local proto = self.__proto
	function EVENT.close(fd, errno)
		if close then
			local ok, err = core.pcall(close, fd, errno)
			if not ok then
				logger.info("[rpc.client] EVENT.close", err)
			end
		end
		self.fd = nil
		np.clear(queue, fd)
	end

	function EVENT.data()
		local fd, d, sz, cmd, session, _ = np.rpcpop(queue)
		if not fd then
			return
		end
		core.fork(EVENT.data)
		while true do
			local str
			str, sz = proto:unpack(d, sz, true)
			np.drop(d)
			local body = proto:decode(cmd, str, sz)
			if not body then
				logger.error("[rpc.client] decode fail",
					session, cmd)
				return
			end
			--ack
			local waitpool = self.waitpool
			local co = waitpool[session]
			if not co then --timeout
				logger.warn("[rpc.client] late session",
					session, cmd)
				return
			end
			waitpool[session] = nil
			self.ackcmd[session] = cmd
			core.wakeup(co, body)
			--next
			fd, d, sz, cmd, session, _ = np.rpcpop(queue)
			if not fd then
				break
			end
		end
	end

	local callback = function(type, fd, message, ...)
		np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
	return core.tcp_connect(addr, callback)
end

--return true/false
local function checkconnect(self)
       if self.fd and self.fd >= 0 then
		return self.fd
	end
	if self.closed then
		return false
	end
	if not self.fd then	--disconnected
		self.fd = -1
		local fd = doconnect(self)
		if self.closed then
			if fd then
				core.socket_close(fd)
				fd = nil
			end
		end
		if not fd then
			logger.error("[rpc.client] connect", self.__addr, "fail")
			self.fd = false
		else
			self.fd = fd
		end
		wakeup_all_connect(self)
		return self.fd
	else
		local co = core.running()
		local t = self.connectqueue
		t[#t + 1] = co
		core.wait()
		return self.fd and self.fd > 0
	end
end

local function waitfor(self, session)
	local co = core.running()
	local expire = self.timeoutwheel + self.nowwheel
	expire = expire % self.totalwheel
	local timeout = self.timeout
	local t = timeout[expire]
	if not t then
		t = {}
		timeout[expire] = t
	end
	t[#t + 1] = session
	self.waitpool[session] = co
	local body = core.wait()
	local ackcmd = self.ackcmd
	local cmd = ackcmd[session]
	ackcmd[session] = nil
	return body, cmd
end

local function send_request(self, cmd, body) 
	local ok = checkconnect(self)
	if not ok then
		return false, "closed"
	end
	local proto = self.__proto
	if type(cmd) == "string" then
		cmd = proto:tag(cmd)
	end
	local session = core.genid()
	local traceid = core.tracepropagate()
	local body, sz = proto:encode(cmd, body, true)
	body, sz = proto:pack(body, sz, true)
	local ok = tcp_send(self.fd, np.rpcpack(body, sz, cmd, session, traceid))
	if not ok then
		return false, "send fail"
	end
	return true, session
end

client.send = send_request

function client.call(self, cmd, body)
	local ok, session = send_request(self, cmd, body)
	if not ok then
		return false, session
	end
	return waitfor(self, session)
end

function client.close(self)
	if self.closed then
		return
	end
	gc(self)
	self.closed = true
	wakeup_all_connect(self)
	wakeup_all_timeout(self)
end

-----rpc
function rpc.connect(config)
	local totalwheel = math.floor((config.timeout + 999) / 1000)
	local obj = {
		fd = false,	--false disconnected, -1 conncting, >=0 conncted
		closed = false,
		connectqueue = {},
		timeout = {},
		waitpool = {},
		ackcmd = {},
		nowwheel = 0,
		totalwheel = totalwheel,
		timeoutwheel = totalwheel - 1,
		__addr = config.addr,
		__proto = config.proto,
		__close = config.close,
	}
	setmetatable(obj, clientmt)
	clienttimer(obj)
	checkconnect(obj)
	return obj
end

function rpc.listen(config)
	local obj = {
		addr = config.addr,
		backlog = config.backlog,
		proto = config.proto,
		accept = config.accept,
		close = config.close,
		call = config.call,
	}
	setmetatable(obj, servermt)
	local ok, errno = server_listen(obj)
	if not ok then
		return nil, errno
	end
	return obj
end

return rpc

