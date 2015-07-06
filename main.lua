local server = require("server")
--[[
server.recv(function (type, fd, data)
        print("--type:", type, "---fd:", fd, "---data:", data);
end)
]]--

function timer()
        
        print("----timer----------")
        server.addtimer(500, timer)
end

server.addtimer(500, timer)


