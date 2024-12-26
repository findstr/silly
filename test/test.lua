local core = require "core"
local logger = require "core.logger"
local metrics = require "core.metrics.c"
local env = require "core.env"
local testaux = require "test.testaux"

local modules = {
	"testjson",
	"testdom",
	"testtimer",
	"testtcp",
	"testudp",
	"testdns",
	"testrpc",
	"testgrpc",
	"testwakeup",
	"testwaitgroup",
	"testmutex",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testcrypto",
	"testhttp",
	"testhttp2",
	"testhpack",
	"testwebsocket",
	"testpatch",
}
if metrics.pollapi() == "epoll" then
	modules[#modules + 1] = "testredis"
	modules[#modules + 1] = "testmysql"
end
modules[#modules + 1] = "testexit"

logger.info("test start, pollapi:", metrics.pollapi())

local M = ""
local gprint = print
local function print(...)
	gprint(M, ...)
end
assert(not env.load("test/test.conf"))
assert(env.get("hello.1.1") == "world")
env.set("hello.1.1", "hello")
assert(env.get("hello.1.1") == "hello")

_ENV.print = print
core.sleep(1000)
for k, v in ipairs(modules) do
	M = v .. ":"
	print("=========start=========")
	testaux.module(v)
	dofile("test/" .. v .. ".lua")
	print("======success==========")
end




