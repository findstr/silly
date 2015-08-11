local json = require("json")

local function test(tbl)
        local sz = json.encode(tbl)
        print(sz)
end

local t1 = {uid="1",cmd="auth"}
test(t1)
local t2 = {rid="1", cmd="roomcreate"}
test(t2)
local t3 = {
                room = 
                {
                        {name="1 room", rid = "1"},
                        {name="2 room", rid = "2"},
                },
                cmd="room_list"
        }

test(t3)

local t4 = {
                cmd="game_start",
                uid="1",
                card={{card="kill"}, {card="peach"}, {card="run"}, {card="kill"}}
        }

test(t4)

