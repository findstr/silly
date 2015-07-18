local silly = require("silly")
local raw = require("rawpacket")

print("hello lua")

local packet = raw.create()

silly.socket_recv(function (msg)
        local fd, type = raw.push(packet, msg)
        print("lua.server.push", fd, type)

        local sid, data = raw.pop(packet)
        if (sid and data) then
                print("lua.server.pop", sid, #data, data, "workid", silly.workid())

                local p, s = raw.pack("helloworld");

                print("lua.send", p, s)

                silly.socket_send(sid, p, s);
        end
end)

local function timer()
        print("heartbeat~", silly.workid())
        silly.timer_add(1000, timer);
end

silly.timer_add(1000, timer);


