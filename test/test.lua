local core = require "core"
local env = require "core.env"
local logger = require "core.logger"
local metrics = require "core.metrics.c"
local testaux = require "test.testaux"

local function netstat()
	local connecting, tcpclient, ctrlcount = metrics.netstat()
	return {
		connecting = connecting,
		tcpclient = tcpclient,
		ctrlcount = ctrlcount,
	}
end

local modules = {
	"testcompress",
	"testjson",
	"testdom",
	"testtimer",
	"testtcp",
	"testudp",
	"testdns",
	"testrpc",
	"testgrpc",
	"testhttp",
	"testhttp2",
	"testwakeup",
	"testwaitgroup",
	"testmutex",
	"testnetstream",
	"testnetpacket",
	"testchannel",
	"testxor",
	"testbase64",
	"testhash",
	"testcipher",
	"testrsa",
	"testec",
	"testhmac",
	"testjwt",
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
	local netinfo1 = netstat()
	dofile("test/" .. v .. ".lua")
	core.sleep(500)
	local netinfo2 = netstat()
	testaux.asserteq(netinfo1.tcpclient, netinfo2.tcpclient)
	testaux.module("")
	print("======success==========")
end




