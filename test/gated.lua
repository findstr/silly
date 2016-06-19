local core = require "silly.core"
local gate = require "gate"
local np = require "netpacket"

gate.listen {
        port = "@9999",
        unpack = function(data, sz)
                return core.tostring(data, sz)
        end,
        accept = function(fd, addr)
                print("accept", fd, addr)
        end,

        close = function(fd, errno)
                print("close", fd, errno)
                core.sleep(5000)
                core.quit()
        end,

        data = function(fd, msg)
                print("data", fd, msg)
                gate.send(fd, msg)
                core.sleep(1000)
                gate.send(fd, msg .. "t\n")
                print("port1 data finish")
        end,
}

gate.listen {
        port = "@9998",
        accept = function(fd, addr)
                print("accept", fd, addr)
        end,

        close = function(fd, errno)
                print("close", fd, errno)
        end,
        data = function(fd, msg)
                print("data", fd, msg)
                gate.send(fd, msg)
                core.sleep(100)
                print("port2 data finish")
        end,
}

