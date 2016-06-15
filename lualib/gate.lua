local core = require "silly.core"
local env = require "silly.env"
local np = require "netpacket"

local gate = {}

local queue = np.create()
local socket_config = {}
local socket_queue = {}

local function push_message(fd, data, sz)
        table.insert(socket_queue[fd], 1, data)
        table.insert(socket_queue[fd], 1, sz)
end

local function pop_message(fd)
        local d = table.remove(socket_queue[fd])
        local s = table.remove(socket_queue[fd])
        return d, s
end

local function clear_socket(fd)
        while true do
                local d, _ = pop_message(fd)
                if not d then
                        return
                end
                core.drop(d)
        end
end

local function dispatch_socket(fd)
        local empty = #socket_queue[fd] == 0
        local f, d, s = np.pop(queue)
        --push it into socket queue, when process may yield
        while f do
                assert(f == fd)
                push_message(f, d, s)
                f, d, s = np.pop(queue)
        end

        --if socket_queue[fd] is not empty, it blocked by last message process, directly return
        if empty == false or (not socket_config[fd]) then
                return
        end
        local data, sz = pop_message(fd)
        while data do
                local unpack = socket_config[fd].unpack
                if unpack then
                        socket_config[fd].data(fd, unpack(data, sz))
                        core.drop(data)
                else
                        socket_config[fd].data(fd, np.tostring(data, sz))
                end
                if socket_queue[fd] == nil then         --already closed
                        return ;
                end
                data, sz = pop_message(fd)
        end
end

local EVENT = {}

function EVENT.accept(fd, portid, addr)
        local lc = socket_config[portid];
        socket_config[fd] = lc
        socket_queue[fd] = {}
        local ok = pcall(lc.accept, fd, addr)
        if not ok then
                gate.close(fd)
        end
end

function EVENT.close(fd, errno)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        clear_socket(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        pcall(assert(sc).close, fd, errno)
end

function EVENT.data(fd)
        local ok, err = pcall(dispatch_socket, fd)
        if not ok then
                print("gate dispatch socket error:", err)
                gate.close(fd)
        end
end

function EVENT.connected(fd)
        print("never come gate.EVENT.connected")
end

local function dispatch_message(q, type, ...)
        queue = q
        assert(EVENT[type])(...)
end

local function gate_dispatch(type, fd, message, ...)
        --have already closed
        if type ~= "accept" and socket_config[fd] == nil then                  
                assert(socket_queue[fd] == nil)
                core.drop(message)
                return ;
        end

        dispatch_message(np.message(queue, message), type, fd, ...)
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
        local portid = core.listen(config.port, gate_dispatch)
        if not portid then
                return false
        end
        socket_config[portid] = config
        return true
end

function gate.close(fd)
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        clear_socket(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        np.clear(queue, fd)
        core.close(fd)
end

function gate.send(fd, ...)
        local d
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        if sc.pack then
                d = sc.pack(...)
        else
                d = ... 
        end
        if not d then
                return false
        end
        return core.write(fd, np.pack(d))
end


return gate

