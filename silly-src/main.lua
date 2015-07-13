local server = require("server")
local raw = require("rawpacket")

print("hello lua")

local packet = raw.create()

server.socket_recv(function (msg)
        local fd, type = raw.push(packet, msg)
        print("lua.server.push", fd, type)

        local sid, data = raw.pop(packet)
        if (sid and data) then
                print("lua.server.pop", sid, #data, data)

                local p, s = raw.pack("helloworld");

                print("lua.send", p, s)

                server.socket_send(sid, p, s);
        end
end)

local function timer()
        print("heartbeat~")
        server.timer_add(1000, timer);
end

server.timer_add(1000, timer);

