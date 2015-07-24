local silly = require("silly")
local raw = require("rawpacket")
local packet = raw.create()

local event = {
        socket = {}
}

local socket = {
}

local SILLY_SOCKET_ACCEPT       = 2   --a new connetiong
local SILLY_SOCKET_CLOSE        = 3   --a close from client
local SILLY_SOCKET_CONNECT      = 4   --a async connect result
local SILLY_SOCKET_DATA         = 5   --a data packet(raw) from client


function socket.register(handler)
        event.accept = handler.accept
        event.close = handler.close
end

function socket.connect(ip, port)
        --not implement
end

function socket.read(fd, handler)
        event.socket[fd].recv = handler
end

function socket.write(fd, data)
        local p, s = raw.pack(data);
        silly.socket_send(fd, p, s);
end

function socket.kick(fd)
        --not implement
end


local function dispatch_event(fd, type)
        if type == SILLY_SOCKET_ACCEPT then
                event.socket[fd] = {}
                event.accept(fd);
        elseif type == SILLY_SOCKET_CLOSE then
                event.close(fd);
                event.socket[fd] = nil
        elseif type == SILLY_SOCKET_CONNECT then
                -- not implement
        end
end

local function dispatch_msg(fd, msg)
        assert(fd);
        assert(msg);
        if event.socket[fd].recv then
                event.socket[fd].recv(fd, msg)
        end
end

silly.socket_recv(function (msg)
        local fd, type, data
        fd, type = raw.push(packet, msg)
        dispatch_event(fd, type);

        fd, data = raw.pop(packet)
        while fd and data do
                dispatch_msg(fd, data)
                fd, data = raw.pop(packet)
        end
end)

return socket

