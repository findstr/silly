local lprofiler = require "lprofiler"

local profiler = {}
local co_resume = nil
local co_yield = nil

function profiler.start()
        co_yield = coroutine.yield
        co_resume = coroutine.resume

        if co_yield == nil or co_resume == nil then
                print("profiler.start:get nil yield/resume function")
                return false
        end

        coroutine.yield = function (...)
                lprofiler.yield()
                co_yield(...)
                lprofiler.resume()
        end

        coroutine.resume = function (...)
                lprofiler.yield()
                co_resume(...)
                lprofiler.resume()
        end

        lprofiler.start()

        return true
end

function profiler.stop()
        lprofiler.stop()
        coroutine.yield = co_yield
        coroutine.resume = co_resume
end

function profiler.report()
        return lprofiler.report()
end

return profiler

