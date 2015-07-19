local socket = require("socket")
local json = require("json")
local room = require("room")
local game = {}

local usr_pool = {}
local room_list = {}
local CMD = {}

local function getrid()
        local rid = #room_list + 1
        --TODO:need to reuse the hold index
        --
        return rid
end

function CMD.room_create(fd, cmd)
        local res = {}
        local rid;

        rid = getrid()
        assert(room_list[rid] == nil)
        room_list[rid] = room:create(cmd.uid)

        res.cmd = "room_create"
        if room_list[rid] then
                res.rid = rid
        else
                res.rid = -1
        end

        socket.write(fd, json.encode(res))
end

function CMD.room_list(fd, cmd)
        local rl = {}
        assert(cmd.page_index == tostring(1))
        rl.cmd = "room_list"
        rl.room = {}
        for k, v in pairs(room_list) do
                print("name", v:getname())
                rl.room[#rl.room + 1] = {name=v:getname(), rid = k}
        end

        socket.write(fd, json.encode(rl))
end

function CMD.room_enter(fd, cmd)

end

function game.process(fd, msg)
        assert(CMD[msg.cmd])(fd, msg)
end

function game.enter(fd)
        usr_pool[fd] = {}
        usr_pool[fd].fd = fd
        usr_pool[fd].handler = game.process
        usr_pool[fd].kick = nil
end

function game.kick(fd)
        if (usr_pool[fd].kick) then
                usr_pool[fd].kick(fd)
        end
        usr_pool[fd] = {}
end

function game.handler(fd, cmd)
        assert(usr_pool[fd].handler)(fd, cmd)
end

return game

