local server = require("server")
local crypt = require("crypt")
local json = require("json")
local CMD = {}

local randomkey
local usr
local pwd


function CMD.register(fd, data) 
        usr = data.user
        pwd = data.pwd
        server.send(fd, "I receive it" .. str)
end

function CMD.auth1(fd, data) 
        local res
        randomkey = crypt.randomkey()
        res = '{"cmd":"auth1", "response":"' .. randomkey .. '"}'
        server.send(fd, res)
end

function CMD.auth2(fd, data)
        local hash = crypt.sha1(randomkey .. pwd);
        if hasn == data.pwd then
                res = '{"cmd":"auth2", "response":"' .. 200 .. '"}'
        else
                res = '{"cmd":"auth2", "response":"' .. 403 .. '"}'
        end
        
        server.send(fd, res)
end

--[[
local str = crypt.sha1("123456")
for i = 1, #str do
        print(" ", string.format("%x", str:byte(i)))
end

]]--


--[[
print("hello lua")

print("server", server)
]]--
while true do
        local fd, data = server.pull()
        if (data) then
                print("receive data:", data)
                local t = json.decode(data)
                assert(CMD[t.cmd])(fd, t, data)
                --server.send(fd, "i have receive:" .. data)
        end
end
