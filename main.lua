local server = require("server")
local crypt = require("crypt")

local CMD = {}

local usr
local pwd


function CMD.register(fd, data) 
        local _, r, _, u, _, p = data:match('"(%w+)":"(%w+)","(%w+)":"(%w+)","(%w+)":"(%w+)"')
        usr = u
        pwd = p
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
                local _, request = data:match('"(%w+)":"(%w+)"')
                assert(CMD[request](fd, data))
                --[[
                print("---fd:", fd);
                print("---data:", data);
                server.send(fd, "i have receive:" .. data)
                ]]--
        end
end
