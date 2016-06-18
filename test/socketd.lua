local core = require "silly.core"
local socket = require "socket"

socket.listen("@9999", function(fd, addr)
        print(fd, "from", addr)
        while true do
                local n = socket.readline(fd)
                print(n)
                if not n then
                        break
                end
                socket.write(fd, n)
        end
        core.quit()
end)

