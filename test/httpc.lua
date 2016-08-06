local core = require "silly.core"
local client = require "http.client"

local function print_r(tbl)
        for k, v in pairs(tbl) do
                print("key:", k)
                if type(v) == "table" then
                        print_r(v)
                else
                        print(v)
                end
        end
end

core.start(function()
        local status, head, body = client.POST("http://127.0.0.1:8080/upload",
                                {"Content-Type: application/x-www-form-urlencoded"},
                                "hello=findstr&")
        --local status, head, body = client.GET("http://127.0.0.1:8080/")
        print("status", status)
        --print_r(head)
        --print(body)
end)

