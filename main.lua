local socket = require("socket")
local core = require("core")

--service
local SERVICE = {}

function SERVICE.accept(fd)
        print(fd, "service-come in")
end

function SERVICE.close(fd)
        print(fd, "service-leave")
end

function SERVICE.data(fd, data)
        print("service-data", data)
        socket.write(fd, "PONG")
end

socket.service(SERVICE)

