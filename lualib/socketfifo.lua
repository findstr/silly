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
        fifo.conn_queue = {}
        fifo.req_queue = {}

        return fifo
end

local function wait_for_conn(fifo)
        fifo.conn_queue[#fifo.conn_queue + 1] = core.self()
        core.block()
end

local function wake_up_conn(fifo, res)
        for _, v in pairs(fifo.conn_queue) do
                core.run(v)
        end

        fifo.conn_queue = {}
end

local function wait_for_response(fifo)
        local co = core.self()
        table.insert(fifo.req_queue, 1, co)
        return core.block()
end

local function wakeup_one_response(fifo, data)
        local co = table.remove(fifo.req_queue)
        assert(co)
        core.run(co, data)
end

--EVENT
local function gen_event(fifo)
        return function (fd)
                print("fifo - accept", fifo)
        end,

        function (fd)
                print("fifo - close", fifo)
                local co = table.remove(fifo.req_queue)
                print("fifo - close2", #fifo.req_queue)
                while co do
                        print("fifo - close3", co)
                        core.run(co, nil)
                        co = table.remove(fifo.req_queue)
                end
        end,

        function (fd, data)
                print("fifo - data", data)
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
                self.fd = socket.connect(self.ip, self.port, EVENT)
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

function socketfifo:request(cmd, need_response)
        local res
        socket.write(self.fd, cmd)
        if need_response then
                res = wait_for_response(self)
        else
                res = nil
        end

        return res
end


return socketfifo

