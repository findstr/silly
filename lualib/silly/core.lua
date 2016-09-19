local silly = require "silly"
local env = require "silly.env"

local core = {}

local tremove = table.remove
local tpack = table.pack
local tunpack = table.unpack

local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
coroutine.running = nil
coroutine.yield = nil
coroutine.resume = nil

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
local weakmt = {__mode="kv"}
setmetatable(copool, weakmt)

local function cocall()
        while true do
                local ret, func = coyield("EXIT")
                if ret ~= "STARTUP" then
                        print("create coroutine fail", ret)
                        print(debug.traceback())
                        return
                end
                local ok, err = core.pcall(func, coyield())
                if ok == false then
                        print("call", err)
                end
        end
end

local function cocreate(f)
        local co = tremove(copool)
        if co then
                coresume(co, "STARTUP", f)
                return co
        end

        co = coroutine.create(cocall)
        coresume(co)    --wakeup the new coroutine
        coresume(co, "STARTUP", f)       --pass the function handler
        return co
end

core.write = silly.send
core.udpwrite = silly.udpsend
function core.running()
        local co = corunning()
        return co
end
core.exit = silly.exit
core.tostring = silly.tostring
core.genid = silly.genid
core.memstatus = silly.memstatus
core.msgstatus = silly.msgstatus
core.now = silly.timenow
core.current = silly.timecurrent

local function errmsg(msg)
        return debug.traceback("error: " .. msg, 2)
end

core.pcall = function(f, ...)
        return xpcall(f, errmsg, ...)
end

function core.error(errmsg)
        print(errmsg)
        print(debug.traceback())
end


local wakeup_co_status = {}
local wakeup_co_param = {}
local wait_co_status = {}
local sleep_co_session = {}
local sleep_session_co = {}

--the wait_co_status won't hold the coroutine
--this table just to be check some incorrect call of core.wakeup
--the coroutine in wait_co_status should be hold by the wakeuper
setmetatable(wait_co_status, weakmt)

local dispatch_wakeup

local function waitresume(co, typ, ...)
        assert(typ == "WAKEUP", typ)
        assert(wakeup_co_status[co] == nil)
        assert(wait_co_status[co]== nil)
        assert(sleep_co_session[co] == nil)
        return ...
end


local function waityield(co, ret, typ)
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
        elseif typ == "EXIT" then
                assert(co)
                copool[#copool + 1] = co
        else
                print("silly.core waityield unkonw return type", typ)
                print(debug.traceback())
        end
        dispatch_wakeup()
end

function dispatch_wakeup()
        local co = next(wakeup_co_status)
        if not co then
                return
        end
        local param = wakeup_co_param[co]
        wakeup_co_status[co] = nil
        wakeup_co_param[co] = nil
        waityield(co, coresume(co, "WAKEUP", param))
end

function core.fork(func)
        local co = cocreate(func)
        assert(co)
        assert(wakeup_co_status[co] == nil)
        wakeup_co_status[co] = "FORK"
        return co
end

function core.wait()
        local co = corunning()
        assert(wakeup_co_status[co] == nil)
        assert(sleep_co_session[co] == nil)
        assert(wait_co_status[co] == nil)
        wait_co_status[co] = "WAIT"
        return waitresume(co, coyield("WAIT"))
end

function core.wait2()
        local res = core.wait()
        if not res then
                return
        end
        return tunpack(res, 1, res.n)
end

function core.wakeup(co, res)
        assert(wait_co_status[co] or sleep_co_session[co])
        assert(wakeup_co_status[co] == nil)
        assert(wakeup_co_param[co] == nil)
        wakeup_co_status[co] = "WAKEUP"
        wakeup_co_param[co] = res
        wait_co_status[co] = nil
end

function core.wakeup2(co, ...)
        core.wakeup(co, tpack(...))
end

function core.sleep(ms)
        local co = corunning()
        local session = silly.timeout(ms)
        sleep_session_co[session] = co
        sleep_co_session[co] = session
        waitresume(co, coyield("SLEEP"))
end

function core.timeout(ms, func)
        local co = cocreate(func)
        local session = silly.timeout(ms)
        sleep_session_co[session] = co
        sleep_co_session[co] = session
        return session
end

function core.start(func, ...)
        local co = cocreate(func)
        waityield(co, coresume(co, ...))
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
        local id = silly.listen(ip, port, backlog);
        if id < 0 then
                print("listen", port, "error",  id)
                return nil
        end
        socket_dispatch[id] = dispatch 
        return id
end

function core.bind(port, dispatch)
        assert(port)
        assert(dispatch)
        local ip, port = port:match("([0-9%.]*)@([0-9]+)")
        if ip == "" then
                ip = "0.0.0.0"
        end
        port = tonumber(port)
        if port == 0 then
                print("listen invaild port", port)
                return nil
        end
        local id = silly.bind(ip, port);
        if id < 0 then
                print("udpbind", port, "error",  id)
                return nil
        end
        socket_dispatch[id] = dispatch 
        return id

end

local function doconnect(ip, dispatch, bind, dofunc)
        assert(ip)
        assert(dispatch)
        local ip, port = ip:match("([0-9%.]*)@([0-9]+)")
        assert(ip and port)
        bind = bind or "@0"
        local bip, bport = bind:match("([0-9%.]*)@([0-9]+)")
        assert(bip and bport)
        local fd = dofunc(ip, port, bip, bport)
        if fd < 0 then
                return nil
        end
        assert(socket_connect[fd] == nil)
        socket_connect[fd] = corunning()
        local ok = core.wait()
        socket_connect[fd] = nil
        if ok ~= true then
                return nil
        end
        socket_dispatch[fd] = assert(dispatch)
        return fd

end

function core.connect(ip, dispatch, bind)
        return doconnect(ip, dispatch, bind, silly.connect)
end

function core.udp(ip, dispatch, bind)
        return doconnect(ip, dispatch, bind, silly.udp)
end

function core.close(fd)
        local sc = socket_dispatch[fd]
        if sc == nil then
                return false
        end
        socket_dispatch[fd] = nil
        assert(socket_connect[fd] == nil)
        silly.close(fd)
end

--the message handler can't be yield
local messagetype = {
        [1] = "expire",         --SILLY_TEXPIRE         = 1
        [2] = "accept",         --SILLY_SACCEPT         = 2
        [3] = "close",          --SILLY_SCLOSE          = 3
        [4] = "connected",      --SILLY_SCONNECTED      = 4
        [5] = "data",           --SILLY_SDATA           = 5
        [6] = "udp",            --SILLY_UDP             = 6
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

function MSG.close(fd)
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

function MSG.connected(fd)
        local co = socket_connect[fd]
        if co == nil then       --have already closed
                assert(socket_dispatch[fd] == nil)
                return
        end
        core.wakeup(co, true)
        return nil
end

function MSG.data(fd)
        --do nothing
        return socket_dispatch[fd]
end

function MSG.udp(fd)
        --do nothing
        return socket_dispatch[fd]
end

--fd, message, portid/errno, addr
local function dispatch(type, fd, message, ...)
        local type = messagetype[type]
        --may run other coroutine here(like connected)
        local dispatch = assert(MSG[type], type)(fd, message, ...)
        --check if the socket has closed
        if dispatch then     --have ready close
                local co = cocreate(dispatch)
                waityield(co, coresume(co, type, fd, message, ...))
        end
        dispatch_wakeup()
end

silly.dispatch(dispatch)

return core

