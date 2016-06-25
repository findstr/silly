local core = require "silly.core"
local env = require "silly.env"
local np = require "netpacket"
local zproto = require "zproto"

--[[
gate can work on two mode

1. normal mode
gate.listen {
        port = ip@port:backlog 
        pack = function(...)
                @...
                        is the all param
                        which passed to gate.send
                        exclude fd
                @return 
                        return string or (lightuserdata, size)
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

2. rpc mode
gate.listen {
        port = ip@port:backlog 
        mode = "rpc",
        proto = the proto instance
        pack = function(data)
                @data 
                        binary string
                @return 
                        return string or (lightuserdata, size)
        end,
        unpack = function(data, sz)
                @data 
                        lightuserdata
                        need not free the data
                        it will be freed by gate.lua
                @sz 
                        size of lightuserdata
                @return
                        return string or lightuserdata
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
        data = function(fd, data, rpc)
                @fd 
                        socket fd
                @data 
                        a table parsed from zproto
                @rpc
                        rpc header defined in gate.lua
                        
                @return
                        no return
        end

]]--

local proto = zproto:parse [[
rpc {
        .session:integer 1
        .command:integer 2
}
]]

local gate = {}
local rpc_session = {}
local queue = np.create()
local socket_config = {}
local socket_queue = {}
local socket_rpc = {}

local function close_wakeup(fd)
        local rpc = socket_rpc[fd]
        for k, v in pairs(rpc) do
                core.wakeup(v, nil)
                rpc[k] = nil
        end
end

local function push_message(fd, data)
        table.insert(socket_queue[fd], 1, data)
end

local function pop_message(fd)
        local d = table.remove(socket_queue[fd])
        return d
end

local function rpcunpack(fd, sc, data, sz)
        if sc.unpack then
                data, sz = sc.unpack(data, sz)
        end
        local str = proto:unpack(data, sz)
        local rpc, takes = proto:decode("rpc", str)
        if not rpc then
                print("rpcunpack parse the header fail")
                gate.forceclose(fd)
                return
        end
        local res = sc.proto:decode(rpc.command, str:sub(takes + 1))
        if not res then
                print("rpc unpack fail", rpc.session, rpc.command)
                gate.forceclose(fd)
                return
        end
        res.__rpc = rpc
        return res
end

local function rpcdispatch(fd, sc)
        if sc.__type == "client" then
                local data = pop_message(fd)
                while data do
                        local rpc = data.__rpc;
                        local co = socket_rpc[fd][rpc.session]
                        if not co then
                                print("rpc unpack try a nonexit session", rpc.session)
                                return
                        end
                        socket_rpc[fd][rpc.session] = nil
                        core.wakeup(co, data)
                        data = pop_message(fd)
                end
        else
                local data = pop_message(fd)
                while data do
                        --it maybe yield at this
                        sc.data(fd, data, data.__rpc)
                        if socket_queue[fd] == nil then
                                return ;
                        end
                        data = pop_message(fd)
                end
        end
end

local function dataunpack(_, sc, data, sz)
        local cooked
        if sc.unpack then
                cooked = sc.unpack(data, sz)
        else
                cooked = core.tostring(data, sz)
        end
        return cooked
end

local function datadispatch(fd, sc)
        local data = pop_message(fd)
        while data do
                --it maybe yield at this
                sc.data(fd, data)       
                if socket_queue[fd] == nil then         --already closed
                        return ;
                end
                data = pop_message(fd)
        end
end

local function dispatch_socket(fd)
        local sc = socket_config[fd]
        local empty = #socket_queue[fd] == 0
        local f, d, sz = np.pop(queue)
        --push it into socket queue, when process may yield
        while f do
                assert(f == fd)
                local ok, cooked
                if sc.mode == "rpc" then
                        ok, cooked = pcall(rpcunpack, fd, sc, d, sz)
                else
                        ok, cooked = pcall(dataunpack, fd, sc, d, sz);
                end
                np.drop(d)
                if not ok then
                        print("unpack crash", cooked)
                        gate.forceclose(fd)
                        return
                end
                assert(cooked)
                push_message(f, cooked)
                f, d, sz= np.pop(queue)
        end

        --if socket_queue[fd] is not empty
        --it blocked by last message process
        --directly return
        assert(socket_config[fd])
        if empty == false  then
                return
        end

        --dispatch message
        if sc.mode == "rpc" then
                rpcdispatch(fd, sc)
        else
                datadispatch(fd, sc)
        end
end

local EVENT = {}

function EVENT.accept(fd, portid, addr)
        local lc = socket_config[portid];
        socket_config[fd] = lc
        socket_queue[fd] = {}
        socket_rpc[fd] = {}
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
        close_wakeup(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        socket_rpc[fd] = nil
        pcall(assert(sc).close, fd, errno)

end

function EVENT.data(fd)
        local ok, err = pcall(dispatch_socket, fd)
        if not ok then
                print("gate dispatch socket error:", err)
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
        local fd = core.connect(config.ip, config.port, gate_dispatch)
        if fd < 0 then
                return -1
        end
        if config.mode == "rpc" then
                assert(config.proto)
                assert(config.data == nil,
                "rpc mode need no 'data' func, result will be ret by rpccall")
        end
        config.__type = "client"
        -- now all the socket event can be process it in the socket coroutine
        socket_config[fd] = config
        socket_queue[fd] = {}
        socket_rpc[fd] = {}
        return fd
end

function gate.listen(config)
        assert(config)
        local portid = core.listen(config.port, gate_dispatch)
        if not portid then
                return false
        end
        config.__type = "server"
        socket_config[portid] = config
        return true
end

function gate.forceclose(fd)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        close_wakeup(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        socket_rpc[fd] = nil
        np.clear(queue, fd)
        core.close(fd)
        pcall(assert(sc).close, fd, errno)
end

function gate.close(fd)
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        close_wakeup(fd)
        socket_config[fd] = nil
        socket_queue[fd] = nil
        socket_rpc[fd] = nil
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
                d, sz = sc.pack(...)
        else
                d, sz = ... 
        end
        if not d then
                return false
        end
        return core.write(fd, np.pack(d, sz))
end

local function rpcsend(fd, sc, session, typ, dat)
        local cmd
        assert(type(dat) == "table")
        assert(sc.mode == "rpc")
        assert(sc.proto)
        if type(typ) == "string" then
                cmd = sc.proto:querytag(typ)
        else
                assert(type(typ) == "integer")
                cmd = typ
        end
        local rpc = {
                session = session;
                command = cmd,
        }
        local head = proto:encode("rpc", rpc)
        local body = sc.proto:encode(typ, dat)
        head = head .. body
        head = proto:pack(head)
        if sc.pack then
                head = sc.pack(head)
        end
        local err = core.write(fd, np.pack(head))
        if not err then
                return false, "send error"
        end
        return true
end

function gate.rpccall(fd, typ, dat, timeout)
        local sc = socket_config[fd]
        if sc == nil then
                return false, "socket error"
        end
        assert(sc.__type == "client", "only client can call rpcret")
        local session = core.genid();
        local ok, err = rpcsend(fd, sc, session, typ, dat)
        if not ok then
                return ok, err
        end
        assert(socket_rpc[fd][session] == nil)
        socket_rpc[fd][session] = core.running()
        return core.wait()
end

function gate.rpcret(fd, cookie, typ, dat)
        local sc = socket_config[fd]
        if sc == nil then
                return false, "socket error"
        end
        assert(sc.__type == "server", "only server can call rpcret")
        return rpcsend(fd, sc, cookie.session, typ, dat)
end

return gate

