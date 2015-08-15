local silly = require("silly")
local core = require("core")

local event = {
        handler = {},
        packer = nil,
}

local socket_pool = {}

local socket = {}

local SOCKET_READY              = 1     --socket is ready for processing the msg
local SOCKET_PROCESSING         = 2     --socket is process the msg
local SOCKET_CONNECTING         = 3     --socket is connecting
local SOCKET_CLOSE              = 4     --socket is close, but the resource has not already clear

local function unwire(fd, msg)
        if msg == nil then
                return nil
        end

        local decode = socket_pool[fd].unpack
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
        local queue = socket_pool[fd].queue
        local handler = socket_pool[fd].handler

        while true do
                socket_pool[fd].status = SOCKET_PROCESSING
                msg = unwire(fd, p)
                func(fd, msg)
                -- check if the socket is close
                if socket_pool[fd].isclose ~= 0 and socket_pool[fd] ~= SOCKET_CLOSE then
                        assert(socket_pool[fd].isclose == 1)
                        handler["close"](fd)
                end

                if socket_pool[fd].isclose ~= 0 then
                        silly.socket_close(fd)
                        socket_pool[fd] = nil
                        return ;
                elseif socket_pool[fd].status == SOCKET_CLOSE then
                        return ;
                end

                p = table.remove(queue)
                if p == nil then --queue is empty
                        socket_pool[fd].status = SOCKET_READY
                        func, fd, p= core.block()
                end
        end
end

local function init_new_socket(fd)
        if socket_pool[fd] then
                print("double connect")
                return -1;
        end

        socket_pool[fd] = {
                status = SOCKET_READY,
                queue = {},
                handler = event.handler,
                isclose = 0,            --0:runing, 1:close, 2:closed
                co = core.create(socket_co),
                packer = nil,
        }

        return 0
end

function socket.packet(fd, pack, unpack)
        socket_pool[fd].pack = pack
        socket_pool[fd].unpack = unpack
end


--function table
--accept(fd)
--close(fd)
--data(fd, packet)

function socket.service(handler, packer)
        assert(packer)
        event.handler = handler
        event.packer = packer
end

function socket.connect(ip, port, handler, packer)
        local fd = silly.socket_connect(ip, port);
        if fd < 0 then
                return -1
        end

        init_new_socket(fd)
        if packer then
                socket_pool[fd].packer = packer
        else
                socket_pool[fd].packer = event.packer 
        end

        --connect will be runned in core.start coroutine
        local co = socket_pool[fd].co
        socket_pool[fd].co = core.self()
        
        socket_pool[fd].status = SOCKET_CONNECTING

        core.block()

        socket_pool[fd].status = SOCKET_READY
        if socket_pool[fd].isclose ~= 0 then
                assert(socket_pool[fd].isclose == 2)
                socket_pool[fd] = nil
                return -1
        end

        -- now all the socket event can be process it in the socket coroutine
        socket_pool[fd].co = co
        socket_pool[fd].handler = handler

        return fd
end

function socket.close(fd)
        socket_pool[fd].status = SOCKET_CLOSE
        silly.socket_shutdown(fd)
end

function socket.write(fd, data)
        if (socket_pool[fd].isclose ~= 0) then -- client close the socket
                print("write the data to a close socket")
                return ;
        end

        local ed;
        local pack = socket_pool[fd].pack
        if pack then
                ed = pack(data)
        else
                ed = data
        end

        local p, s = socket_pool[fd].packer:pack(ed);
        silly.socket_send(fd, p, s);
end

--socket event

local silly_message_handler = {}
--SILLY_SOCKET_ACCEPT       = 2   --a new connetiong
silly_message_handler[2] = function (fd)
        local err = init_new_socket(fd)
        if err == -1 then
                return
        end

        socket_pool[fd].packer = event.packer:create()

        local co = socket_pool[fd].co
        local handler = socket_pool[fd].handler
        assert(handler)
        assert(socket_pool[fd].status == SOCKET_READY)

        core.run(co, handler["accept"], fd)
end

--SILLY_SOCKET_CLOSE        = 3   --a close from client
silly_message_handler[3] = function (fd)
        local handler = socket_pool[fd].handler
        local status = socket_pool[fd].status
        local co = socket_pool[fd].co
        if status == SOCKET_PROCESSING then
                socket_pool[fd].isclose = 1
                return ;
        elseif status == SOCKET_READY then 
                core.run(co, handler["close"], fd);
        end
        
        -- when status == SOCKET_CLOSE the server close the socket after the client
        silly.socket_close(fd)
        socket_pool[fd] = nil  --it will release the packet of queue, the coroutine
end

--SILLY_SOCKET_CLOSED       = 4   --a socket has been closed(all the resource has already free), now only for connect
silly_message_handler[4] = function (fd)
        local handler = socket_pool[fd].handler
        local status = socket_pool[fd].status
        local co = socket_pool[fd].co
        assert(status == SOCKET_CONNECTING)
        socket_pool[fd].isclose = 2
        core.run(co, handler["close"], fd);
        socket_pool[fd] = nil  --it will release the packet of queue, the coroutine
end

--SILLY_SOCKET_SHUTDOWN     = 5                  //a socket shutdown has already processed
silly_message_handler[5] = function (fd)
        silly.socket_close(fd)
        socket_pool[fd] = nil
end

--SILLY_SOCKET_CONNECTED    = 6   --a async connect result
silly_message_handler[6] = function (fd)
        local co = socket_pool[fd].co
        local status = socket_pool[fd].status
        assert(status == SOCKET_CONNECTING)
        core.run(co, fd)
end

--SILLY_SOCKET_DATA         = 7   --a data packet(raw) from client
silly_message_handler[7] = function (fd, data, size)
        assert(fd);

        local packer = socket_pool[fd].packer

        packer:push(fd, data, size)

        fd, data = packer:pop()
        while fd and data do
                if (socket_pool[fd].status ~= SOCKET_CLOSE) then
                        local handler = socket_pool[fd].handler
                        if handler["data"] then
                                local fun = handler["data"]
                                local co = socket_pool[fd].co
                                local status = socket_pool[fd].status

                                if status == SOCKET_READY then
                                        core.run(co, fun, fd, data)
                                elseif status == SOCKET_PROCESSING then
                                        print("insert")
                                        local q = socket_pool[fd].queue
                                        table.insert(q, 1, data)
                                end
                        end
                end

                fd, data = packer:pop()
        end
end


silly.socket_register(function (fd, type, ...)
        silly_message_handler[type](fd, ...) --event handler
end)

return socket

