local core = require "silly.core"
local env = require "silly.env"
local np = require "netpacket"
local zproto = require "zproto"

--[[
rpc.listen {
        addr = ip@port:backlog 
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
                        it will be freed by rpc.lua
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
        data = function(fd, rpc, data)
                @fd 
                        socket fd
                @data 
                        a table parsed from zproto
                @rpc
                        rpc header defined in rpc.lua
                        
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

local rpc = {}
local queue = np.create()
local socket_config = {}
local socket_rpc = {}

local function close_wakeup(fd)
        local rpc = socket_rpc[fd]
        for k, v in pairs(rpc) do
                core.wakeup(v, nil)
                rpc[k] = nil
        end
end

local function forceclose(fd)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        rpc.close(fd)
        local ok, err = core.pcall(assert(sc).close, fd, errno)
        if not ok then
                print("[rpc] forceclose", err)
        end
end

local function dispatchclient(fd, sc, rpc, body)
        local co = socket_rpc[fd][rpc.session]
        if not co then
                print("[rpc] try to wakeup a nonexit session", rpc.session)
                return
        end
        socket_rpc[fd][rpc.session] = nil
        core.wakeup(co, body)
end

local function dispatchserver(fd, sc, rpc, body)
        sc.data(fd, rpc, body)
end

local function dispatch_socket(fd)
        local sc = socket_config[fd]
        local f, d, s = np.pop(queue)
        while f do
                if sc.unpack then
                        ok, data, sz = core.pcall(sc.unpack, d, s)
                        if not ok then
                                print("[rpc] call socketconfig.unpack fail", data)
                                np.drop(d, s)
                                forceclose(fd)
                                return 
                        end
                end
                local str = proto:unpack(data, sz)
                np.drop(d, s)
                local rpc, takes = proto:decode("rpc", str)
                if not rpc then
                        print("[rpc] parse the header fail")
                        forceclose(fd)
                        return
                end
                local body = sc.proto:decode(rpc.command, str:sub(takes + 1))
                if not body then
                        print("[rpc] parse body fail", rpc.session, rpc.command)
                        forceclose(fd)
                        return
                end
                assert(sc.__dispatch)(fd, sc, rpc, body)
                f, d, s= np.pop(queue)
        end
end

local EVENT = {}

function EVENT.accept(fd, portid, addr)
        local lc = socket_config[portid];
        socket_config[fd] = lc
        socket_rpc[fd] = {}
        local ok = core.pcall(lc.accept, fd, addr)
        if not ok then
                forceclose(fd)
        end
end

function EVENT.close(fd, errno)
        local sc = socket_config[fd]
        if sc == nil then       --have already closed
                return ;
        end
        close_wakeup(fd)
        socket_config[fd] = nil
        socket_rpc[fd] = nil
        local ok, err = core.pcall(assert(sc).close, fd, errno)
        if not ok then
                print("[rpc] EVENT.close", ok)
        end
end

function EVENT.data(fd)
        local ok, err = core.pcall(dispatch_socket, fd)
        if not ok then
                print("[rpc] dispatch socket error:", err)
                forceclose(fd)
        end
end

local function dispatch_message(q, type, ...)
        queue = q
        assert(EVENT[type])(...)
end

local function rpc_dispatch(type, fd, message, ...)
        --have already closed
        if type ~= "accept" and socket_config[fd] == nil then
                assert(socket_queue[fd] == nil)
                return ;
        end
        dispatch_message(np.message(queue, message), type, fd, ...)
end

function rpc.connect(config)
        local fd = core.connect(config.addr, rpc_dispatch)
        if not fd then
                return fd
        end
        assert(config.proto)
        assert(config.data == nil,
                "rpc client need no 'data' func, result will be ret by rpccall")
        config.__dispatch = dispatchclient
        -- now all the socket event can be process it in the socket coroutine
        socket_config[fd] = config
        socket_rpc[fd] = {}
        return fd
end

function rpc.listen(config)
        assert(config)
        local portid = core.listen(config.addr, rpc_dispatch)
        if not portid then
                return false
        end
        config.__dispatch = dispatchserver
        socket_config[portid] = config
        return true
end

function rpc.close(fd)
        local sc = socket_config[fd]
        if sc == nil then
                return false
        end
        close_wakeup(fd)
        socket_config[fd] = nil
        socket_rpc[fd] = nil
        np.clear(queue, fd)
        core.close(fd)
end

local function rpcsend(fd, sc, session, typ, dat)
        local cmd
        assert(type(dat) == "table")
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

function rpc.call(fd, typ, dat)
        local sc = socket_config[fd]
        if sc == nil then
                return false, "socket error"
        end
        local session = core.genid();
        local ok, err = rpcsend(fd, sc, session, typ, dat)
        if not ok then
                return ok, err
        end
        assert(socket_rpc[fd][session] == nil)
        socket_rpc[fd][session] = core.running()
        return core.wait()
end

function rpc.ret(fd, cookie, typ, dat)
        local sc = socket_config[fd]
        if sc == nil then
                return false, "socket error"
        end
        return rpcsend(fd, sc, cookie.session, typ, dat)
end

return rpc

