local core = require "silly.core"
local np = require "netpacket"

--[[
gate.listen {
        addr = ip@port:backlog 
        pack = function(...)
                @...
                        is the all param
                        which passed to gate.send
                        exclude fd
                @return 
                        return string or (lightuserdata, sz)
        end,
        unpack = function(data, sz)
                @data 
                        lightuserdata
                        need not free the data
                        it will be freed by gate.lua
                @sz 
                        size of lightuserdata
                @return
                        return string or table
        end,
        accept = function(fd, addr)
                @fd 
                        new socket fd come int
                @addr 
                        ip:port of new socket 
                @return
                        no return
        end,
        close = function(fd, errno)
                @fd 
                        the fd which closed by client
                        or occurs errors
                @errno 
                        close errno, if normal is 0
                @return 
                        no return
        end,
        data = function(fd, data)
                @fd 
                        socket fd
                @data 
                        a complete packetdata(string or table)
                        if define 'pack' function
                        the 'data' is the value which 'pack' return
                @return
                        no return
        end
}
]]--

local gate = {}
local queue = np.create()
local socket_config = {}
local socket_queue = {}

local function push_message(fd, data)
        table.insert(socket_queue[fd], 1, data)
end

local function pop_message(fd)
        local d = table.remove(socket_queue[fd])
        return d
end

local EVENT = {}

local function unpack(sc, d, sz)
        if sc.unpack then
                local ok, cooked = core.pcall(sc.unpack, d, sz)
                if not ok then
                        print("[gate] unpack", cooked)
                        return nil
                end
                return cooked
        else
                return core.tostring(d, sz)
        end
end

local function dispatch_socket(fd)
        local sc = socket_config[fd]
        local f, d, sz = np.pop(queue)
        while f do
                assert(f == fd)
                local cooked = unpack(sc, d, sz)
                np.drop(d);
                if not cooked then
                        gate.forceclose(fd)
                        return
                end
                push_message(f, cooked)
                f, d, sz= np.pop(queue)
        end
        --has some coroutine handle this socket
        --so return
        if sc.__running then
                return
        end
        sc.__running = true
        local data = pop_message(fd)
        while data do
                --it maybe yield at this
                sc.data(fd, data)
                --sc.data may close it
                if not socket_config[fd] then
                        return
                end
                data = pop_message(fd)
        end
        sc.__running = nil
        if sc.__close then
                EVENT.close(fd, 0)
        end
end


local function newsocket(fd, config)
        socket_config[fd] = config
        socket_queue[fd] = {}
end

local function delsocket(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        np.clear(queue, fd)
end

function EVENT.accept(fd, portid, addr)
        local lc = socket_config[portid];
        newsocket(fd, lc)
        local ok, err = core.pcall(lc.accept, fd, addr)
        if not ok then
                print("[gate] EVENT.accept", err)
                gate.close(fd)
        end
end

function EVENT.close(fd, errno)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        if sc.__running then
                sc.__close = true
                return
        end
        delsocket(fd)
        local ok, err = core.pcall(assert(sc).close, fd, errno)
        if not ok then
                print("[gate] EVENT.close", err)
        end
end

function EVENT.data(fd)
        local ok, err = core.pcall(dispatch_socket, fd)
        if not ok then
                print("[gate] dispatch socket", err)
                gate.forceclose(fd)
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
                return ;
        end

        dispatch_message(np.message(queue, message), type, fd, ...)
end

function gate.connect(config)
        local fd = core.connect(config.addr, gate_dispatch)
        if fd then
                -- now all the socket event can be process it in the socket coroutine
                newsocket(fd, config)
        end
        return fd
end

function gate.listen(config)
        assert(config)
        local portid = core.listen(config.addr, gate_dispatch)
        if portid then
                socket_config[portid] = config
        end
        return portid
end

function gate.forceclose(fd)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        delsocket(fd)
        core.close(fd)
        local ok, err = core.pcall(assert(sc).close, fd, errno)
        if not ok then
                print("[gate] forceclose", err)
        end
end

function gate.close(fd)
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        delsocket(fd)
        core.close(fd)
end

function gate.send(fd, ...)
        local d
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        if sc.pack then
                d, sz = sc.pack(...)
        else
                d, sz = ... 
        end
        if not d then
                return false
        end
        return core.write(fd, np.pack(d, sz))
end

return gate

