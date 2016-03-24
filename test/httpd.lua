local server = require "http.server"

local dispatch = {}

local function dump(reqeust, body)
        for k, v in pairs(request) do
                print(k, v)
        end
        print(#body, body)
end

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
                string.format("Content-Length:%d", #body),
                }

        write(200, head, body)
end

local content = ""

dispatch["/download"] = function(request, body, write)
        write(200, {"Content-Type: text/plain"}, content)
end

dispatch["/upload"] = function(request, body, write)
        local val = body:match(".-=(.+)&")
        if val then
                content = val
        end
        local body = "Upload"
        local head = {
                "Content-Type: text/plain",
                }


        write(200, head, body)
end


server.listen("web", function(request, body, write)
        local c = dispatch[request.URI]
        if c then 
                c(request, body, write)
        else
                print("Unsupport URI", request.URI)
                write(404, {"Content-Type: text/plain"}, "404 Page Not Found")
        end
end)

