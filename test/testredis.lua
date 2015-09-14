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

local db = redis:create {
        ip = "127.0.0.1",
        port = 6379
}

core.start(function ()
        print("Connect", db:connect())
        dprint("PING", db:ping())
        dprint("SET bar hello", db:set("bar", "hello"))
        dprint("GET bar", db:get("bar"))
        dprint("KEYS *", db:keys("*"))
        dprint("EXISTS bar", db:exists("bar"))
        dprint("EXISTS hello", db:exists("hello"))
        dprint("DEL bar", db:del("bar"))
        dprint("EXISTS bar", db:exists("bar"))
        dprint("DEL bar", db:del("bar"))

        dprint("SET foo 1", db:set("foo", 1))
        dprint("TYPE foo", db:type("foo"))
        dprint("TYPE bar", db:type("bar"))
        dprint("LPUSH bar 1", db:lpush("bar", 1))
        dprint("TYPE bar", db:type("bar"))

        dprint("STRLEN bar", db:strlen("foo"))

        print("test finish")

end)

core.start(function ()
        core.sleep(1000)
        print("test begin2")
        print("Connect", db:connect())
        dprint("PING", db:ping())
        dprint("SET bar hello", db:set("bar", "hello"))
        dprint("GET bar", db:get("bar"))
        print("test finish2")
end)

