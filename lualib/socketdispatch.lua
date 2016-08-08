local socket = require "socket"
local core = require "silly.core"

local tunpack = table.unpack
local tinsert = table.insert
local tremove = table.remove

local CONNECTING   = 1
local CONNECTED    = 2
local CLOSE        = 5
local FINAL        = 6

local dispatch = {}

local mt = {
        __index = dispatch,
        __gc = function(tbl)
                tbl:close()
        end
}

--the function of process response insert into d.funcqueue
function dispatch:create(config)
        local d = {}
        d.socket = false
        d.status = CLOSE 
        d.dispatchco = false
        d.config = config
        d.connectqueue = {}
        d.waitqueue = {}
        d.funcqueue = {}        --process response, return
        setmetatable(d, mt)
        return d 
end

local function wakeup(co, callret, success, ...)
        assert(callret == true)
        assert(success == true)
        core.wakeup(co, ...)
end

local function wakeup_all(self, ret, err)
        local co = tremove(self.waitqueue)
        tremove(self.funcqueue)
        while co do
                core.wakeup(co, ret, err)
                co = tremove(self.waitqueue)
                tremove(self.funcqueue)
        end
end

local function doclose(self)
        if (self.status == CLOSE) then
                return
        end
        assert(self.sock >= 0)
        socket.close(self.sock)
        self.sock = false
        self.dispatchco = false
        self.status = CLOSE;
        wakeup_all(self, nil, "diconnected")
end


--this function will be run the indepedent coroutine
local function dispatch_response(self)
        return function ()
                while true do
                        local co = tremove(self.waitqueue)
                        local func = tremove(self.funcqueue)
                        if func and co then
                                local res = {core.pcall(func, self)}
                                if res[1] and res[2] then
                                        wakeup(co, tunpack(res))
                                else    --disconnected
                                        print("dispatch_response disconnected")
                                        core.wakeup(co, nil, "disconnected") 
                                        doclose(self)
                                        return 
                                end
                        else
                                self.dispatchco = core.running()
                                core.wait()
                        end
                end
        end
end

local function waitfor_response(self, response)
        local co = core.running()
        tinsert(self.waitqueue, 1, co)
        tinsert(self.funcqueue, 1, response)
        if self.dispatchco then     --the first request
                local co = self.dispatchco
                self.dispatchco = nil
                core.wakeup(co)
        end
        return core.wait()
end

local function waitfor_connect(self)
        local co = core.running()
        tinsert(self.connectqueue, 1, co)
        return core.wait()
end

local function wakeup_conn(self, ...)
        for k, v in pairs(self.connectqueue) do
                core.wakeup(v, ...)
                self.connectqueue[k] = nil
        end
end

local function tryconnect(self)
        if self.status == CONNECTED then
                return true;
        end
        if self.status == FINAL then
                return false
        end
        local res
        if self.status == CLOSE then
                self.status = CONNECTING;
                self.sock = socket.connect(self.config.addr)
                if not self.sock then
                        res = false
                        self.status = CLOSE
                else
                        res = true
                        self.status = CONNECTED;
                end
                local ret
                ret = {res}
                if res then
                        assert(self.dispatchco == false)
                        core.fork(dispatch_response(self))
                        if self.config.auth then
                                ret = {waitfor_response(self, self.config.auth)}
                        end
                        assert(#self.funcqueue == 0)
                        assert(#self.waitqueue == 0)
                        if not ret[1] then
                                doclose(self)
                                print("socketdispatch auth fail", table.unpack(ret))
                        end
                end
                wakeup_conn(self, table.unpack(ret))
                return table.unpack(ret)
        elseif self.status == CONNECTING then
                return waitfor_connect(self)
        else
                core.error("try_connect incorrect call at status:" .. self.status)
        end
end

function dispatch:connect()
        return tryconnect(self)
end

function dispatch:close()
        if self.status == FINAL then
                return 
        end
        doclose(self)
        self.status = FINAL 
        return 
end

-- the respose function will be called in the socketfifo coroutine
function dispatch:request(cmd, response)
        local res
        assert(tryconnect(self))
        res = socket.write(self.sock, cmd)
        if not res then
                doclose(self)
                return nil
        end
        if response then
                return waitfor_response(self, response)
        else
                return nil
        end
end

local function read_write_wrapper(func)
        return function (self, ...)
                return func(self.sock, ...)
        end
end

dispatch.read = read_write_wrapper(socket.read)
dispatch.write = read_write_wrapper(socket.write)
dispatch.readline = read_write_wrapper(socket.readline)

return dispatch

