local server = require "http.server"
local client = require "http.client"
local P = require "print"

local dispatch = {}

dispatch["/"] = function(reqeust, body, write)
        local body = [[
                <html>
                        <head>Hello Stupid</head>
                        <body>
                                <form action="upload" method="POST">
                                <input type="text" name="Hello"/>
                                <input type="submit" name="submit"/>
                                </form>
                        </body>
                </html>
        ]]
        local head = {
                "Content-Type: text/html",
                }

        write(200, head, body)
end

local content = ""

dispatch["/download"] = function(request, body, write)
        write(200, {"Content-Type: text/plain"}, content)
end

dispatch["/upload"] = function(request, body, write)
        if request.form.Hello then
                content = request.form.Hello
        end
        local body = "Upload"
        local head = {
                "Content-Type: text/plain",
                }


        write(200, head, body)
end


server.listen("@8080", function(request, body, write)
        local c = dispatch[request.uri]
        if c then 
                c(request, body, write)
        else
                print("Unsupport uri", request.uri)
                write(404, {"Content-Type: text/plain"}, "404 Page Not Found")
        end
end)


--client part

return function()
        local status, head, body = client.POST("http://127.0.0.1:8080/upload",
                                {"Content-Type: application/x-www-form-urlencoded"},
                                "Hello=findstr&")
        local status, head, body = client.GET("http://127.0.0.1:8080/download")
        assert(body == "findstr")
        print("status", status, body)
end

