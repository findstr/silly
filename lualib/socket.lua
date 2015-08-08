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

local SOCKET_READY              = 1     --socket is ready for processing the msg
local SOCKET_RUNNING            = 2     --socket is process the msg

local function unwire(fd, msg)
        local decode = event.socket[fd].unpack
        if decode then
                cmd = decode(msg)
        else
                cmd = msg
        end

        return cmd
end

local function socket_co(...)
        local func, fd, p = ...
        local msg
        local queue = event.socket[fd].queue
        while true do
                event.socket[fd].status = SOCKET_RUNNING
                msg = unwire(fd, p)
                print("socket_co", msg.cmd)
                func(fd, msg)

                p = table.remove(queue)
                if p == nil then --queue is empty
                        event.socket[fd].status = SOCKET_READY
                        func, fd, p= coroutine.yield()
                end
        end
end


function socket.register(handler)
        event.accept = handler.accept
        event.close = handler.close
end

function socket.connect(ip, port)
        --not implement
end

function socket.packet(fd, pack, unpack)
        event.socket[fd].pack = pack
        event.socket[fd].unpack = unpack
end

function socket.recv(fd, handler)
        event.socket[fd].recv = handler
end

function socket.write(fd, data)
        local ed;
        local pack = event.socket[fd].pack
        if pack then
                ed = pack(data)
        else
                ed = data
        end

        local p, s = raw.pack(ed);
        silly.socket_send(fd, p, s);
end

function socket.kick(fd)
        --not implement
end

local function accept(fd)
        event.socket[fd] = {}
        event.socket[fd].status = SOCKET_READY
        event.socket[fd].queue = {}
        event.socket[fd].co = coroutine.create(socket_co)
        event.accept(fd);
end

local function dispatch_event(fd, type)
        if type == SILLY_SOCKET_ACCEPT then
                accept(fd)
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
                local func = event.socket[fd].recv
                local co = event.socket[fd].co
                local status = event.socket[fd].status

                if status == SOCKET_READY then
                        coroutine.resume(co, func, fd, msg)
                else
                        print("insert")
                        local q = event.socket[fd].queue
                        table.insert(q, 1, msg)
                end
        end
end

silly.socket_recv(function (msg)
        local fd, type, data
        local cmd

        fd, type = raw.push(packet, msg)
        dispatch_event(fd, type);

        fd, data = raw.pop(packet)
        while fd and data do
                dispatch_msg(fd, data)
                fd, data = raw.pop(packet)
        end
end)

return socket

