local silly = require("silly")
local timer = require("timer")

local core = {}

function core.workid()
        return silly.workid()
end

local function wakeup(co)
        coroutine.resume(co)
end

function core.sleep(ms)
        timer.add(ms, wakeup, coroutine.running())
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

local function resume_wrapper(ret, ...)
        if (ret == true) then
                return ...
        else
                local err = ...
                print(err)
                return nil
        end
end

function core.run(co, ...)
        return resume_wrapper(coroutine.resume(co, ...))
end


return core

