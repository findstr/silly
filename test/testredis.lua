local core = require("core")
local redis = require("redis")

local function dprint(cmd, success, value)
        print(string.format('====%s:%s', cmd, success and "success" or "fail"))
        if type(value) == "table" then
                for i, v in ipairs(value) do
                        print(string.format("%d)%s", i, v))
                end
        else
                print(value)
        end
end

core.start(function ()
        redis.connect()
        dprint("PING", redis.ping())
        dprint("SET bar hello", redis.set("bar", "hello"))
        dprint("GET bar", redis.get("bar"))
        dprint("KEYS *", redis.keys("*"))
        dprint("EXISTS bar", redis.exists("bar"))
        dprint("EXISTS hello", redis.exists("hello"))
        dprint("DEL bar", redis.del("bar"))
        dprint("EXISTS bar", redis.exists("bar"))
        dprint("DEL bar", redis.del("bar"))

        dprint("SET foo 1", redis.set("foo", 1))
        dprint("TYPE foo", redis.type("foo"))
        dprint("TYPE bar", redis.type("bar"))
        dprint("LPUSH bar 1", redis.lpush("bar", 1))
        dprint("TYPE bar", redis.type("bar"))

        dprint("STRLEN bar", redis.strlen("foo"))


end)

