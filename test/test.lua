local core = require "sys.core"
local testaux = require "testaux"

local modules = {
	"testjson",
	"testdom",
	"testtimer",
	"testsocket",
	"testdns",
	"testrpc",
	"testudp",
	"testwakeup",
	"testwaitgroup",
	"testmulticast",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testcrypto",
	"testhttp",
	"testhttp2",
	"testwebsocket",
	"testredis",
	"testmysql",
	"testexit",
}

local M = ""
local gprint = print
local function print(...)
	gprint(M, ...)
end

assert(core.envget("hello.1.1") == "world")

_ENV.print = print

local ok, res = pcall(core.wait)
assert(not ok)

core.start(function()
	local entry = {}
	for k, v in pairs(modules) do
		entry[k] = require(v)
	end
	for k, v in ipairs(modules) do
		M = v .. ":"
		print("=========start=========")
		testaux.module(v)
		local ok, err = pcall(entry[k])
		if not ok then
			print(err)
			core.exit(1)
		end
		print("======success==========")
	end
end)




