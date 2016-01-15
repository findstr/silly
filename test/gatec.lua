local core = require "silly.core"
local gate = require "gate"
local np = require "netpacket"

core.start(function()
        print("connect 8989 start")
        local fd = gate.connect {
                ip = "127.0.0.1",
                port = 8989,
                close = function(fd)
                        print("close", fd)
                end,

                data = function(fd, msg)
                        print("recv data", fd, msg)
                        core.sleep(100)
                        print("port1 data finish", core.running())
                end,
        }
        gate.send(fd, "connect 8989")
        core.sleep(100);
        print("connect 8989 finish")
        gate.close(fd)
end)

core.start(function()
        print("connect 8988 start")
        local fd = gate.connect {
                ip = "127.0.0.1",
                port = 8988,
                close = function(fd)
                        print("close", fd)
                end,

                data = function(fd, msg)
                        print("recv data", fd, msg)
                        core.sleep(100)
                        print("port1 data finish", core.running())
                end,
        }
        gate.send(fd, "connect 8988")
        print("connect 8988 finish")
        core.sleep(100);
        gate.close(fd)
end)


