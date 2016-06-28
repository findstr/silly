local core = require "silly.core"

local closure = {}
local function gen_closure(n)
        return function ()
                print("clouser", n)
        end
end

for i = 1, 30 do
        closure[i] = gen_closure(i)
        core.timeout(1000, closure[i])
end

core.start(function()
        print("hello")
        print("current begin", core.now())
        core.sleep(5000)
        print("current end", core.now())
        print("world")
end)

