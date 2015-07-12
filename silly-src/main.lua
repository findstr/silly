local server = require("server")
print("hello lua")

server.recv(function (msg)
        print("lua.server.recv", msg, "xxx")
end)
