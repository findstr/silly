local socket = require("socket")
local core = require("core")
local spacker = require("spacker")

local blocksocket = {}

local STATUS_CONNECTED  = 1
local STATUS_CLOSE      = 2

local function wakeup(bsocket, ...)
        local co = bsocket.readthread 
        if co == nil then
                return
        end

        bsocket.readthread = nil
        core.run(co, ...)
end

local mtable = {__gc = function (table)
        if table.fd > 0 then
                socket.close(table.fd)
        end
end}

local function pop_data(bsocket, byte)
        assert(bsocket.data_size >= byte)

        bsocket.data_size = bsocket.data_size - byte

        if #bsocket.data_head >= byte then
                local res = string.sub(bsocket.data_head, 1, byte)
                bsocket.data_head = string.sub(bsocket.data_head, byte + 1)
                return res
        end

        local res = {}

        table.insert(res, bsocket.data_head)
        byte = byte - #bsocket.data_head
        bsocket.data_head = ""
        while byte > 0 do
                local d = table.remove(bsocket.data_queue, 1)
                if #d > byte then
                        table.insert(res, string.sub(d, 1, byte))
                        bsocket.data_head = string.sub(d, byte + 1)
                        byte = 0
                else
                        table.insert(res, d)
                        byte = byte - #d
                end
        end
        
        return table.concat(res, "")
end

local function has_line(self, termi)
        local pos = 0
        local _, start = string.find(self.data_head, termi)
        if start ~= nil then
                pos = pos + start
                return start
        end

        pos = pos + #self.data_head

        for _, v in pairs(self.data_queue) do
                _, start = string.find(v, termi)
                if start ~= nil then
                        pos = pos + start
                        return pos
                end

                pos = pos + #v
        end

        return nil

end


local function event_function(bsocket)
        return function (fd)    -- accept
                print("blocksocket - accept", bsocket)
        end,

        function (fd)           -- close 
                bsocket.status = STATUS_CLOSE
                wakeup(bsocket)
        end,

        function (fd, data)     -- data
                --push the data
                if bsocket.data_head == "" then
                        assert(bsocket.data_size == 0)
                        bsocket.data_head = data
                else
                        table.insert(bsocket.data_queue, data)
                end
 
                local len
                bsocket.data_size = bsocket.data_size + #data
                if bsocket.linetermi == "" then
                        if bsocket.data_size < bsocket.read_len then
                                return;
                        end

                        len = bsocket.read_len
                        bsocket.read_len = 0
                else
                        len = has_line(bsocket, bsocket.linetermi)
                        if len == nil then
                                return
                        end
                        bsocket.linetermi = ""
                end
                wakeup(bsocket, pop_data(bsocket, len))
        end
end


function blocksocket:connect(ip, port, dthread)
        local t = {
                data_head  = "",
                data_queue = {},
                data_size   = 0,
                read_len = 0,
                status = STATUS_CONNECTED,
                readthread = dthread,
                linetermi = "",
        }

        setmetatable(t, {__index = self})
 
        local EVENT = {}
        EVENT.accept, EVENT.close, EVENT.data = event_function(t)

        t.fd = socket.connect(ip, port, EVENT, spacker:create("raw"))
        if t.fd >= 0 then
                return t
        else
                return nil
        end
end

function blocksocket:close()
        assert(self.readthread == nil)
        socket.close(self.fd)
        self.status = STATUS_CLOSE

        return
end

function blocksocket:read(nr)
        if self.status == STATUS_CLOSE then
                return nil
        end

        if nr > self.data_size then
                self.read_len = nr
                self.readthread = core.running()
                return core.block()
        else
                return pop_data(self, nr)
        end
end

function blocksocket:readline(termi)
        if self.status == STATUS_CLOSE then
                return nil
        end

        local has = has_line(self, termi)
        if has ~= nil then
                return pop_data(self, has)
        else
                self.linetermi = termi
                self.readthread = core.running()
                return core.block()
        end

end

function blocksocket:write(data)
        if self.status == STATUS_CLOSE then
                return nil
        end

        return socket.write(self.fd, data)
end

return blocksocket

