local fifo = require("socketfifo")
local spacker = require("spacker")

local redis = {}

local response = {
        param_count = 0,
        need_count = 0,
        success = false,
        packet = {},
}
local sfifo = fifo:create {
                                ip = "127.0.0.1",
                                port = 6379,
                                packer = spacker:create("linepacket"),
                        }

local response_header = {}

local header = "+-:*$"

local function reset_response(packet)
        assert(packet)
        response.param_count = 0
        response.need_count = 0
        response.success = false
        response.packet = packet
end

response_header[header:byte(1)] = function (res)        --'+'
        table.insert(response.packet, res)
end

response_header[header:byte(2)] = function (res)        --'-'
        table.insert(response.packet, res)
end

response_header[header:byte(3)] = function (res)        --':'
        table.insert(response.packet, tonumber(res))
end

local function read_response()
        local data = sfifo:readline("\r\n")
        local head = data:byte(1)
        local func = response_header[head]
        local res = data
        if func then
                res = string.sub(res, 2)
        else
                res = string.sub(res, 1, #res - 2)
                func = response_header.data
        end

        func(res)

        return true
end


response_header[header:byte(4)] = function (res)        --'*'
        local nr = tonumber(res)
        for i = 1, nr do
                read_response()
        end
end

response_header[header:byte(5)] = function (res)        --'$'
        local nr = tonumber(res)
        local param = sfifo:read(nr + 2)
        table.insert(response.packet, string.sub(param, 1, -3))
end

local function request(cmd)
        sfifo:request(cmd, read_response)
        
        success = true
        if #response.packet == 1 then
                r = table.remove(response.packet)
                reset_response(response.packet)
        else
                r = response.packet
                reset_response({})
        end

        return success, r
end

local function pack_param(lines, param)
        local p =  tostring(param)
        table.insert(lines, string.format("$%d", #p))
        table.insert(lines, p)
end

local function pack_cmd(cmd, param)
        local pn = 1
        if param ~= nil then
                assert(type(param) == "table")
                pn = pn + #param;
        end

        local lines = {string.format("*%d", pn), }

        pack_param(lines, cmd)
        
        for _, v in ipairs (param) do
                pack_param(lines, v)
        end

        local sz = table.concat(lines, "\r\n")

        return sz .. "\r\n"

end


function redis.connect()
        return sfifo:connect()
end

setmetatable(redis, {__index = function (self, k)
        local cmd = string.upper(k)
        local f = function (p, ...)
                if type(p) == "table" then
                        return request(pack_cmd(cmd, p))
                elseif p ~= nil then
                        return request(pack_cmd(cmd, {p, ...}))
                else
                        return request(pack_cmd(cmd, {}))
                end
        end

        self[k] = f
        return f
end
})


return redis


