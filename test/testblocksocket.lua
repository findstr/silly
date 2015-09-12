local bsocket = require("blocksocket")
local core = require("core")

core.start(function()
        local fd = bsocket:connect("127.0.0.1", 8989)
        print("connect fd:", fd)
        local cmd = "hello\r\n"
        fd:write(cmd)
        local res = fd:read(3)
        print("read res1:", res)
        local res = fd:read(2)
        print("read res2:", res)
        local res = fd:read(9)
        print("read res3:", res)

        print("test end")
end)


