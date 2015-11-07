local socketfifo = require("socketfifo")
local core = require "silly.core"
local spacker = require("spacker")

local fifo = socketfifo:create{
                                ip = '127.0.0.1', 
                                port = 8989,
                                packer = spacker:create("binpacket")
                        }

local function read_ack(sfifo)
        local res = sfifo:read(3)
        print("read", res)

end

core.start(function ()
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        print("1 - connect before")
        local res = fifo:connect()
        print("1 - connect after", res, fifo)
        res = fifo:request(cmd, read_ack)
        print("1 - ", res)
        fifo:close()
        print("1 - ", fifo.status)
end)

core.start(function ()
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        print("2 - connect before")
        local res = fifo:connect()
        print("2 - connect after", res, fifo)
        res = fifo:request(cmd, read_ack)
        print("2 - ", res)
        fifo:close()
        print("2 - ", fifo.status)
end)


