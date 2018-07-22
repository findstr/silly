local core = require "sys.core"

local modules = {
	"testtimer",
	"testsocket",
	"testdns",
	"testrpc",
	"testudp",
	"testwakeup",
	"testmulticast",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testcrypt",
	"testhttp",
	"testredis",
	"testmysql",
}

local M = ""
local gprint = print
local function print(...)
	gprint(M, ...)
end

assert(core.envget("hello") == "world")

_ENV.print = print

core.start(function()
	local entry = {}
	for k, v in pairs(modules) do
		entry[k] = require(v)
	end
	for k, v in ipairs(modules) do
		M = v .. ":"
		print("=========start=========")
		assert(entry[k])()
		print("======success==========")
	end
	core.exit()
end)




