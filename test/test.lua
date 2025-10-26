local silly = require "silly"
local time = require "silly.time"
local env = require "silly.env"
local dns = require "silly.net.dns"
local testaux = require "test.testaux"

dns.server("223.5.5.5:53")

local netstat = testaux.netstat

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
local testset = env.get("set")
local case = env.get("case")
M = testset .. ":"
print("=========start=========")
if case then
	print("Running subset:", case)
	testaux.filtercase(case)
end
local netinfo1 = netstat()
local function traceback(err)
    return debug.traceback(err, 2)
end
local ok, err = xpcall(function() dofile("test/" .. testset .. ".lua") end, traceback)
if not ok then
	print("FAIL crash:", err)
	silly.exit(1)
end
time.sleep(500)
local netinfo2 = netstat()
testaux.asserteq(netinfo1.tcpclient, netinfo2.tcpclient, testset .. ":netstat")
testaux.module("")
silly.exit(0)
