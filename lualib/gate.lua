local core = require "silly.core"
local env = require "silly.env"
local np = require "netpacket"

local gate = {}

local queue = np.create()
local listen_config = {}
local socket_config = {}
local socket_queue = {}

local function dispatch_socket(fd)
        local empty = #socket_queue[fd] == 0
        local f, d, s = np.pop(queue)
        --push it into socket queue, when process may yield
        while f do
                assert(f == fd)
                local m
                local unpack = socket_config[fd].unpack
                if unpack then
                        m = unpack(d, s)
                        np.drop(d);
                else
                        m = np.tostring(d, s)
                end
                table.insert(socket_queue[fd], 1, m)
                f, d, s = np.pop(queue)
        end

        --if socket_queue[fd] is not empty, it blocked by last message process, directly return
        if empty == false then
                return
        end

        local m = table.remove(socket_queue[fd])
        while m do
                socket_config[fd].data(fd, m)
                if socket_queue[fd] == nil then         --already closed
                        return ;
                end
                m = table.remove(socket_queue[fd])
        end
end

local EVENT = {}

function EVENT.accept(fd, portid)
        local lc = listen_config[portid];
        socket_config[fd] = lc
        socket_queue[fd] = {}
        lc.accept(fd)
end

function EVENT.close(fd)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        socket_config[fd] = nil
        socket_queue[fd] = nil
        assert(sc).close(fd)
end

function EVENT.data(fd)
        dispatch_socket(fd)
end

function EVENT.connected(fd)
        print("never come gate.EVENT.connected")
end

local function dispatch_message(q, type, ...)
        queue = q
        assert(EVENT[type])(...)
end

local function gate_dispatch(type, fd, portid, message) 
        --have already closed
        if type ~= "accept" and socket_config[fd] == nil then                  
                assert(socket_queue[fd] == nil)
                core.drop(message)
                return ;
        end

        dispatch_message(np.message(queue, message), type, fd, portid)
end

function gate.connect(config)
        local fd = core.connect(config.ip, config.port, gate_dispatch)
        if fd < 0 then
                return -1
        end
        -- now all the socket event can be process it in the socket coroutine
        socket_config[fd] = config
        socket_queue[fd] = {}
        return fd
end

function gate.listen(config)
        assert(config)
        local portid = env.get("listen." .. config.port)
        if portid == nil then
                print("invald port name")
                return false
        end
        portid = tonumber(portid)
        listen_config[portid] = config
        core.listen(config.port, gate_dispatch)
        return true
end

function gate.close(fd)
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        socket_config[fd] = nil
        socket_queue[fd] = nil
        np.clear(queue, fd)
        core.close(fd)
end

function gate.send(fd, data)
        local d
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        if sc.pack then
                d = sc.pack(data)
        else
                d = data
        end
        core.write(fd, np.pack(d))
end


return gate

