local core = require "sys.core"
local np = require "sys.netpacket"
local zproto = require "zproto"
local type = type
local pairs = pairs
local assert = assert
local pack = string.pack
local unpack = string.unpack
--[[
rpc.listen {
	addr = ip:port:backlog
	proto = the proto instance
	accept = function(fd, addr)
		@fd
			new socket fd come int
		@addr
			ip:port of new socket
		@return
			no return
	end,
	close = function(fd, errno)
		@fd
			the fd which closed by client
			or occurs errors
		@errno
			close errno, if normal is 0
		@return
			no return
	end,
	call = function(fd, cmd, data)
		@fd
			socket fd
		@cmd
			data type
		@data
			a table parsed from zproto
		@return
			cmd, result table
	end
}
]]--

local rpc = {}

local function gc(obj)
	if not obj.fd then
		return
	end
	if obj.fd < 0 then
		return
	end
	core.close(obj.fd)
	obj.fd = false
end

-----------server
local server = {}
local servermt = {__index = server, __gc = gc}

function server.listen(self)
	local EVENT = {}
	local config = self.config
	local accept = assert(config.accept, "accept")
	local close = assert(config.close, "close")
	local call = assert(config.call, "call")
	local rpcproto = config.proto
	local queue = np.create()
	function EVENT.accept(fd, portid, addr)
		local ok, err = core.pcall(accept, fd, addr)
		if not ok then
			core.log("[rpc.server] EVENT.accept", err)
			np.clear(queue, fd)
			core.close(fd)
		end
	end

	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close, fd, errno)
		if not ok then
			core.log("[rpc.server] EVENT.close", err)
		end
		np.clear(queue, fd)
	end

	function EVENT.data()
		local fd, d, sz = np.pop(queue)
		if not fd then
			return
		end
		core.fork(EVENT.data)
		while true do
			--parse
			local str = rpcproto:unpack(d, sz)
			np.drop(d, sz)
			if #str < 8 then
				core.log("[rpc.server] decode the header fail")
				return
			end
			local session, cmd = unpack("<I4I4", str)
			local body = rpcproto:decode(cmd, str, 8)
			if not body then
				core.log("[rpc.server] decode body fail", session, cmd)
				return
			end
			local ok, cmd, res = core.pcall(call, fd, cmd, body)
			if not ok or not cmd then
				core.log("[rpc.server] dispatch socket", cmd)
				return
			end
			--ack
			if type(cmd) == "string" then
				cmd = rpcproto:tag(cmd)
			end
			local hdrdat = pack("<I4I4", session, cmd)
			local bodydat = rpcproto:encode(cmd, res)
			local full = rpcproto:pack(hdrdat .. bodydat)
			core.write(fd, np.pack(full))
			--next
			fd, d, sz = np.pop(queue)
			if not fd then
				return
			end
		end

	end
	local callback = function(type, fd, message, ...)
		queue = np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
	local fd = core.listen(config.addr, callback, config.backlog)
	self.fd = fd
	return fd
end

function server.close(self)
	gc(self)
end

-------client
local client = {}
local clientmt = {__index = client, __gc = gc}

local function clienttimer(self)
	local wheel
	wheel = function()
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
				core.log("[rpc.client] timeout session", v)
				ackcmd[v] = "timeout"
				core.wakeup(co)
				waitpool[v] = nil
			end
			wk[k] = nil
		end
	end
	core.timeout(1000, wheel)
end


local function wakeupall(self)
	local q = self.connectqueue
	for k, v in pairs(q) do
		core.wakeup(v)
		q[k] = nil
	end
end

local function doconnect(self)
	local EVENT = {}
	local config = self.config
	local close = config.close
	local rpcproto = config.proto
	local queue = np.create()
	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close, fd, errno)
		if not ok then
			core.log("[rpc.client] EVENT.close", err)
		end
		self.fd = nil
		np.clear(queue, fd)
	end

	function EVENT.data()
		local fd, d, sz = np.pop(queue)
		if not fd then
			return
		end
		core.fork(EVENT.data)
		while true do
			--parse
			local str = rpcproto:unpack(d, sz)
			np.drop(d, sz)
			if #str < 8 then
				core.log("[rpc.client] decode the header fail")
			end
			local session, cmd = unpack("<I4I4", str)
			local body = rpcproto:decode(cmd, str, 8)
			if not body then
				core.log("[rpc.client] parse body fail", session, cmd)
				return
			end
			--ack
			local waitpool = self.waitpool
			local co = waitpool[session]
			if not co then --timeout
				return
			end
			waitpool[session] = nil
			self.ackcmd[session] = cmd
			core.wakeup(co, body)
			--next
			fd, d, sz = np.pop(queue)
			if not fd then
				return
			end
		end
	end

	local callback = function(type, fd, message, ...)
		queue = np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
	return core.connect(config.addr, callback)
end

--return true/false
local function checkconnect(self)
       if self.fd and self.fd >= 0 then
		return self.fd
	end
	if not self.fd then	--disconnected
		self.fd = -1
		local fd = doconnect(self)
		if not fd then
			self.fd = false
		else
			self.fd = fd
		end
		wakeupall(self)
		return self.fd
	else
		local co = core.running()
		local t = self.connectqueue
		t[#t + 1] = co
		core.wait(co)
		return self.fd and self.fd > 0
	end
end

function client.connect(self)
	return checkconnect(self)
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
	local body = core.wait(co)
	local ackcmd = self.ackcmd
	local cmd = ackcmd[session]
	ackcmd[session] = nil
	return body, cmd
end

function client.call(self, cmd, body)
	local ok = checkconnect(self)
	if not ok then
		return ok
	end
	local rpcproto = self.config.proto
	local cmd = rpcproto:tag(cmd)
	local session = core.genid()
	local hdrdat = pack("<I4I4", session, cmd)
	local bodydat = rpcproto:encode(cmd, body)
	local full = rpcproto:pack(hdrdat .. bodydat)
	core.write(self.fd, np.pack(full))
	return waitfor(self, session)
end

function client.close(self)
	gc(self)
end

-----rpc
function rpc.createclient(config)
	local totalwheel = math.floor((config.timeout + 999) / 1000)
	local obj = {
		fd = false,	--false disconnected, -1 conncting, >=0 conncted
		connectqueue = {},
		timeout = {},
		waitpool = {},
		ackcmd = {},
		nowwheel = 0,
		totalwheel = totalwheel,
		timeoutwheel = totalwheel - 1,
		config = config,
	}
	setmetatable(obj, clientmt)
	clienttimer(obj)
	return obj
end

function rpc.createserver(config)
	local obj = {
		config = config
	}
	setmetatable(obj, servermt)
	return obj
end

return rpc

