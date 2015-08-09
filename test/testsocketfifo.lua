local socketfifo = require("socketfifo")
local core = require("core")

local fifo = socketfifo:create{
                                ip = '127.0.0.1', 
                                port = 8989
                        }


core.start(function ()
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        print("1 - connect before")
        local res = fifo:connect()
        print("1 - connect after", res)
        res = fifo:request(cmd, true)
        print("1 - ", res)
end)

core.start(function ()
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        print("2 - connect before")
        local res = fifo:connect()
        print("2 - connect after", res)
        res = fifo:request(cmd, true)
        print("2 - ", res)
end)


