local silly = require "silly"
local env = require "silly.env"

local core = {}

local tinsert = table.insert
local tremove = table.remove

--coroutine pool
--sometimes, the coroutine will never execute the end
--so use the weaktable
local copool = {}
local wakemt = {__mode="kv"}

setmetatable(copool, wakemt)
local function cocreate(f)
        local co = table.remove(copool)
        if co then
                coroutine.resume(co, "STARTUP", f)
                return co
        end

        local function cocall()
                while true do
                        local ret, func = coroutine.yield("EXIT")
                        if ret ~= "STARTUP" then
                                print("create coroutine fail", ret)
                                print(debug.traceback())
                                return
                        end
                        local ok, err = pcall(func, coroutine.yield())
                        if ok == false then
                                print("cocall", err)
                                print(debug.traceback())
                        end
                end
        end

        co = coroutine.create(cocall)
        coroutine.resume(co)    --wakeup the new coroutine
        coroutine.resume(co, "STARTUP", f)       --pass the function handler
        if #copool > 100 then
                print("coroutine pool large than 100", #copool)
        end
        return co
end

core.running = coroutine.running
core.quit = silly.quit
core.write = silly.socketsend
core.drop = silly.dropmessage

function core.error(errmsg)
        print(errmsg)
        print(debug.traceback())
end


local wakeup_co_status = {}
local wakeup_co_param = {}
local wait_co_status = {}
local sleep_co_session = {}
local sleep_session_co = {}

local dispatch_wakeup

local function waitresume(co, typ, ...)
        assert(typ == "WAKEUP", typ)
        assert(wakeup_co_status[co] == nil)
        assert(wait_co_status[co]== nil)
        assert(sleep_co_session[co] == nil)
        return ...
end


local function waityield(co, ret, typ, ...)
        if ret == false then
                return
        end
        if typ == "WAIT" then
                assert(wakeup_co_status[co] == nil)
                assert(wait_co_status[co])
                assert(sleep_co_session[co] == nil)
        elseif typ == "SLEEP" then
                assert(wakeup_co_status[co] == nil)
                assert(wait_co_status[co] == nil)
                assert(sleep_co_session[co])
        elseif typ == "WAKEUP" then
                assert(wakeup_co_status[co] == nil)
                assert(wait_co_status[co]== nil)
                assert(sleep_co_session[co] == nil)
        elseif typ == "EXIT" then
                assert(co)
                table.insert(copool, co)
        else
                print("silly.core waityield unkonw return type", typ)
                print(debug.traceback())
        end
        dispatch_wakeup()
        return ...
end

function dispatch_wakeup()
        local k, v
        k, v = next(wakeup_co_status, k)
        if not k then
                return
        end
        local co = k
        local param = wakeup_co_param[co]
        wakeup_co_status[co] = nil
        wakeup_co_param[co] = nil
        if not param then
                param = {}
        end
        waityield(co, coroutine.resume(co, "WAKEUP", table.unpack(param)))
end

function core.fork(func)
        local co = cocreate(func)
        assert(co)
        assert(wakeup_co_status[co] == nil)
        wakeup_co_status[co] = "FORK"
        return co
end

function core.wait()
        local co = coroutine.running()
        assert(wakeup_co_status[co] == nil)
        assert(sleep_co_session[co] == nil)
        assert(wait_co_status[co] == nil)
        wait_co_status[co] = "WAIT"
        return waitresume(co, coroutine.yield("WAIT"))
end

function core.wakeup(co, ...)
        assert(wait_co_status[co] or sleep_co_session[co])
        assert(wakeup_co_status[co] == nil)
        wakeup_co_status[co] = "WAKEUP"
        wakeup_co_param[co] = table.pack(...)
        wait_co_status[co] = nil
end

function core.sleep(ms)
        local co = coroutine.running()
        local session = silly.timeout(ms)
        sleep_session_co[session] = co
        sleep_co_session[co] = session
        waitresume(co, coroutine.yield("SLEEP"))
end

function core.start(func, ...)
        local co = cocreate(func)
        waityield(co, coroutine.resume(co, ...))
end


--socket
local socket_dispatch = {}
local socket_connect = {}

function core.listen(port, dispatch)
        assert(port)
        assert(dispatch)
        local ip, port, backlog = port:match("([0-9%.]*)@([0-9]+):?([0-9]*)")
        if ip == "" then
                ip = "0.0.0.0"
        end
        if backlog == "" then
                backlog = 5
        else
                backlog = tonumber(backlog)
                assert(backlog > 0, "backlog need large than 0")
        end
        port = tonumber(port)
        if port == 0 then
                print("listen invaild port", port)
                return nil
        end
        local id = silly.socketlisten(ip, port, backlog);
        if id < 0 then
                print("listen", port, "error",  id)
                return nil
        end
        socket_dispatch[id] = dispatch 
        return id
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
        socket_connect[fd] = coroutine.running()
        local ok = core.wait()
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
        local ret = silly.socketclose(fd)
        return ret
end

--the message handler can't be yield
local messagetype = {
        [1] = "expire",         --SILLY_TEXPIRE         =1
        [2] = "accept",         --SILLY_SACCEPT         = 2
        [3] = "close",          --SILLY_SCLOSE          = 3
        [4] = "connected",      --SILLY_SCONNECTED      = 4
        [5] = "data",           --SILLY_SDATA           = 5
}

local MSG = {}
function MSG.expire(session, _, _)
        local co = sleep_session_co[session]
        assert(sleep_co_session[co] == session)
        core.wakeup(co)
        sleep_session_co[session] = nil
        sleep_co_session[co] = nil
end

function MSG.accept(fd, _, portid, addr)
        assert(socket_dispatch[fd] == nil)
        assert(socket_connect[fd] == nil)
        assert(socket_dispatch[portid])
        socket_dispatch[fd] = assert(socket_dispatch[portid])
        return socket_dispatch[fd]
end

function MSG.close(fd, _, _)
        local co = socket_connect[fd]
        if co then      --connect fail
                core.wakeup(co, false)
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

function MSG.connected(fd, _, _)
        local co = socket_connect[fd]
        if co == nil then       --have already closed
                assert(socket_dispatch[fd] == nil)
                return
        end
        core.wakeup(co, true)
        return nil
end

function MSG.data(fd, _, _)
        --do nothing
        return socket_dispatch[fd]
end

local function dispatch(type, fd, message, ...)
        local type = messagetype[type]
        --may run other coroutine here(like connected)
        local dispatch = assert(MSG[type], type)(fd, message, ...)
        --check if the socket has closed
        if dispatch == nil then     --have ready close
                core.drop(message)
        else
                local co = cocreate(dispatch)
                waityield(co, coroutine.resume(co, type, fd, message, ...))
        end
        dispatch_wakeup()
end

silly.dispatch(dispatch)

return core

