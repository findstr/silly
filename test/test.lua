local silly = require "silly"
local log = require "silly.logger"
local time = require "silly.time"
local env = require "silly.env"
local dns = require "silly.net.dns"
local testaux = require "test.testaux"

dns.server("223.5.5.5:53")

log.info {
	version = silly.version,
	string = "hello",
	empty_string = "",
	long_string = string.rep("a", 1024),
	unicode = "汉字🙂",
	integer = 1234567890,
	float = 3.14159,
	negative = -42,
	zero = 0,
	inf = 1/0,
	nan = 0/0,
	boolean_true = true,
	boolean_false = false,
	array = {1, 2, 3, "four", {nested = "deep"}},
	nested = {
		level1 = {
			level2 = {
				val = "deep",
				arr = { {x=1}, {x=2} }
			}
		}
	},
	complex_key_table = (function()
		local k = {}
		return { [k] = "table key (should be tested)" }
	end)(),
	func = function() return "hello from func" end,
	meta = setmetatable({a=1}, {__tostring = function() return "metatable" end}),
	byte_data = ("\0\1\2\3"):rep(4),
	cyclic = (function() local t = {}; t.self = t; return t end)(),
}

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
