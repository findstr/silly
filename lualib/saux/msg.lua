local core = require "silly.core"
local np = require "netpacket"
local TAG = "saux.msg"

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
	core.close(obj.fd, TAG)
	obj.fd = false
end

local servermt = {__index = msgserver, __gc == gc}
local clientmt = {__index = msgclient, __gc == gc}

---server
local function servercb(sc, config)
	local EVENT = {}
	local queue = np.create()
	local accept_cb = assert(config.accept, "servercb accept")
	local close_cb = assert(config.close, "servercb close")
	local data_cb = assert(config.data, "servercb data")

	function EVENT.accept(fd, portid, addr)
		local ok, err = core.pcall(accept_cb, fd, addr)
		if not ok then
			core.log("[msg] EVENT.accept", err)
			core.close(fd, TAG)
		end
	end

	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close_cb, fd, errno)
		if not ok then
			core.log("[msg] EVENT.close", err)
		end
	end

	function EVENT.data()
		local f, d, sz = np.pop(queue)
		if not f then
			return
		end
		core.fork(EVENT.data)
		while true do
			local ok, err = core.pcall(data_cb, f, d, sz)
			if not ok then
				core.log("[msg] dispatch socket", err)
			end
			f, d, sz = np.pop(queue)
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

local function sendmsg(self, fd, data)
	return core.write(fd, np.pack(data))
end

msgserver.send = sendmsg
msgserver.multicast = function(self, fd, data, sz)
	return core.multicast(fd, data, sz)
end

function msgserver.start(self)
	local fd = core.listen(self.addr, self.callback, TAG)
	self.fd = fd
	return fd
end

function msgserver.stop(self)
	gc(self)
end

function msgserver.close(self, fd)
	core.close(fd, TAG)
end

-----client

local function clientcb(sc, config)
	local EVENT = {}
	local queue = np.create()
	sc.queuedat = {}
	local close_cb = assert(config.close, "clientcb close")
	local data_cb = assert(config.data, "clientcb data")
	function EVENT.accept(fd, portid, addr)
		assert(not "never come here")
	end

	function EVENT.close(fd, errno)
		local ok, err = core.pcall(close_cb, fd, errno)
		sc.fd = false
		if not ok then
			core.log("[msg] EVENT.close", err)
		end
	end

	function EVENT.data()
		local f, d, sz = np.pop(queue)
		if not f then
			return
		end
		core.fork(EVENT.data)
		while true do
			local ok, err = core.pcall(data_cb, f, d, sz)
			if not ok then
				core.log("[msg] EVENT.data", err)
			end
			f, d, sz = np.pop(queue)
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
		local fd = core.connect(self.addr, self.callback, nil, TAG)
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

function msgclient.send(self, data)
	local fd = checkconnect(self)
	if not fd then
		return false
	end
	return sendmsg(self, fd, data)
end

function msgclient.connect(self)
	local fd = checkconnect(self)
	return fd
end


function msg.createclient(config)
	local obj = {
		fd = false,
		addr = config.addr,
		callback = false,
		connectqueue = {},
	}
	obj.callback = clientcb(obj, config),
	setmetatable(obj, clientmt)
	return obj
end

function msg.createserver(config)
	local obj = {
		fd = false,
		addr = config.addr,
		callback = false,
	}
	obj.callback = servercb(obj, config)
	setmetatable(obj, servermt)
	return obj
end


return msg

