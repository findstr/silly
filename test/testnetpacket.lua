local core = require "sys.core"
local np = require "sys.netpacket"
local testaux = require "testaux"
local P = require "print"

local BUFF

local function rawtostring(buff, sz)
	local str = core.tostring(buff, sz)
	np.drop(buff)
	return str
end

local function popdata()
	local fd, buff, sz = np.pop(BUFF)
	if not fd then
		return fd, buff
	end
	local data = rawtostring(buff, sz)
	return fd, data
end

local function buildpacket()
	local len = math.random(1, 30)
	local raw = testaux.randomdata(len)
	assert(#raw == len)
	local pk = string.pack(">I2", #raw) .. string.pack("<c" .. #raw, raw)
	return raw, pk
end

local function justpush(sid, pk)
	local msg = testaux.newdatamsg(sid, pk)
	BUFF = np.message(BUFF, msg)
end

local function randompush(sid, pk)
	local i = 1
	local len = #pk + 1
	while i < len do
		local last = len - i
		if last > 2 then
			last = last // 2
			last = math.random(1, last)
		end
		local x = pk:sub(i, i + last - 1)
		i = i + last;
		justpush(sid, x)
	end
end

local function pushbroken(sid, pk)
	local pk2 = pk:sub(1, #pk - 1)
	randompush(sid, pk2)
	local fd, data = popdata()
	assert(not fd)
	assert(not data)
end

local function testpacket(push)
	print("--------testpacket-----------")
	local raw, pk = buildpacket()
	local sid = math.random(1, 65535)
	push(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(sid, fd, "netpacket test fd")
	testaux.asserteq(raw, data, "netpacket test data")
	fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket empty test fd")
	testaux.asserteq(data, nil, "netpacket empty test data")
end

local function testclear()
	print("--------testclear-----------")
	local raw, pk = buildpacket()
	local sid = math.random(1, 65535)
	pushbroken(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket broken test fd")
	testaux.asserteq(data, nil, "netpacket broken test data")
	randompush(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(fd, sid, "netpacket broken test fd")
	testaux.assertneq(data, raw, "netpacket broken test data")
	local fd, data = popdata()
	testaux.asserteq(fd, nil, "netpacket broken test fd")
	testaux.asserteq(data, nil, "netpacket broken test data")
	np.clear(BUFF, sid)
	randompush(sid, pk)
	local fd, data = popdata()
	testaux.asserteq(fd, sid, "netpacket clear test fd")
	testaux.asserteq(data, raw, "netpacket clear test fd")
end


local function testexpand()
	print("--------testexpand----------")
	local queue = {}
	local total = 8194
	print("push broken data")
	local raw, pk = buildpacket()
	local sid = 1
	pushbroken(sid, pk)
	print("begin push complete data")
	for i = 1, total do
		local raw, pk = buildpacket()
		local sid = math.random(2, 65535)
		queue[#queue + 1] = {
			fd = sid,
			raw = raw,
		}
		randompush(sid, pk)
	end
	print("push complete, begin to pop")
	for i = 1, total do
		local obj = table.remove(queue, 1)
		local fd, buff, sz = np.pop(BUFF)
		testaux.assertneq(fd, nil, "test queue expand of " .. i)
		local data = rawtostring(buff, sz)
		testaux.asserteq(obj.fd, fd, "test queue expand fd")
		testaux.asserteq(obj.raw, data, "test queue expand fd")
	end
end

return function()
	collectgarbage("collect")
	BUFF = np.create()
	testpacket(justpush)
	testpacket(randompush)
	testclear()
	testexpand()
	BUFF = nil
	collectgarbage("collect")
end

