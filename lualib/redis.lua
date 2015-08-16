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
        response.param_count = 1
        response.success = true
        table.insert(response.packet, res)
end

response_header[header:byte(2)] = function (res)        --'-'
        response.param_count = 1
        response.success = false
        table.insert(response.packet, res)
end

response_header[header:byte(3)] = function (res)        --':'
        response.param_count = 1
        response.success = true
        table.insert(response.packet, tonumber(res))
end

response_header[header:byte(4)] = function (res)        --'*'
        response.param_count = tonumber(res)
        assert(#response.packet == 0)
        response.success = true
end

response_header[header:byte(5)] = function (res)        --'$'
        if response.param_count == 0 then
                response.param_count = 1
                response.success = true
        end
        response.need_count = tonumber(res)
end

function response_header.data(res)                      --data
        assert(#res == response.need_count)
        table.insert(response.packet, res)
end

local function read_response(data)
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

        if response.param_count == #response.packet then
                return true
        else
                return false
        end
end

local function request(cmd)
        sfifo:request(cmd, read_response)

        local r
        local success

        assert(response.param_count == #response.packet)
        
        success = response.success
        if response.param_count == 1 then
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

--[[
function redis.ping()
        local cmd = "*1\r\n$4\r\nPING\r\n"
        local res = request(cmd)
        print(res)
end

function redis.set(k, v)
        local cmd = string.format("*2\r\n$3\r\nGET\r\n$3\r\nbar\r\n")
        local res = request(cmd)
        print("set-res", res)
        print("set-end")
end
]]--



return redis


