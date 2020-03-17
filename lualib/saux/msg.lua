local core = require "sys.core"
local np = require "sys.netpacket"
local pairs = pairs
local assert = assert
local type = type
local msg = {}
local msgserver = {}
local msgclient = {}

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

local servermt = {__index = msgserver, __gc = gc}
local clientmt = {__index = msgclient, __gc = gc}

local function event_callback(proto, accept_cb, close_cb, data_cb)
	local EVENT = {}
	local queue = np.create()
	function EVENT.accept(fd, portid, addr)
		local ok, err = core.pcall(accept_cb, fd, addr)
		if not ok then
			core.log("[msg] EVENT.accept", err)
			core.close(fd)
		end
	end
	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close_cb, fd, errno)
		if not ok then
			core.log("[msg] EVENT.close", err)
		end
	end
	function EVENT.data()
		local f, d, sz, cmd = np.msgpop(queue)
		if not f then
			return
		end
		core.fork(EVENT.data)
		while true do
			local obj = proto:decode(cmd, d, sz)
			np.drop(d);
			local ok, err = core.pcall(data_cb, f, cmd, obj)
			if not ok then
				core.log("[msg] dispatch socket", err)
			end
			f, d, sz, cmd = np.msgpop(queue)
			if not f then
				return
			end
		end
	end
	return function (type, fd, message, ...)
		queue = np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
end

---server
local function servercb(sc, conf)
	local accept_cb = assert(conf.accept, "servercb accept")
	local close_cb = assert(conf.close, "servercb close")
	local data_cb = assert(conf.data, "servercb data")

	return function (type, fd, message, ...)
		queue = np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
end

local function sendmsg(self, fd, cmd, data)
	local proto = self.proto
	local dat = proto:encode(cmd, data)
	if type(cmd) == "string" then
		cmd = proto:tag(cmd)
	end
	return core.write(fd, np.msgpack(dat, cmd))
end

msgserver.send = sendmsg
msgserver.multicast = function(self, fd, data, sz)
	return core.multicast(fd, data, sz)
end

function msgserver.listen(self)
	local fd = core.listen(self.addr, self.callback, self.backlog)
	self.fd = fd
	return fd
end

function msgserver.stop(self)
	gc(self)
end

function msgserver.close(self, fd)
	core.close(fd)
end

-----client
local function wakeupall(self)
	local q = self.connectqueue
	for k, v in pairs(q) do
		core.wakeup(v)
		q[k] = nil
	end
end

local function checkconnect(self)
       if self.fd and self.fd >= 0 then
		return self.fd
	end
	if not self.fd then	--disconnected
		self.fd = -1
		local fd = core.connect(self.addr, self.callback)
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

function msgclient.close(self)
	gc(self)
end

function msgclient.send(self, cmd, data)
	local fd = checkconnect(self)
	if not fd then
		return false
	end
	return sendmsg(self, fd, cmd, data)
end

function msgclient.connect(self)
	local fd = checkconnect(self)
	return fd
end


function msg.createclient(conf)
	local obj = {
		fd = false,
		callback = false,
		addr = conf.addr,
		proto = conf.proto,
		connectqueue = {},
	}
	local close_cb = assert(conf.close, "clientcb close")
	local data_cb = assert(conf.data, "clientcb data")
	obj.callback = event_callback(conf.proto, nil, close_cb, data_cb)
	setmetatable(obj, clientmt)
	return obj
end

function msg.createserver(conf)
	local obj = {
		fd = false,
		callback = false,
		addr = conf.addr,
		proto = conf.proto,
	}
	local accept_cb = assert(conf.accept, "servercb accept")
	local close_cb = assert(conf.close, "servercb close")
	local data_cb = assert(conf.data, "servercb data")
	obj.callback = event_callback(conf.proto, accept_cb, close_cb, data_cb)
	setmetatable(obj, servermt)
	return obj
end


return msg

