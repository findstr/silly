local silly = require("silly")
local raw = require("rawpacket")
local packet = raw.create()

local event = {
        handler = {},
        socket = {}
}

local socket = {
}

local SOCKET_READY              = 1     --socket is ready for processing the msg
local SOCKET_PROCESSING         = 2     --socket is process the msg
local SOCKET_CONNECTING         = 3     --socket is connecting
local SOCKET_CLOSE              = 4     --socket is close, but the resource has not already clear

local function unwire(fd, msg)
        if msg == nil then
                return nil
        end

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
        local handler = event.socket[fd].handler

        while true do
                event.socket[fd].status = SOCKET_PROCESSING
                msg = unwire(fd, p)
                func(fd, msg)

                -- check if the socket is close
                if event.socket[fd].isclose ~= 0 then
                        assert(event.socket[fd].isclose == 1)
                        handler["close"](fd)
                        silly.socket_close(fd)
                        event.socket[fd] = nil
                end

                p = table.remove(queue)
                if p == nil then --queue is empty
                        event.socket[fd].status = SOCKET_READY
                        func, fd, p= coroutine.yield()
                end
        end
end

local function init_new_socket(fd, co)
        if event.socket[fd] then
                print("double connect")
                return -1;
        end

        event.socket[fd] = {}
        event.socket[fd].status = SOCKET_READY
        event.socket[fd].queue = {}
        event.socket[fd].handler = event.handler
        event.socket[fd].isclose = 0    --0:runing, 1:close, 2:closed
        event.socket[fd].co = coroutine.create(socket_co)

        return 0
end

function socket.packet(fd, pack, unpack)
        event.socket[fd].pack = pack
        event.socket[fd].unpack = unpack
end


--function table
--accept(fd)
--close(fd)
--data(fd, packet)

function socket.service(handler)
        event.handler = handler
end

function socket.connect(ip, port, handler)
        local fd = silly.socket_connect(ip, port);
        if fd < 0 then
                return -1
        end

        init_new_socket(fd)
        --connect will be runned in core.start coroutine
        local co = event.socket[fd].co
        event.socket[fd].co = coroutine.running()
        
        event.socket[fd].status = SOCKET_CONNECTING
        coroutine.yield()
        event.socket[fd].status = SOCKET_READY
        if event.socket[fd].isclose ~= 0 then
                assert(event.socket[fd].isclose == 2)
                event.socket[fd] = nil
                return -1
        end

        -- now all the socket event can be process it in the socket coroutine
        event.socket[fd].co = co
        event.socket[fd].handler = handler

        return fd
end

function socket.close(fd)
        event.socket[fd].status = SOCKET_CLOSE
        silly.socket_shutdown(fd)
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

--socket event

local silly_message_handler = {}
--SILLY_SOCKET_ACCEPT       = 2   --a new connetiong
silly_message_handler[2] = function (fd)
        local err= init_new_socket(fd)
        if err == -1 then
                return
        end

        local co = event.socket[fd].co
        local handler = event.socket[fd].handler
        assert(handler)
        assert(event.socket[fd].status == SOCKET_READY)

        coroutine.resume(co, handler["accept"], fd)
end

--SILLY_SOCKET_CLOSE        = 3   --a close from client
silly_message_handler[3] = function (fd)
        local handler = event.socket[fd].handler
        local status = event.socket[fd].status
        local co = event.socket[fd].co
        if status ~= SOCKET_READY then
                event.socket[fd].isclose = 1
                return ;
        end
        coroutine.resume(co, handler["close"], fd);
        silly.socket_close(fd)
        event.socket[fd] = nil  --it will release the packet of queue, the coroutine
end

--SILLY_SOCKET_CLOSED       = 4   --a socket has been closed(all the resource has already free)
silly_message_handler[4] = function (fd)
        local handler = event.socket[fd].handler
        local status = event.socket[fd].status
        local co = event.socket[fd].co
        if status ~= SOCKET_READY then
                event.socket[fd].isclose = 2
                if (status == SOCKET_CONNECTING) then
                        coroutine.resume(co, handler["close"], fd);
                end

                return ;
        end
        coroutine.resume(co, handler["close"], fd);
        event.socket[fd] = nil  --it will release the packet of queue, the coroutine
end

--SILLY_SOCKET_SHUTDOWN     = 5                  //a socket shutdown has already processed
silly_message_handler[5] = function (fd)
        silly.socket_close(fd)
        event.socket[fd] = nil
end

--SILLY_SOCKET_CONNECTED    = 6   --a async connect result
silly_message_handler[6] = function (fd)
        local co = event.socket[fd].co
        local status = event.socket[fd].status
        assert(status == SOCKET_CONNECTING)
        coroutine.resume(co, fd)
end

--SILLY_SOCKET_DATA         = 7   --a data packet(raw) from client
silly_message_handler[7] = function (fd)
        assert(fd);
        local data
        local cmd

        assert(packet);
        fd, data = raw.pop(packet)
        while fd and data do
                if (event.socket[fd].status ~= SOCKET_CLOSE) then
                        local handler = event.socket[fd].handler
                        if handler["data"] then
                                local fun = handler["data"]
                                local co = event.socket[fd].co
                                local status = event.socket[fd].status

                                if status == SOCKET_READY then
                                        coroutine.resume(co, fun, fd, data)
                                else
                                        print("insert")
                                        local q = event.socket[fd].queue
                                        table.insert(q, 1, data)
                                end
                        end
                end

                fd, data = raw.pop(packet)
        end

        
end


silly.socket_recv(function (msg)
        local fd, type, data
        local cmd

        fd, type = raw.push(packet, msg)
        silly_message_handler[type](fd) --event handler
end)

return socket

