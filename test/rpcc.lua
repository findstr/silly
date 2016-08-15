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
                timeout = 1000,
                pack = function(data)
                        return crypt.aesencode("hello", data)
                end,
                unpack = function(data, sz)
                        return crypt.aesdecode("hello", data, sz)
                end,
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
                local ack, body = client:call("test", test)
                if not ack then
                        print("rpc call fail", res)
                        return
                end
                assert(test.rand == body.rand)
                print("rpc call", index, "ret:", body.name, body.age)
        end
end

core.start(function()
        print("connect 9999 start")
        client:connect()
        for i = 1, 5 do
                core.fork(request(client, i))
        end
        core.sleep(10000)
        client:close(fd)
        core.quit()
end)


