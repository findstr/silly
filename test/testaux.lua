local core = require "sys.core"
local c = require "test.aux.c"
local type = type
local format = string.format
local testaux = {}
local m = ""
local rand = math.random

local meta_str = "abcdefghijklmnopqrstuvwxyz"
local meta = {}
for i = 1, #meta_str do
	meta[#meta + 1] = meta_str:sub(i, i)
end

math.randomseed(core.now())

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

function testaux.asserteq(a, b, str)
	a = escape(a)
	b = escape(b)
	if a == b then
		print(format('%s\tSUCCESS\t"%s"\t"%s" == "%s"', m, str, a, b))
	else
		print(format('%s\tFAIL\t"%s"\t"%s" == "%s"', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertneq(a, b, str)
	a = escape(a)
	b = escape(b)
	if a ~= b then
		print(format('%s\tSUCCESS\t"%s"\t"%s" ~= "%s"', m, str, a, b))
	else
		print(format('%s\tSUCCESS\t"%s"\t"%s" ~= "%s"', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.assertle(a, b, str)
	a = escape(a)
	b = escape(b)
	if a <= b then
		print(format('SUCCESS\t"%s"\t "%s" <= "%s"', m, str, a, b))
	else
		print(format('FAIL\t"%s"\t"%s" <= "%s"', m, str, a, b))
		print(debug.traceback(1))
		core.exit(1)
	end
end

function testaux.module(name)
	m = name
end

return testaux


