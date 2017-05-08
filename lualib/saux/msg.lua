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

local NIL = {}

local function decode(proto, d, sz)
	local str = core.tostring(d, sz)
	np.drop(d)
	local len = #str
	assert(len >= 4)
	local data
	local cmd = string.unpack("<I4", str)
	if (len > 4) then
		data = proto:decode(cmd, str:sub(4+1))
	else
		data = NIL
	end
	return cmd, data
end

---server
local function servercb(sc)
        local EVENT = {}
        local queue = np.create()
        function EVENT.accept(fd, portid, addr)
                local ok, err = core.pcall(sc.accept, fd, addr)
                if not ok then
                        print("[gate] EVENT.accept", err)
                        core.close(fd, TAG)
                end
        end

        function EVENT.close(fd, errno)
                local ok, err = core.pcall(assert(sc).close, fd, errno)
                if not ok then
                        print("[gate] EVENT.close", err)
                end
        end

        function EVENT.data()
                local f, d, sz = np.pop(queue)
                if not f then
                        return
                end
                core.fork(EVENT.data)
		local cmd, data = decode(sc.proto, d, sz)
		if not data then
			return
		end
		local ok, err = core.pcall(sc.data, f, cmd, data)
                if not ok then
                        print("[gate] dispatch socket", err)
                end
        end

        return function (type, fd, message, ...)
                queue = np.message(queue, message)
                assert(EVENT[type])(fd, ...)
        end
end

local function sendmsg(self, fd, cmd, body)
	local proto = self.proto
	if type(cmd) == "string" then
		cmd = proto:querytag(cmd)
	end
	local cmddat = string.pack("<I4", cmd)
	local bodydat = proto:encode(cmd, body)
	return core.write(fd, np.pack(cmddat .. bodydat))
end

msgserver.send = sendmsg

function msgserver.start(self)
	local fd = core.listen(self.addr, servercb(self), TAG)
	self.fd = fd
	return fd
end

function msgserver.close(self)
	gc(self)
end

-----client

local function clientcb(sc)
        local EVENT = {}
        local queue = np.create()
	sc.waitco = false
	sc.queuecmd = {}
	sc.queuedat = {}
        function EVENT.accept(fd, portid, addr)
		assert(not "never come here")
        end

        function EVENT.close(fd, errno)
		local co = sc.waitco
		if co then
			sc.fd = false
			core.wakeup(co, false)
			sc.waitco = false
		end
        end

        function EVENT.data()
                local f, d, sz = np.pop(queue)
                if not f then
                        return
                end
                core.fork(EVENT.data)
		local cmd, data = decode(sc.proto, d, sz)
		if not data then
			return
		end
		local qc = sc.queuecmd
		local qd = sc.queuedat
		qc[#qc + 1] = cmd
		qd[#qd + 1] = data
		local co = sc.waitco
		if co then
			sc.waitco = false
			core.wakeup(co, true)
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

function msgclient.read(self)
	if not self.fd then
		return nil
	end
	if #self.queuecmd == 0 then
		self.waitco = core.running()
		local ok = core.wait()
		if not ok then
			return nil
		end
	end
	assert(#self.queuecmd > 0)
	local cmd = table.remove(self.queuecmd, 1)
	local dat = table.remove(self.queuedat, 1)
	return cmd, dat
end

function msgclient.close(self)
	gc(self)
end

function msgclient.send(self, cmd, body)
	local fd = checkconnect(self)
	if not fd then
		return false
	end
	return sendmsg(self, fd, cmd, body)
end


function msgclient.connect(self)
	local fd = checkconnect(self)
	return fd
end


function msg.createclient(config)
	local obj = {
		fd = false,
		waitco = false,
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

