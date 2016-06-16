local core = require "silly.core"

local closure = {}

local last = nil

local function wrap(str, last)
        return function()
                core.wait()
                if last then
                        print("#", last)
                        core.wakeup(last)
                end
                print(str, "exit")
        end
end

local function create(str)
        if last then
                table.insert(closure, last)
        end
        local tmp =  core.fork(wrap(str, last))
        print(tmp)
        last = tmp
end


core.start(function()
for i = 1, 5 do
        create("test" .. i)
end
core.sleep(100)
print("--------------")
core.fork(function ()
        print("-", last)
        core.wakeup(last)
end)
end)

