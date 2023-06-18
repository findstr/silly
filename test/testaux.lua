local core = require "sys.core"
local time = require "sys.time"
local json = require "sys.json"
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
		return a:gsub("([\x0d\x0a])", function(s)
			local c = s:byte(1)
			if c == 0x0d then
				return "\\r"
			else
				return "\\n"
			end
		end)
	elseif type(a) == "table" then
		local l = {}
		for k, v in pairs(a) do
			if type(v) == "function" then
				v = tostring(v)
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
	print(format('%s\tFAIL\t"%s"', m, str))
	print(debug.traceback(1))
	core.exit(1)
end
function testaux.success(str)
	print(format('%s\tSUCCESS\t"%s"', m, str))
end

function testaux.asserteq(a, b, str)
	local aa = escape(a)
	local bb = escape(b)
	a = tostringx(aa, 30)
	b = tostringx(bb, 30)
	if aa == bb then
		print(format('%s\tSUCCESS\t"%s"\t"%s" == "%s"', m, str, a, b))
	else
		print(format('%s\tFAIL\t"%s"\t"%s" == "%s"', m, str, a, b))
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
		print(format('%s\tSUCCESS\t"%s"\t"%s" ~= "%s"', m, str, a, b))
	else
		print(format('%s\tFAIL\t"%s"\t"%s" ~= "%s"', m, str, a, b))
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
		print(format('%s\tSUCCESS\t"%s"\t "%s" <= "%s"', m, str, a, b))
	else
		print(format('%s\tFAIL\t"%s"\t"%s" <= "%s"', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.module(name)
	m = name
end

return testaux


