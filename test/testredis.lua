local core = require "sys.core"
local redis = require "sys.db.redis"
local testaux = require "testaux"

local function asserteq(cmd, expect_success, expect_value, success, value)
	if type(value) == "table" then
		value = value[1]
	end
	print(string.format('====%s:%s', cmd, success and "success" or "fail"))
	testaux.asserteq(success, expect_success, cmd)
	if success then	--Redis 3.2 has different error message
		testaux.asserteq(value, expect_value, cmd)
	end
	collectgarbage("collect")
end

local db = nil
local function testbasic()
	local err
	db, err= redis:connect{
		addr = "127.0.0.1:6379",
		db = 11,
	}
	db:flushdb()
	asserteq("PING",true, "PONG\r\n", db:ping())
	asserteq("SET foo bar", true, "OK\r\n", db:set("foo", "bar"))
	asserteq("GET foo", true, "bar", db:get("foo"))
	asserteq("KEYS fo*", true, "foo", db:keys("fo*"))
	asserteq("EXISTS foo", true, 1, db:exists("foo"))
	asserteq("EXISTS hello", true, 0, db:exists("hello"))
	asserteq("DEL foo", true, 1, db:del("foo"))
	asserteq("EXISTS foo", true, 0, db:exists("foo"))
	asserteq("DEL foo", true, 0, db:del("foo"))
	asserteq("SET foo 1", true, "OK\r\n", db:set("foo", 1))
	asserteq("TYPE foo", true, "string\r\n", db:type("foo"))
	asserteq("TYPE bar", true, "none\r\n", db:type("bar"))
	asserteq("LPUSH bar 1", true, 1, db:lpush("bar", 1))
	asserteq("TYPE bar", true, "list\r\n", db:type("bar"))
	asserteq("STRLEN bar", false, "ERR Operation against a key holding the wrong kind of value\r\n", db:strlen("bar"))
	asserteq("HMSET hash k1 v1 k2 v2", true, "OK\r\n", db:hmset("hash", "k1", "v1", "k2", "v2"))
	asserteq("HGET hash k1", true, "v1", db:hget("hash", "k1"))
	asserteq("HGETALL hash", true, "k1", db:hgetall("hash"))
end

return function()
	local testcount = 1024
	local finish = 0
	local idx = 0
	print("-----test basic-----")
	testbasic()
	print("-----test cocurrent:", testcount)
	db:del("foo")
	for i = 1, testcount do
		core.fork(function()
			idx = idx + 1
			local id = idx
			local ok, get = db:incr("foo")
			core.sleep(math.random(1, 100))
			testaux.asserteq(ok, true, "INCR foo")
			testaux.asserteq(id, get, "INCR foo")
			finish = finish + 1
			print("----finish:", finish)
		end)
		core.sleep(math.random(1, 10))
	end
	while true do
		if finish == testcount then
			break
		end
		core.sleep(500)
	end
end

