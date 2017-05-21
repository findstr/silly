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
local function servercb(sc)
        local EVENT = {}
        local queue = np.create()
        function EVENT.accept(fd, portid, addr)
                local ok, err = core.pcall(sc.accept, fd, addr)
                if not ok then
                        print("[msg] EVENT.accept", err)
                        core.close(fd, TAG)
                end
        end

        function EVENT.close(fd, errno)
                local ok, err = core.pcall(assert(sc).close, fd, errno)
                if not ok then
                        print("[msg] EVENT.close", err)
                end
        end

        function EVENT.data()
                local f, d, sz = np.pop(queue)
                if not f then
                        return
                end
                core.fork(EVENT.data)
		local ok, err = core.pcall(sc.data, f, d, sz)
                if not ok then
                        print("[msg] dispatch socket", err)
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

function msgserver.start(self)
	local fd = core.listen(self.addr, servercb(self), TAG)
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

local function clientcb(sc)
        local EVENT = {}
        local queue = np.create()
	sc.queuedat = {}
        function EVENT.accept(fd, portid, addr)
		assert(not "never come here")
        end

        function EVENT.close(fd, errno)
		local ok, err = core.pcall(assert(sc).close, fd, errno)
		sc.fd = false
                if not ok then
                        print("[msg] EVENT.close", err)
                end
        end

        function EVENT.data()
                local f, d, sz = np.pop(queue)
                if not f then
                        return
                end
                core.fork(EVENT.data)
		local ok, err = core.pcall(assert(sc).data, f, d, sz)
		if not ok then
			print("[msg] EVENT.data", err)
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
		local ok
		local fd = core.connect(self.addr, clientcb(self), nil, TAG)
		if not fd then
			self.fd = false
			ok = false
		else
			self.fd = fd
			ok = true
		end
		wakeupall(self)
		return ok
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
		connectqueue = {},
	}
	for k, v in pairs(config) do
		assert(not obj[k])
		obj[k] = v
	end
	setmetatable(obj, clientmt)
	return obj
end

function msg.createserver(config)
	local obj = {
		fd = false,
	}
	for k, v in pairs(config) do
		obj[k] = v
	end
        setmetatable(obj, servermt)
        return obj
end


return msg

