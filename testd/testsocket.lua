local socket = require "silly.socket"
local core = require "silly.core"
local spacker = require("spacker")

--connect
local CONN = {}

function CONN.accept(fd)
        print("accept, because the socket is initactive, so it never be called")
end
function CONN.close(fd)
        print("closexx")
end

function CONN.data(fd, data)
        print("data", #data, data)
        socket.close(fd)
end

core.start(function()
        local fd = socket.connect("127.0.0.1", 6379, CONN, spacker:create("linepacket"))
        print("connect fd:", fd)
        local cmd = "*1\r\n$4\r\nPING\r\n"
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
        print("test recv", fd, data)
        socket.write(fd, "+PONG\r\n")
end

socket.service(SERVICE, spacker:create("binpacket"))

