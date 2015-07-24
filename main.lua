local socket = require("socket")
local timer = require("timer")
local core = require("core")
local json = require("json")
local game = require("game")
local usrmgr = require("usrmgr")

local conn_process = {}

local EVENT = {}

local count = 0

function EVENT.accept(fd)
        conn_process[fd] = {}
        socket.read(fd, function (fd, data)
                count = count + #data 
                print("****Count:", count, fd, #data)
        end)
end

function EVENT.close(fd)
        print("---close:", fd)
end


socket.register(EVENT)



