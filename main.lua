
--[[
local socket = require("socket")
local core = require("core")

local EVENT = {}

function EVENT.accept(fd)

end
function EVENT.close(fd)
        print("closexx")
end

function EVENT.data(fd, data)
        print("data", data)
end
core.start(function()
        
        local fd = socket.connect("127.0.0.1", 8989, EVENT)
        print("connect fd:", fd)
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        socket.write(fd, cmd)
end)
]]--


local t = {}

local function sep_res(res, ...)
        print (res)
        return ...
end

local function test1()
        return 1, 3, 4
end

local function test2()
        return sep_res(test1())
end

local b, c = test2()
print("fsdaf", b, c)


