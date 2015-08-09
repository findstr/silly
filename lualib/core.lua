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

function core.start(func)
        local co = coroutine.create(func)
        coroutine.resume(co)
end

function core.block()
        return coroutine.yield()
end

function core.self()
        return coroutine.running()
end

function core.run(co, ...)
        return coroutine.resume(co, ...)
end


return core

