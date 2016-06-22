local core = require "silly.core"
local env = require "silly.env"
local np = require "netpacket"
local zproto = require "zproto"

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

local function rpcunpack(fd, sc, data)
        if sc.unpack then
                data = sc.unpack(data)
        end
        local str = proto:unpack(data)
        local rpc, takes = proto:decode("rpc", str)
        if not rpc then
                print("rpcunpack parse the header fail")
                gate.close(fd)
                return
        end
        local res = sc.proto:decode(rpc.command, str:sub(takes + 1))
        if not res then
                print("rpc unpack fail", rpc.session, rpc.command)
                gate.close(fd)
                return
        end
        res.__rpc = rpc
        return res
end

local function rpcdispatch(fd, sc)
        if sc.type == "client" then
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
                        sc.rpc(fd, data.__rpc, data)
                        if socket_queue[fd] == nil then
                                return ;
                        end
                        data = pop_message(fd)
                end
        end
end

local function dataunpack(_, sc, data)
        local cooked
        if sc.unpack then
                cooked = sc.unpack(data)
        else
                cooked = data
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
        local f, data = np.pop(queue)
        --push it into socket queue, when process may yield
        while f do
                assert(f == fd)
                local cooked
                if sc.mode == "rpc" then
                        cooked = rpcunpack(fd, sc, data)
                else
                        cooked = dataunpack(fd, sc, data);
                end
                assert(cooked)
                push_message(f, cooked)
                f, data = np.pop(queue)
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
                assert(config.rpc, "the callback of rpc is 'rpc', not 'data'")
        end
        config.type = "client"
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
        if config.mode == "rpc" then
                assert(config.data == nil, "the callback of rpc is 'rpc', not 'data'")
        end
        config.type = "server"
        socket_config[portid] = config
        return true
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
                d = sc.pack(...)
        else
                d = ... 
        end
        if not d then
                return false
        end
        return core.write(fd, np.pack(d))
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
        assert(sc.type == "client", "only client can call rpcret")
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
        assert(sc.type == "server", "only server can call rpcret")
        return rpcsend(fd, sc, cookie.session, typ, dat)
end

return gate

