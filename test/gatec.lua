local core = require "silly.core"
local gate = require "gate"
local crypt = require "crypt"
local np = require "netpacket"

core.start(function()
        print("connect 8989 start")
        local fd = gate.connect {
                ip = "127.0.0.1",
                port = 9999,
                pack = function(data)
                        return crypt.aesencode("hello", data)
                end,
                unpack = function(data, sz)
                        data, sz = crypt.aesdecode("hello", data, sz)
                        return core.tostring(data, sz)
                end,

                close = function(fd, errno)
                        print("close", fd, errno)
                end,

                data = function(fd, msg)
                        print("recv data", fd, msg)
                        core.sleep(100)
                        print("port1 data finish")
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
                port = 9998,
                close = function(fd, errno)
                        print("close", fd, errno)
                end,

                data = function(fd, msg)
                        print("recv data", fd, msg)
                        core.sleep(100)
                        print("port1 data finish")
                end,
        }
        gate.send(fd, "connect 8988")
        print("connect 8988 finish")
        core.sleep(100);
        gate.close(fd)
        core.sleep(5000)
        core.quit()
end)


