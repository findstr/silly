local server = require("server")
local crypt = require("crypt")
local json = require("json")
local db = require("simpledb")
local usrmgr = require("usrmgr")

local CMD = {}

local randomkey

function CMD.register(fd, data) 
        usrmgr.reg(data.user, data.pwd)
        server.send(fd,  '{"cmd":"auth1", "response":"200"}\r\n\r')
end

function CMD.auth1(fd, data) 
        local res
        randomkey = crypt.randomkey()
        res = '{"cmd":"auth1", "response":"' .. randomkey .. '"}\n'
        server.send(fd, res)
end

function CMD.auth2(fd, data)
        local pwd = usrmgr.getpwd(data.usr)
        local hash = crypt.sha1(randomkey .. pwd);
        if hasn == data.pwd then
                res = '{"cmd":"auth2", "response":"' .. 200 .. '"}\n'
        else
                res = '{"cmd":"auth2", "response":"' .. 403 .. '"}\n'
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
                assert(CMD[t.cmd])(fd, t)
                --server.send(fd, "i have receive:" .. data)
        end
end

