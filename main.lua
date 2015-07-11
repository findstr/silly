local socket= require("socket")
local timer = require("timer")

function timer_handler()
        print("heatbeat~")
        timer.add(1000, timer_handler)
end

--timer.add(1000, timer_handler)

--[[

local CMD = {}

function CMD.connect(fd)
        print("---new connect:", fd, "---")
        socket.read(fd, function(data)
                print("---fd", fd, "--data", data)
        end)
end

function CMD.disconnect(fd)
        print("----disconnect---", fd)
end

socket.register(CMD)

]]--

local fd = socket.connect("127.0.0.1", 6379)

socket.write(socket.CDATA, fd, "PING\r\n\r")
socket.read(fd, function (data) 
        print (data)
end, socket.CDATA)
