local core = require "silly.core"
local rpc = require "rpc"
local zproto = require "zproto"
local crypt = require "crypt"

local logic = zproto:parse [[
test 0xff {
        .name:string 1
        .age:integer 2
        .rand:string 3
}
]]

local client = rpc.createclient {
                addr = "127.0.0.1@9999",
                proto = logic,
                timeout = 5000,
                close = function(fd, errno)
                        print("close", fd, errno)
                end,
        }
 

local function request(fd, index)
        return function()
                local test = {
                        name = "hello",
                        age = index,
                        rand = crypt.randomkey(),
                }
                local body, ack = client:call("test", test)
                if not body then
                        print("rpc call fail", body)
                        return
                end
                assert(test.rand == body.rand)
                print("rpc call", index, "ret:", body.name, body.age)
        end
end

local n = 1 
local function test()
        n = n + 1
        core.timeout(100, test)
        if n > 1000 then
                core.exit()
                return 
        end
        for i = 1, 10 do
                core.fork(request(client, i))
        end
end

core.start(function()
        print("connect 9999 start")
        client:connect()
        core.timeout(1, test)
end)


