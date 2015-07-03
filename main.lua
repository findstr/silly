local server = require("server")
local crypt = require("crypt")
local json = require("json")
local CMD = {}

local usr
local pwd


function CMD.register(fd, data) 
        usr = data.user
        pwd = data.pwd
        server.send(fd, "I receive it")
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
                assert(CMD[t.cmd](fd, t))
                --[[
                print("---fd:", fd);
                print("---data:", data);
                server.send(fd, "i have receive:" .. data)
                ]]--
        end
end
