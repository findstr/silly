local core = require "silly.core"
local np = require "netpacket"
local zproto = require "zproto"
local TAG = "saux.rpc"
--[[
rpc.listen {
	addr = ip@port:backlog
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

local proto = zproto:parse [[
rpc {
	.session:integer 1
	.command:integer 2
}
]]

local rpc = {}

local function gc(obj)
	if not obj.fd then
		return
	end
	if obj.fd < 0 then
		return
	end
	core.close(obj.fd, TAG)
	obj.fd = false
end

-----------server
local server = {}
local servermt = {__index = server, __gc = gc}

function server.listen(self)
	local EVENT = {}
	function EVENT.accept(fd, portid, addr)
		local ok, err = core.pcall(self.config.accept, fd, addr)
		if not ok then
			print("[rpc.server] EVENT.accept", err)
			np.clear(self.queue, fd)
			core.close(fd, TAG)
		end
	end

	function EVENT.close(fd, errno)
		local ok, err = core.pcall(assert(self.config).close, fd, errno)
		if not ok then
			print("[rpc.server] EVENT.close", err)
		end
		np.clear(self.queue, fd)
	end

	function EVENT.data()
		local fd, d, sz = np.pop(self.queue)
		if not fd then
			return
		end
		core.fork(EVENT.data)
		local rpcproto = self.config.proto
		--parse
		local str = proto:unpack(d, sz)
		np.drop(d, sz)
		local rpc, takes = proto:decode("rpc", str)
		if not rpc then
			print("[rpc.server] parse the header fail")
			return
		end
		local body = rpcproto:decode(rpc.command, str:sub(takes + 1))
		if not body then
			print("[rpc.server] parse body fail", rpc.session, rpc.command)
			return
		end
		local ok, cmd, res = core.pcall(assert(self.config).call, fd, rpc.command, body)
		if not ok or not cmd then
			print("[rpc.server] dispatch socket", cmd)
			return
		end
		--ack
		if type(cmd) == "string" then
			cmd = rpcproto:querytag(cmd)
		end
		local hdr = {session = rpc.session, command = cmd}
		local hdrdat = proto:encode("rpc", hdr)
		local bodydat = rpcproto:encode(cmd, res)
		local full = proto:pack(hdrdat .. bodydat)
		core.write(fd, np.pack(full))
	end

	local callback = function(type, fd, message, ...)
		self.queue = np.message(self.queue, message)
		assert(EVENT[type])(fd, ...)
	end
	local fd = core.listen(self.config.addr, callback, TAG)
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
		for k, v in pairs(wk) do
			local co = self.waitpool[v]
			if co then
				print("[rpc.client] timeout session", v)
				self.ackcmd[v] = "timeout"
				core.wakeup(co)
				self.waitpool[v] = nil
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
	function EVENT.close(fd, errno)
		local ok, err = core.pcall(assert(self.config).close, fd, errno)
		if not ok then
			print("[rpc.client] EVENT.close", err)
		end
		self.fd = nil
		np.clear(self.queue, fd)
	end

	function EVENT.data()
		local fd, d, sz = np.pop(self.queue)
		if not fd then
			return
		end
		core.fork(EVENT.data)
		--parse
		local str = proto:unpack(d, sz)
		np.drop(d, sz)
		local rpc, takes = proto:decode("rpc", str)
		if not rpc then
			print("[rpc.client] parse the header fail")
			return
		end
		local body = self.config.proto:decode(rpc.command, str:sub(takes + 1))
		if not body then
			print("[rpc.client] parse body fail", rpc.session, rpc.command)
			return
		end
		--ack
		local co = self.waitpool[rpc.session]
		if not co then --timeout
			return
		end
		self.waitpool[rpc.session] = nil
		self.ackcmd[rpc.session] = rpc.command
		core.wakeup(co, body)
	end

	local callback = function(type, fd, message, ...)
		self.queue = np.message(self.queue, message)
		assert(EVENT[type])(fd, ...)
	end
	return core.connect(self.config.addr, callback, nil, TAG)
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
		core.wait()
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
	if not self.timeout[expire] then
		self.timeout[expire] = {}
	end
	local t = self.timeout[expire]
	t[#t + 1] = session
	self.waitpool[session] = co
	local body = core.wait()
	local cmd = self.ackcmd[session]
	self.ackcmd[session] = nil
	return body, cmd
end

function client.call(self, cmd, body)
	local ok = checkconnect(self)
	if not ok then
		return ok
	end
	local cmd = self.config.proto:querytag(cmd)
	local hdr = {session = core.genid(), command = cmd}
	local hdrdat = proto:encode("rpc", hdr)
	local bodydat = self.config.proto:encode(cmd, body)
	local full = proto:pack(hdrdat .. bodydat)
	core.write(self.fd, np.pack(full))
	return waitfor(self, hdr.session)
end

function client.close(self)
	gc(self)
end

-----rpc
function rpc.createclient(config)
	local obj = {}
	obj.fd = false	--false disconnected, -1 conncting, >=0 conncted
	obj.connectqueue = {}
	obj.queue = np.create()
	obj.timeout = {}
	obj.waitpool = {}
	obj.ackcmd = {}
	obj.nowwheel = 0
	obj.totalwheel = math.floor((config.timeout + 999) / 1000)
	obj.timeoutwheel = obj.totalwheel - 1
	obj.config = config
	setmetatable(obj, clientmt)
	clienttimer(obj)
	return obj
end

function rpc.createserver(config)
	local obj = {}
	obj.queue = np.create()
	obj.config = config
	setmetatable(obj, servermt)
	return obj
end

return rpc

