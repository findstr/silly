local server = require("server")

local socket_poll = {}

local socket = {}

socket.GDATA = 0
socket.CDATA = 1
socket.HANDLE = 2

function socket.register(handler)
        socket.connect = handler.connect
        socket.disconnect = handler.disconnect
end

function socket.read(fd, handler)
        socket_poll[fd].recv = handler
end

function socket.write(fd, data)
        return server.send(fd, data)
end

server.recv(function (type, fd, data)
        if fd > 0 then--connecting
                if type == socket.GDATA then
                        if socket_poll[fd] == nil then
                                socket_poll[fd] = {}
                                socket.connect(fd)
                        else
                                socket_poll[fd].recv(data)
                        end
                elseif type == socket.CDATA then

                end
        else -- disconnect
                assert(fd < 0)
                assert(socket_poll[-fd].disconnect)
                socket_poll[-fd].disconnect(fd)
                socket_poll[-fd] = nil
        end
end)

return socket

