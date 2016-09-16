local core = require "silly.core"
local rpc = require "rpc"
local zproto = require "zproto"

local logic = zproto:parse [[
test 0xff {
        .name:string 1
        .age:integer 2
        .rand:string 3
}
]]

local server = rpc.createserver {
        addr = "@9999",
        proto = logic,
        accept = function(fd, addr)
                print("accept", fd, addr)
        end,

        close = function(fd, errno)
                print("close", fd, errno)
                core.exit()
        end,

        call = function(fd, cmd, msg)
                print("rpc recive", fd, cmd, msg.name, msg.age, msg.rand)
                core.sleep(100)
                return cmd, msg
        end
}

server:listen()

