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

