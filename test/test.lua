local core = require "silly.core"

local modules = {
	"testtag",
	"testsocket",
	"testmulticast",
	"testdns",
	"testrpc",
	"testudp",
	"testwakeup",
	"testtimer",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testcrypt",
	"testredis",
	"testhttp",
}

local M = ""
local gprint = print
local function print(...)
	gprint(M, ...)
end

_ENV.print = print

core.start(function()
	local entry = {}
	for k, v in pairs(modules) do
		entry[k] = require(v)
	end

	for k, v in ipairs(modules) do
		M = v .. ":"
		print("=========start=========\n")
		assert(entry[k])()
		print("======success==========\n")
	end
	core.exit()
end)




