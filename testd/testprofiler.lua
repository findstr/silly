local profiler = require "profiler"
local core = require "silly.core"

local function dump_table(title, tbl)
        print(title)
        for k, v in pairs(tbl) do
                if type(v) == "table" then
                        dump_table(title, v)
                else
                        print(k, v)
                end
        end
end

--test single function
local function testa(n)
        local f = function()
                for i = 1, 10000000 do
                        n = n + 3
                end
                print(n)
        end

        return f
end

local f1 = testa(5)
local f2 = testa(8)

profiler.start()

f1()
f2()
f1()

profiler.stop()

local tbl = profiler.report()
for k, v in pairs(tbl) do
        print("===========thread", k)
        dump_table("total_time-------", v.total_time)
        dump_table("call_time--------", v.call_times)
        --dump_table("db_info----------", v.debug_info)
end

print("-----------------test coroutine----------------------")

-- test thread
local function test3()
        f1()
        f2()
        core.sleep(3000)
        f1()
end

local function test4()
        f1()
        f2()
        f1()
end

local function test2()
        test4()
        test3()
end
local function test1 ()
        test2()
end

local function test ()
        test1()
end


core.start(function()
        profiler.start()
        test()
        test()
        test()
        test()
        test()
        test()
        profiler.stop()

        print("-----------test1 run--------------------")

        local tbl = profiler.report()
        print(tbl)
        for k, v in pairs(tbl) do
                print("===========thread", k)
                dump_table("total_time-------", v.total_time)
                dump_table("call_time--------", v.call_times)
                --dump_table("db_info----------", v.debug_info)
        end
        print("------------test1 end--------------")

end)


