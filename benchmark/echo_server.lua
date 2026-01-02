local tcp = require "silly.net.tcp"

local server = tcp.listen {
    addr = "127.0.0.1:6389",
    accept = function(conn)
        while true do
            local l, err = conn:read("\n")
            if err then
		conn:close()
                break
            end
            if l == "save\r\n" then
                conn:write("*2\r\n$4\r\nsave\r\n$23\r\n3600 1 300 100 60 10000\r\n")
            elseif l == "appendonly\r\n" then
                conn:write("*2\r\n$10\r\nappendonly\r\n$2\r\nno\r\n")
            elseif l == "PING\r\n" then
                conn:write("+PONG\r\n")
            end
        end
    end
}
