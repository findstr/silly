local socket = require("socket")
local timer = require("timer")
local core = require("core")

local EVENT = {}

function EVENT.accept(fd)
        print("---accept:", fd)
        socket.read(fd, function (fd, data)
                print("--recv", fd, "--data", data, "--workid", core.workid())
                socket.write(fd, data)
        end)
end

function EVENT.close(fd)
        print("---close:", fd)
end


socket.register(EVENT)


function t()
        print("heartbeat~", core.workid())
        timer.add(1000, t)
end

timer.add(1000, t)

