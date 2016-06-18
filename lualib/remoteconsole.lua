local core = require "silly.core"
local socket = require "socket"

local CMD = {}

function CMD.exit(fd, line)
end

function CMD.memstatus(fd, line)
        local sz = core.memstatus()
        socket.write(fd, "Memory Used:" .. sz .. "\n")
end


socket.listen("127.0.0.1@2323", function(fd, addr)
        print(fd, "from", addr)
        while true do
                local res = socket.readline(fd)
                if not res then
                        break
                end
                local cmd = res:match("[%g]+")
                if not cmd then
                        print("incorrect format:", res)
                elseif cmd == "quit" then
                        socket.close(fd)
                        break
                else
                        local func = CMD[cmd];
                        if not func then
                                print("unsupport command:" .. cmd)
                        else
                                func(fd, res)
                        end
                end
        end
        print(addr, "disconnected")
end)

