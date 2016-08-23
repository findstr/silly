local core = require "silly.core"
local channel = require "silly.channel"

local c1 = channel.run(function(n1, n2)
        print("value1x", n1)
        core.sleep(1)
        print("value1y", n2)
end)

core.start(function()
        for i = 1, 3 do
                c1:push("hello" .. i, "world" .. i)
        end
        core.sleep(10)
        for i = 4, 6 do 
                c1:push("hello" .. i, "world" .. i)
                core.sleep(1)
        end
end)


