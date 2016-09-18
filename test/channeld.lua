local core = require "silly.core"
local channel = require "silly.channel"

local c1 = channel.channel()
local function test()
        local n1, _, n2 = c1:pop2()
        core.fork(test)
        assert(n2)
        print("value1x", n1)
        core.sleep(1)
        print("value1y", n2)
end

core.fork(test)

core.start(function()
        core.sleep(10)
        for i = 1, 3 do
                c1:push2("hello" .. i, nil, "world" .. i, nil)
        end
        core.sleep(1000)
        for i = 4, 6 do 
                c1:push2("hello" .. i, nil, "world" .. i, nil)
                core.sleep(1)
        end
end)


