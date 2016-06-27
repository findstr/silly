local core = require "silly.core"
local rpc = require "rpc"
local crypt = require "crypt"
local zproto = require "zproto"

local logic = zproto:parse [[
test 0xff {
        .name:string 1
        .age:integer 2
        .rand:string 3
}
]]

local function quit()
        core.sleep(10000)
        core.quit()
end

rpc.listen {
        addr = "@9999",
        proto = logic,
        pack = function(data)
                return crypt.aesencode("hello", data)
        end,
        unpack = function(data, sz)
                return crypt.aesdecode("hello", data, sz)
        end,
        accept = function(fd, addr)
                print("accept", fd, addr)
        end,

        close = function(fd, errno)
                print("close", fd, errno)
        end,

        data = function(fd, cookie, msg)
                print("rpc recive", msg.name, msg.age, msg.rand)
                rpc.ret(fd, cookie, "test", msg)
                print("port1 data finish")
                core.fork(quit)
        end
}

