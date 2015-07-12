local server = require("server")

local socket_poll = {
        gate = {},
        conn = {},
}

local socket = {}

socket.GDATA = 0
socket.CDATA = 1
socket.HANDLE = 2

function socket.register(handler)
        socket.connect = handler.connect
        socket.disconnect = handler.disconnect
end

function socket.connect(ip, port)
        local fd = server.connect(ip, port)
        socket_poll.conn[fd] = {}
        return fd;
end

function socket.read(fd, handler, type)
        if (type == socket.GDATA) then
                socket_poll.gate[fd].recv = handler
        elseif (type == socket.CDATA) then
                socket_poll.conn[fd].recv = handler
        end
end

function socket.write(type, fd, data)
        return server.send(type, fd, data)
end

server.recv(function (type, fd, data)
        if fd > 0 then--connecting
                if type == socket.GDATA then
                        if socket_poll.gate[fd] == nil then
                                socket_poll.gate[fd] = {}
                                socket.connect(fd)
                        else
                                socket_poll.gate[fd].recv(fd, data)
                        end
                elseif type == socket.CDATA then
                                socket_poll.conn[fd].recv(data)                     
                end
        else -- disconnect
                assert(fd < 0)
                assert(socket_poll.gate[-fd].disconnect)
                socket_poll.gate[fd] = nil
        end
end)

return socket

