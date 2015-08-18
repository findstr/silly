local socket = require("socket")
local core = require("core")

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
        fifo.process_res = nil

        return fifo
end

local function wait_for_conn(fifo)
        fifo.conn_queue[#fifo.conn_queue + 1] = core.self()
        core.block()
end

local function wake_up_conn(fifo, res)
        for _, v in pairs(fifo.conn_queue) do
                socket.wakeup(v)
        end

        fifo.conn_queue = {}
end

local function wait_for_response(fifo, response)
        local co = core.self()
        table.insert(fifo.co_queue, 1, co)
        table.insert(fifo.res_queue, 1, response)
        return core.block()
end

local function wakeup_one_response(fifo, data)
        if fifo.process_res == nil then
                fifo.process_res = table.remove(fifo.res_queue)
        end

        if fifo.process_res(data) then
                local co = table.remove(fifo.co_queue)
                fifo.process_res = nil
                socket.wakeup(co)
        end
end

--EVENT
local function gen_event(fifo)
        return function (fd)    -- accept
                print("fifo - accept", fifo)
        end,

        function (fd)           -- close 
                print("fifo - close", fifo)
                local co = table.remove(fifo.req_queue)
                print("fifo - close2", #fifo.req_queue)
                while co do
                        print("fifo - close3", co)
                        socket.wakeup(co, nil)
                        co = table.remove(fifo.req_queue)
                end
        end,

        function (fd, data)     -- data
                wakeup_one_response(fifo, data)
        end
end

function socketfifo:connect()
        if self.status == FIFO_CONNECTED then
                return true;
        end

        if self.status == FIFO_CLOSE then
                local res
                local EVENT = {}
                EVENT.accept , EVENT.close, EVENT.data = gen_event(self)

                self.status = FIFO_CONNECTING
                self.fd = socket.connect(self.ip, self.port, EVENT, self.packer)
                if (self.fd < 0) then
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

-- the respose function will be called in the socketfifo coroutine
-- so the response function must be nonblock
function socketfifo:request(cmd, response)
        local res
        socket.write(self.fd, cmd)
        if response then
                res = wait_for_response(self, response)
        else
                res = nil
        end

        return res
end


return socketfifo

