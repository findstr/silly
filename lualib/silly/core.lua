local silly = require "silly"
local timer = require "silly.timer"
local env = require "silly.env"

local core = {}

function core.workid()
        return silly.workid()
end

--coroutine pool
local coroutine_cap = 0
local coroutine_pool = {}

local function coroutine_create(f)
        local co = table.remove(coroutine_pool)
        if co then
                coroutine.resume(co, f)
                return co
        end

        local function coroutine_call()
                while true do
                        local func = coroutine.yield()
                        local ok, err = pcall(func, coroutine.yield())
                        if ok == false then
                                print(err)
                                print(debug.traceback())
                        end
                        if coroutine_cap <= 100 then
                                local co = coroutine.running()
                                table.insert(coroutine_pool, co)
                        else
                                coroutine_cap = coroutine_cap - 1
                                return ;
                        end
                end
        end

        co = coroutine.create(coroutine_call)
        coroutine.resume(co)    --wakeup the new coroutine
        coroutine.resume(co, f)       --pass the function handler
        coroutine_cap = coroutine_cap + 1
        return co
end

core.create = coroutine_create
core.yield = coroutine.yield
core.running = coroutine.running
core.resume = coroutine.resume

core.exit = silly.exit_register
core.write = silly.socketsend
core.drop = silly.dropmessage

local function wakeup(co)
        core.resume(co)
end

function core.sleep(ms)
        timer.add(ms, wakeup, core.running())
        core.yield()
end

function core.start(func, ...)
        local co = core.create(func)
        return coroutine.resume(co, ...)
end

function core.wakeup(co)
        timer.add(0, wakeup, co)
end

--socket dispatch message

local socket_type = {
        [2] = "accept",         --SILLY_SOCKET_ACCEPT   = 2
        [3] = "close",          --SILLY_SOCKET_CLOSE    = 3
        [4] = "connected",      -- SILLY_SOCKET_CONNECTED = 4
        [5] = "data",           --SILLY_SOCKET_DATA = 5
}

local listen_dispatch = {}
local socket_dispatch = {}
local socket_connect = {}

function core.listen(port, dispatch)
        assert(port)
        assert(dispatch)
        local portid = env.get("listen." .. port)
        if portid == nil then
                print("invald port name")
                return false
        end
        portid = tonumber(portid)
        listen_dispatch[portid] = dispatch 

        return true

end

function core.connect(ip, port, dispatch)
        assert(ip)
        assert(port)
        assert(dispatch)

        local fd = silly.socketconnect(ip, port)
        if fd < 0 then
                return -1
        end
        assert(socket_connect[fd] == nil)
        socket_connect[fd] = core.running()
        local ok = core.yield()
        socket_connect[fd] = nil
        if ok ~= true then
                return -1
        end
        socket_dispatch[fd] = assert(dispatch)

        return fd
end

function core.close(fd)
        local sc = socket_dispatch[fd]
        if sc == nil then
                return false
        end
        socket_dispatch[fd] = nil
        assert(socket_connect[fd] == nil)
        return silly.socketclose(fd)
end

--the socket handler can't be yield
local SOCKET = {}
function SOCKET.accept(_, fd, portid, _)
        assert(socket_dispatch[fd] == nil)
        assert(socket_connect[fd] == nil)
        assert(listen_dispatch[portid])
        socket_dispatch[fd] = assert(listen_dispatch[portid])
        return socket_dispatch[fd]
end

function SOCKET.close(_, fd, _, _)
        local co = socket_connect[fd]
        if co then      --connect fail
                core.resume(co, false)
                return nil;
        end
        local sd = socket_dispatch[fd]
        if sd == nil then       --have already closed
                return nil;
        end
        local d = socket_dispatch[fd];
        socket_dispatch[fd] = nil
        return d
end

function SOCKET.connected(_, fd, _, _)
        local co = socket_connect[fd]
        if co == nil then       --have already closed
                assert(socket_dispatch[fd] == nil)
                return
        end
        core.resume(co, true)

        return nil
end

function SOCKET.data(_, fd, _, _)
        --do nothing
        return socket_dispatch[fd]
end

local function dispatch_message(type, fd, portid, message)
        local type = socket_type[type]
        --may run other coroutine here(like connected)
        local dispatch = assert(SOCKET[type])(type, fd, portid, message)
        --check if the socket has closed
        if dispatch == nil then     --have ready close
                core.drop(message)
                return ;
        end
        local co = core.create(dispatch)
        core.resume(co, type, fd, portid, message)
end

silly.socketentry(dispatch_message)

return core

