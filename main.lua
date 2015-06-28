local server = require("server")
print("hello lua")

print("server", server)

while true do
        local fd, data = server.pull()
        if (data) then
                print("---fd:", fd);
                print("---data:", data);
                server.send(fd, "i have receive:" .. data)
        end
end
