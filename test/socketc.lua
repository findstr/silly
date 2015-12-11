local core = require "silly.core"
local socket = require "socket"

core.start(function()
        print("connect 8989 start")
        local fd = socket.connect("127.0.0.1", 8989)
        if fd == -1 then
                print("connect fail:", fd)
                return ;
        end
        
        print("connect fd = ", fd)
        socket.write(fd, "hello")
        local p = socket.read(fd, 2)
        p = socket.read(fd, 5)
        print("read 5 byte", p)
        p = socket.read(fd, 2)
        p = socket.readline(fd)
        print("read line ", p)
end)


