local core = require "sys.core"
local env = require "sys.env"
local testaux = require "testaux"

local modules = {
	"testjson",
	"testdom",
	"testtimer",
	"testtcp",
	"testudp",
	"testdns",
	"testrpc",
	"testwakeup",
	"testwaitgroup",
	"testmutex",
	"testmulticast",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testcrypto",
	"testhttp",
	"testhttp2",
	"testhpack",
	"testwebsocket",
	"testpatch",
	"testredis",
	"testmysql",
	"testexit",
}

local M = ""
local gprint = print
local function print(...)
	gprint(M, ...)
end

assert(env.get("hello.1.1") == "world")
env.set("hello.1.1", "hello")
assert(env.get("hello.1.1") == "hello")

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




