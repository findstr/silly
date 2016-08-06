local core = require "silly.core"
local socket = require "socket"

local fd

local function udp_dispatch(data, addr) 
        print(data, #addr)
        core.sleep(10000)
        print("wakeup")
        socket.udpwrite(fd, "helloxxx", addr)
end

core.start(function()
        fd = socket.bind("@9999", udp_dispatch)
        assert(fd)
end)

