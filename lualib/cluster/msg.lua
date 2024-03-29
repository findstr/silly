local core = require "sys.core"
local np = require "sys.netpacket"
local pairs = pairs
local assert = assert
local type = type
local msg = {}
local msgserver = {}
local msgclient = {}
local queue = np.create()

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
			--parse
			local dat, size = proto:unpack(d, sz, true)
			np.drop(d)
			local obj = proto:decode(cmd, dat, size)
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
		np.message(queue, message)
		assert(EVENT[type])(fd, ...)
	end
end

---server
local function sendmsg(self, fd, cmd, data)
	local proto = self.proto
	if type(cmd) == "string" then
		cmd = proto:tag(cmd)
	end
	local dat, sz = proto:encode(cmd, data, true)
	dat, sz= proto:pack(dat, sz, true)
	return core.write(fd, np.msgpack(dat, sz, cmd))
end
msgserver.send = sendmsg
msgserver.sendbin = function(self, fd, cmd, bin)
	return core.write(fd, np.msgpack(bin, cmd))
end
msgserver.multipack = function(self, cmd, dat, n)
	local proto = self.proto
	if type(cmd) == "string" then
		cmd = proto:tag(cmd)
	end
	local dat, sz = proto:encode(cmd, dat, true)
	dat, sz = proto:pack(dat, sz, true)
	dat, sz = np.msgpack(dat, sz, cmd)
	dat, sz = core.multipack(dat, sz, n)
	return dat, sz
end

msgserver.multicast = function(self, fd, data, sz)
	return core.multicast(fd, data, sz)
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
		core.wait()
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

function msg.connect(conf)
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
	checkconnect(obj)
	return obj
end

function msg.listen(conf)
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
	local fd, errno = core.listen(obj.addr, obj.callback, obj.backlog)
	if not fd then
		return nil, errno
	end
	return obj
end


return msg

