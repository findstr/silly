local socket = require("blocksocket")
local core = require("core")
local s = require("socket")

local wakeup = s.wakeup

local FIFO_CONNECTING   = 1
local FIFO_CONNECTED    = 2
local FIFO_CLOSE        = 3

local socketfifo = {
}

function socketfifo:create(config)
        local fifo = {}
        self.__index = self
        setmetatable(fifo, self)

        fifo.status = FIFO_CLOSE
        fifo.ip = config.ip
        fifo.port = config.port
        fifo.packer = config.packer
        fifo.conn_queue = {}
        fifo.co_queue = {}
        fifo.res_queue = {}

        return fifo
end

local function wait_for_conn(fifo)
        fifo.conn_queue[#fifo.conn_queue + 1] = core.self()
        core.block()
end

local function wake_up_conn(fifo, res)
        for _, v in pairs(fifo.conn_queue) do
                wakeup(v)
        end

        fifo.conn_queue = {}
end

local function wait_for_response(fifo, response)
        local co = core.self()
        table.insert(fifo.co_queue, 1, co)
        table.insert(fifo.res_queue, 1, response)
        return core.block()
end

local function wakeup_response(fifo)
        return function ()
                while fifo.sock do
                        local process_res = table.remove(fifo.res_queue)
                        local co = table.remove(fifo.co_queue)
                        if process_res == nil and co == nil  then
                                return
                        end

                        local err = process_res(fifo)
                        if err == false then
                                fifo:close()
                                return 
                        end
                        wakeup(co)
                end
        end
end

function socketfifo:connect()
        if self.status == FIFO_CONNECTED then
                return true;
        end

        if self.status == FIFO_CLOSE then
                local res

                self.status = FIFO_CONNECTING
                self.sock = socket:connect(self.ip, self.port, core.create(wakeup_response(self)))
                if self.socket == nil then
                        res = false
                        self.status = FIFO_CLOSE
                else
                        self.status = FIFO_CONNECTED
                        res = true
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

end

function socketfifo:close()
        if self.status == FIFO_CLOSE then
                return 
        end

        self.status = FIFO_CLOSE
        local co = table.remove(self.co_queue)
        table.remove(self.res_queue)
        while co do
                wakeup(co)
                co = table.remove(self.co_queue)
                table.remove(self.res_queue)
        end

        self.sock:close()
        self.sock = nil

        return 
end

-- the respose function will be called in the socketfifo coroutine
function socketfifo:request(cmd, response)
        local res
        res = self.sock:write(cmd)
        if response then
                res = wait_for_response(self, response)
        else
                res = nil
        end

        return res
end

local function read_write_wrapper(func)
        return function (self, d)
                return func(self.sock, d)
        end
end

socketfifo.read = read_write_wrapper(socket.read)
socketfifo.write = read_write_wrapper(socket.write)
socketfifo.readline = read_write_wrapper(socket.readline)

return socketfifo

