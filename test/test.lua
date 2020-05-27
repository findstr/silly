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

assert(core.envget("hello") == "world")

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
		assert(entry[k])()
		print("======success==========")
	end
end)




