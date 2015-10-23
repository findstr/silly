local spacker = require("spacker")
local core = require("core")
local socket = require("socket")

local EVENT_PORT1 = {}

function EVENT_PORT1.accept(fd)
        print("accept port1", fd)
end

function EVENT_PORT1.close(fd)
        print("close port1", fd)
end

function EVENT_PORT1.data(fd, data)
        print("data port1", fd, data)
end

local EVENT_PORT2 = {}

function EVENT_PORT2.accept(fd)
        print("accept port2", fd)
end

function EVENT_PORT2.close(fd)
        print("close port2", fd)
end

function EVENT_PORT2.data(fd, data)
        print("data port2", fd, data)
end



socket.listen("port1", EVENT_PORT1, spacker:create("line"))
socket.listen("port2", EVENT_PORT2, spacker:create("line"))


