local core = require "silly.core"
local socket = require "socket"


local function udp_dispatch(data, addr) 
        print("client", data, addr)
end

core.start(function()
        local fd = socket.udp("192.168.2.118@9999", udp_dispatch)
        print("connect", fd)
        socket.udpwrite(fd, "world")
end)

