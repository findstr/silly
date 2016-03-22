local server = require "http.server"

server.listen("web", "127.0.0.1:8080", function(status, request, body, write)
        local body = [[
                <html>
                        <head>Hello Stupid</head>
                        <body>
                                <button>push it</button>
                        </body>
                </html>
        ]]
        local head = {
                "Content-Type: text/html",
                string.format("Content-Length:%d", #body),
                }

        write(200, head, body)
end)

