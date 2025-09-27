local core = require "core"
local hive = require "core.hive"
local time = require "core.time"
local json = require "core.encoding.json"
local metrics = require "core.metrics.c"
local c = require "test.aux.c"
local type = type
local pairs = pairs
local tostring = tostring
local format = string.format
local testaux = {}
local m = ""
local rand = math.random

local meta_str = "abcdefghijklmnopqrstuvwxyz"
local meta = {}
for i = 1, #meta_str do
	meta[#meta + 1] = meta_str:sub(i, i)
end

math.randomseed(time.now())

--inhierit testaux.c function
for k, v in pairs(c) do
	testaux[k] = v
end

local function escape(a)
	if type(a) == "string" then
		return a:gsub("([%c\x7f-\xff])", function(s)
			return string.format("\\x%02x", s:byte(1))
		end)
	elseif type(a) == "table" then
		local l = {}
		for k, v in pairs(a) do
			local t = type(v)
			if t == "function" then
				v = tostring(v)
			elseif t == "number" then
				v = string.format("%g", v)
			end
			l[#l + 1] = {k, v}
		end
		table.sort(l, function(a, b)
			return tostring(a[1]) < tostring(b[1])
		end)
		return json.encode(l)
	else
		return a
	end
end

local bee = hive.spawn [[
	package.cpath = package.cpath .. ";luaclib/?.so;luaclib/?.dll"
	local c = require "test.aux.c"
	return function(fd, len)
		return c.recv(fd, len)
	end
]]

function testaux.recv(fd, n)
	return hive.invoke(bee, fd, n)
end

function testaux.randomdata(sz)
	local tbl = {}
	for i = 1, sz do
		tbl[#tbl+1] = meta[rand(#meta)]
	end
	return table.concat(tbl, "")
end

function testaux.checksum(acc, str)
	for i = 1, #str do
		acc = acc + str:byte(i)
	end
	return acc
end

local function tostringx(a, len)
	a = tostring(a)
	if #a > len then
		a = a:sub(1, len) .. "..."
	end
	return a
end

function testaux.hextostr(arr)
	local buf = {}
	for i = 1, #arr do
		buf[i] = format("%02x", arr:byte(i))
	end
	return table.concat(buf, "")
end

function testaux.error(str)
	print(format('\27[31m%sFAIL\t"%s"\27[0m', m, str))
	print(debug.traceback(1))
	core.exit(1)
end

function testaux.success(str)
	print(format('\27[32m%sSUCCESS\t"%s"\27[0m', m, str))
end

function testaux.asserteq(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 60)
	b = tostringx(bb, 60)
	if aa == bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" == "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" == "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertneq(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa ~= bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" ~= "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" ~= "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertlt(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa < bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t "%s" < "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t "%s" < "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertle(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa <= bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t "%s" <= "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" <= "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertgt(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa > bb then
		print(format('\27[32m%sSUCCESS\t"%s"\t"%s" > "%s"\27[0m', m, str, a, b))
	else
		print(format('\27[31m%sFAIL\t"%s"\t"%s" > "%s"\27[0m', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.module(name)
	if name == "" then
		m = ""
	else
		m = name .. ":"
	end
end

function testaux.asserteq_hex(actual, expected, message)
	local to_hex = function(s)
		return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end))
	end
	testaux.asserteq(to_hex(actual), to_hex(expected), message)

end

function testaux.assert_error(fn, str)
	local ok, err = pcall(fn)
	if not ok then
		print(format('\27[32m%sSUCCESS\t"%s" check exception \t\27[0m', m, str))
	else
		print(format('\27[31m%sFAIL\t"%s" check exception \t\27[0m', m, str))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.hexdump(s)
	return (s:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end

function testaux.netstat()
	local tcpclient, sent_bytes, received_bytes, operate_request, operate_processed = metrics.netstat()
	return {
		tcpclient = tcpclient,
		ctrlcount = operate_processed - operate_request,
	}
end

return testaux


