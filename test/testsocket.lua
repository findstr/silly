local socket = require("socket")
local core = require("core")

--connect
local CONN = {}

function CONN.accept(fd)
        print("accept, because the socket is initactive, so it never be called")
end
function CONN.close(fd)
        print("closexx")
end

function CONN.data(fd, data)
        print("data", data)
        socket.close(fd)
end

core.start(function()
        
        local fd = socket.connect("127.0.0.1", 8989, CONN)
        print("connect fd:", fd)
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        socket.write(fd, cmd)
end)

--service
local SERVICE = {}

function SERVICE.accept(fd)
        print(fd, "service-come in")
end

function SERVICE.close(fd)
        print(fd, "service-leave")
end

function SERVICE.data(fd, data)
        print("service-data", data)
        socket.write(fd, "hello")
end

socket.service(SERVICE)

