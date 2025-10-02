local silly = require "silly"
local np = require "silly.netpacket"
local testaux = require "test.testaux"

local BUFF

local function rawtostring(buff, sz)
	local str = silly.tostring(buff, sz)
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
	testaux.asserteq(#raw, len, "random packet length")
	local pk = string.pack(">I2", #raw + 16) .. string.pack("<c" .. #raw, raw) .. string.pack("<I8I8", 0, 0)
	return raw, pk
end

local function justpush(sid, pk)
	local ptr, size = testaux.new(pk)
	np.push(BUFF, sid, ptr, size)
end

local function randompush(sid, pk)
	local i = 1
	local len = #pk + 1
	local buf = {}
	while i < len do
		local last = len - i
		if last > 2 then
			last = last // 2
			last = math.random(1, last)
		end
		local x = pk:sub(i, i + last - 1)
		i = i + last;
		buf[#buf + 1] =  x
		justpush(sid, x)
	end
	assert(table.concat(buf), pk)
end

local function pushbroken(sid, pk)
	local pk2 = pk:sub(1, #pk - 17)
	randompush(sid, pk2)
end

local function testhashconflict_part1()
	local dat = "\x00\x101234567812345678"
	local part1 = dat:sub(1, 7)
	justpush(0, part1)
	justpush(2048, part1)
	justpush(4096, part1)
	justpush(8192, part1)
end

local function testhashconflict_part2()
	local dat = "\x00\x101234567812345678"
	local part2 = dat:sub(8, -1)
	justpush(2048, part2)
	justpush(4096, part2)
	justpush(8192, part2)
	justpush(0, part2)
	local fd, data = popdata()
	testaux.asserteq(fd, 2048, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 4096, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 8192, "netpacket first packet")
	local fd, data = popdata()
	testaux.asserteq(fd, 0, "netpacket first packet")

end

local function testpacket(push)
	print("--------testpacket-----------")
	local raw, pk = buildpacket()
	local sid = math.random(8193, 65535)
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
	local sid = math.random(8193, 65535)
	pushbroken(sid, pk)
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
		local sid = math.random(8193, 65535)
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

collectgarbage("collect")
local seedx, seedy = math.randomseed()
print("seed", seedx, seedy)
math.randomseed(1721030230,139887399596712)

BUFF = np.create()
testhashconflict_part1()
testpacket(justpush)
testpacket(randompush)
testclear()
testexpand()
testhashconflict_part2()
BUFF = nil
collectgarbage("collect")

