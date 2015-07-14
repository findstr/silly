local socket= require("socket")
local timer = require("timer")
local json = require("json")
local game = require("game")
local usrmgr = require("usrmgr")

local conn_process = {}

local CMD = {}

function CMD.auth(fd, cmd)
        local res = {}
        local valid

        valid = usrmgr.reg(cmd.name)
        
        res.cmd="auth"
        if (valid == true) then
                res.uid = fd;
                game.enter(fd)
                conn_process[fd].handler = game.handler
                conn_process[fd].kick = game.kick
        else
                res.uid = -1;
        end

        print("auth result:", res.uid)

        local sz =json.encode(res)

        socket.write(socket.GDATA, fd, sz)
end

function CMD.message(fd, cmd)
        if conn_process[fd].handler then
                conn_process[fd].handler(fd, cmd)
        else
                --kick it
        end
end


local SOCKET = {}

function SOCKET.connect(fd)
        print("---new connect:", fd)
        conn_process[fd] = {}
        socket.read(fd, function(fd, data)
                local cmd = json.decode(data)
                local handler = CMD[cmd.cmd]
                if handler then
                        handler(fd, cmd)
                else
                        CMD.message(fd, cmd)
                end
        end, socket.GDATA)
end

function SOCKET.disconnect(fd)
        if conn_process[fd].kick then
                conn_process[fd].kick(fd)
        end
        conn_process[fd] = nil
        print("----disconnect---", fd)
end

socket.register(SOCKET)

