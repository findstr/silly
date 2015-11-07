local spacker = require "spacker"
local core = require "silly.core"
local socket = require "silly.socket"

local EVENT = {}

function EVENT.close(fd)
        print("close", fd)
end

function EVENT.data(fd, data)
        print("data", fd, data)
end

core.start(function()
        local fd = socket.connect("127.0.0.1", 8989, EVENT, spacker:create("line"))
        print("connect 8989", fd)
        socket.write(fd, "hello\n")
        local fd = socket.connect("127.0.0.1", 8988, EVENT, spacker:create("line"))
        print("connect 8988", fd)
        socket.write(fd, "how are you\n")
end)

