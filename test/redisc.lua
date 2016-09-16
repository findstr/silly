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

core.start(function ()
        local err
        db, err= redis:connect{
                addr = "127.0.0.1@6379",
        }
        print("Connect",  db, err)
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
        print("test finish")
        core.exit()
end)

core.start(function ()
        core.sleep(5000)
        print("test begin2")
        dprint("PING", db:ping())
        dprint("SET bar hello", db:set("bar", "hello"))
        dprint("GET bar", db:get("bar"))
        print("test finish2")
end)

