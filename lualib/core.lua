local silly = require("silly")
local timer = require("timer")

local core = {}

function core.workid()
        return silly.workid()
end

local function wakeup()
        local co = coroutine.running()
        return function ()
                coroutine.resume(co)
        end
end

function core.sleep(ms)
        timer.add(ms, wakeup())
        coroutine.yield()
end

return core

