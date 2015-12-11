local socket = require "socket"
local core = require "silly.core"

local tunpack = table.unpack
local tinsert = table.insert
local tremove = table.remove

local FIFO_CONNECTING   = 1
local FIFO_CONNECTED    = 2
local FIFO_CLOSE        = 3

local socketfifo = {
}

local function wakeup(v, dummy1, dummy2, ...)
        assert(dummy1 == nil or dummy1 == true)
        assert(dummy2 == nil or dummy2 == true)

        core.resume(v, ...)
end

--when close the socket fifo, we must wakeup all the wait coroutine
--but the coroutine which we wakeup can be call connect too,
--if so, things will become complicated
--so, the socketfifo will be implemented can only be connected once
function socketfifo:create(config)
        local fifo = {}
        self.__index = self
        setmetatable(fifo, self)

        fifo.status = false
        fifo.ip = config.ip
        fifo.port = config.port
        fifo.auth = config.auth
        fifo.conn_queue = {}
        fifo.co_queue = {}
        fifo.res_queue = {}
        fifo.dispatch_co = false

        return fifo
end

--this function will be run the indepedent coroutine
local function dispatch_response(fifo)
        return function ()
                while true do
                        if socket.closed(fifo.fd) then
                                fifo:close()
                                return
                        end
                        local process_res = tremove(fifo.res_queue)
                        local co = tremove(fifo.co_queue)
                        if process_res and co then
                                local res = { pcall(process_res, fifo) }
                                if res[1] and res[2] then
                                        wakeup(co, tunpack(res))
                                else
                                        print("wakeup_response", res[1], res[2])
                                        wakeup(co)
                                        fifo:close()
                                        return 
                                end
                        else
                                fifo.dispatch_co = core.running()
                                core.yield()
                        end
                end
        end
end

local function wait_for_response(fifo, response)
        local co = core.running()
        tinsert(fifo.co_queue, 1, co)
        tinsert(fifo.res_queue, 1, response)
        if fifo.dispatch_co then     --the first request
                local co = fifo.dispatch_co
                fifo.dispatch_co = nil
                core.wakeup(co)
        end
        return core.yield()
end


local function wait_for_conn(fifo)
        tinsert(fifo.conn_queu, core.running())
        core.yield()
end

local function wake_up_conn(fifo)
        for _, v in pairs(fifo.conn_queue) do
                wakeup(v)
        end

        fifo.conn_queue = {}
end

local function block_connect(self)
        if self.status == FIFO_CONNECTED then
                return true;
        end

        if self.status == false then
                local res

                self.status = FIFO_CONNECTING
                self.sock = socket.connect(self.ip, self.port)
                if self.sock < 0 then
                        res = false
                        self.status = FIFO_CLOSE
                else
                        self.status = FIFO_CONNECTED
                        res = true
                end
                
                if res then
                        self.dispatch_co = core.create(dispatch_response(self))
                end

                if res and self.auth then
                        wait_for_response(self, self.auth)
                end
                wake_up_conn(self)
                return res
        elseif self.status == FIFO_CONNECTING then
                wait_for_conn(self)
                if (self.status == FIFO_CONNECTED) then
                        return true
                else
                        return false
                end
        end

        return false
end

function socketfifo:connect()
        return block_connect(self)
end

function socketfifo:close()
        if self.status == FIFO_CLOSE then
                return 
        end
        self.status = FIFO_CLOSE
        local co = tremove(self.co_queue)
        tremove(self.res_queue)
        while co do
                wakeup(co)
                co = tremove(self.co_queue)
                tremove(self.res_queue)
        end

        socket.close(self.sock)
        self.sock = false

        return 
end

function socketfifo:closed()
        return self.status == FIFO_CLOSE
end

-- the respose function will be called in the socketfifo coroutine
function socketfifo:request(cmd, response)
        local res
        assert(block_connect(self))
        res = socket.write(self.sock, cmd)
        if response then
                return wait_for_response(self, response)
        else
                return nil
        end
end

local function read_write_wrapper(func)
        return function (self, ...)
                return func(self.sock, ...)
        end
end

socketfifo.read = read_write_wrapper(socket.read)
socketfifo.write = read_write_wrapper(socket.write)
socketfifo.readline = read_write_wrapper(socket.readline)

return socketfifo

