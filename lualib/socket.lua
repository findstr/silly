local silly = require("silly")
local core = require("core")

local socket_ports = __socket_ports

local event_handler = {}
local event_packer = {}

local socket_pool = {}
local coroutine_pool = {}
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
                        coroutine_pool[socket_pool[fd].co] = nil
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

local function init_new_socket(fd, handler, packer)
        if socket_pool[fd] then
                print("double connect")
                return -1;
        end

        socket_pool[fd] = {
                status = SOCKET_READY,
                queue = {},
                handler = handler,
                packer = packer,
                isclose = 0,            --0:runing, 1:close, 2:closed
                co = core.create(socket_co),
        }

        coroutine_pool[socket_pool[fd].co] = fd

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

function socket.listen(port_name, handler, packer)
        assert(handler)
        assert(packer)

        event_handler[port_name] = handler
        event_packer[port_name] = packer
end

function socket.connect(ip, port, handler, packer)
        assert(packer)
        assert(handler)

        local fd = silly.socket_connect(ip, port);
        if fd < 0 then
                return -1
        end

        init_new_socket(fd, handler, packer)

        --connect will be runned in core.start coroutine
        local co = socket_pool[fd].co
        socket_pool[fd].co = core.self()
        
        socket_pool[fd].status = SOCKET_CONNECTING

        core.block()

        socket_pool[fd].status = SOCKET_READY
        if socket_pool[fd].isclose ~= 0 then
                assert(socket_pool[fd].isclose == 2)
                coroutine_pool[co] = nil
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

function socket.wakeup(co, ...)
        local res = core.run(co, ...)
        if res == false then    --run occurs error
                local fd = coroutine_pool[co]
                local handler = socket_pool[fd].handler
                --when run to here, the coroutine of this socket has already been dead
                --so run it at a new coroutine
                core.start(handler["close"], fd)
                socket.close(fd);
        end
end

--socket event

local silly_message_handler = {}
--SILLY_SOCKET_ACCEPT       = 2   --a new connetiong
silly_message_handler[2] = function (fd, port)
        local port_name = socket_ports[port]
        assert(port_name)
        local handler = event_handler[port_name]
        local packer = event_packer[port_name]

        local err = init_new_socket(fd, handler, packer)
        if err == -1 then
                print("accept init_new_socket error")
                return
        end

        if (handler == nil or packer == nil) then
                print("accept a socket from unlisten port")
                socket.close(fd)
                return
        end

        socket_pool[fd].packer = packer:create()

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
        coroutine_pool[co] = nil
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
        local co = socket_pool[fd].co
        coroutine_pool[co] = nil
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
silly_message_handler[7] = function (fd, port, data, size)
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
                                        socket.wakeup(co, fun, fd, data)
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


silly.socket_register(function (fd, port, type, ...)
        silly_message_handler[type](fd, port, ...) --event handler
end)

return socket

