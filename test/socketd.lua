local socket = require "socket"

socket.listen("@9999", function(fd, addr)
        print(fd, "from", addr)
        while true do
                local n = socket.readline(fd, "3")
                print(n)
                if not n then
                        break
                end
        end
end)

