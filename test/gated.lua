local core = require "silly.core"
local gate = require "gate"

gate.listen {
        port = "port1",
        accept = function(fd)
                print("accept", fd)
        end,

        close = function(fd)
                print("close", fd)
        end,

        data = function(fd, msg)
                print("data", fd, msg)
                gate.send(fd, msg)
                core.sleep(1000)
                gate.send(fd, msg .. "t\n")
                print("port1 data finish", core.running())
        end,
}

gate.listen {
        port = "port2",
        accept = function(fd)
                print("accept", fd)
        end,

        close = function(fd)
                print("close", fd)
        end,

        data = function(fd, msg)
                print("data", fd, msg)
                gate.send(fd, msg)
                core.sleep(100)
                print("port2 data finish", core.running())
        end,
}


