local silly = require "silly"
local timer = require "silly.timer"

local core = {}

function core.workid()
        return silly.workid()
end

function core.exit(func)
        silly.exit_register(func)
end

local function wakeup(co)
        coroutine.resume(co)
end

function core.sleep(ms)
        timer.add(ms, wakeup, coroutine.running())
        coroutine.yield()
end

local function resume_wrapper(ret, ...)
        if (ret == false) then
                local err = ...
                print(err)
        end

        return ret, ...
end


function core.start(func, ...)
        local co = coroutine.create(func)
        return resume_wrapper(coroutine.resume(co, ...))
end

function core.create(func)
        local co = coroutine.create(func)
        return co
end

function core.block()
        return coroutine.yield()
end

function core.self()
        return coroutine.running()
end

function core.running()
        return coroutine.running()
end

function core.run(co, ...)
        return resume_wrapper(coroutine.resume(co, ...))
end

function core.wakeup(co, ...)
        return resume_wrapper(coroutine.resume(co, ...))
end


return core

