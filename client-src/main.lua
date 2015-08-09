local io = require("io")
local socket = require("socket")

local fd = socket.connect("127.0.0.1", 8988);

print("connect fd:", fd)

local CMD = {}

local function pause()
        for line in io.stdin:lines() do
                break;
        end
end

function CMD.login()
        local a = 0
        local cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r"
        socket.send(fd, cmd)
        socket.send(fd, cmd)
        socket.send(fd, cmd)
        local res = socket.recv(fd)
        print(res)
        local res = socket.recv(fd)
        print(res)
        local res = socket.recv(fd)
        print(res)
end

function CMD.roomlist()
        local cmd = "{\"cmd\":\"room_list\", \"page_index\":\"1\"}\r\n\r"
        socket.send(fd, cmd)
        local res = socket.recv(fd)
        print(res)
end

function CMD.roomcreate()
        local cmd = "{\"cmd\":\"room_create\", \"uid\":\"1\"}\r\n\r"
        socket.send(fd, cmd)
        local res = socket.recv(fd)
        print(res)
end

for line in io.stdin:lines() do
        local handler = CMD[line]
        if (handler) then
                handler()
        end
end

socket.close(fd);

