local core = require "silly.core"
local redis = require "redis"

local function dprint(cmd, success, value)
	print(string.format('====%s:%s', cmd, success and "success" or "fail"))
	if type(value) == "table" then
		for i, v in ipairs(value) do
			print(string.format("%d)%s", i, v))
		end
	else
		print(value)
	end
	collectgarbage("collect")
end

local db = nil
local F = 0
local function test1()
	local err
	db, err= redis:connect{
		addr = "127.0.0.1@6379",
	}
	print("Connect",  db, err)
	dprint("SELECT 10", db:select(10))
	dprint("PING", db:ping())
	dprint("SET bar hello", db:set("bar", "hello"))
	dprint("GET bar", db:get("bar"))
	dprint("KEYS *", db:keys("*"))
	dprint("EXISTS bar", db:exists("bar"))
	dprint("EXISTS hello", db:exists("hello"))
	dprint("DEL bar", db:del("bar"))
	dprint("EXISTS bar", db:exists("bar"))
	dprint("DEL bar", db:del("bar"))
	core.sleep(10000)
	dprint("SET foo 1", db:set("foo", 1))
	dprint("TYPE foo", db:type("foo"))
	dprint("TYPE bar", db:type("bar"))
	dprint("LPUSH bar 1", db:lpush("bar", 1))
	dprint("TYPE bar", db:type("bar"))
	dprint("STRLEN bar", db:strlen("foo"))
	dprint("HMSET hash k1 v1 k2 v2", db:hmset("hash", "k1", "v1", "k2", "v2"))
	dprint("HGET hash k1", db:hget("hash", "k1"))
	dprint("HGETALL hash", db:hgetall("hash"))
	print("test finish")
	F = F + 1
end

local function test2()
	core.sleep(5000)
	print("test begin2")
	dprint("PING", db:ping())
	dprint("SET bar hello", db:set("bar", "hello"))
	dprint("GET bar", db:get("bar"))
	print("test finish2")
	F = F + 1
end


return function()
	core.fork(test1)
	core.fork(test2)
	while true do
		if F >= 2 then
			break
		end
		core.sleep(100)
	end
end

