local socket = require "socket"
local stream = require "http.stream"

local server = {}

local listen = socket.listen
local readline = socket.readline
local read = socket.read
local write = socket.write

local http_err_msg = {
        [100] = "Continue",
        [101] = "Switching Protocols",
        [102] = "Processing",
        [200] = "OK",
        [201] = "Created",
        [202] = "Accepted",
        [203] = "Non-authoritative Information",
        [204] = "No Content",
        [205] = "Reset Content",
        [206] = "Partial Content",
        [207] = "Multi-Status",
        [208] = "Already Reported",
        [226] = "IM Used",
        [300] = "Multiple Choices",
        [301] = "Moved Permanently",
        [302] = "Found",
        [303] = "See Other",
        [304] = "Not Modified",
        [305] = "Use Proxy",
        [307] = "Temporary Redirect",
        [308] = "Permanent Redirect",
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [402] = "Payment Required",
        [403] = "Forbidden",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [406] = "Not Acceptable",
        [407] = "Proxy Authentication Required",
        [408] = "Request Timeout",
        [409] = "Conflict",
        [410] = "Gone",
        [411] = "Length Required",
        [412] = "Precondition Failed",
        [413] = "Payload Too Large",
        [414] = "Request-URI Too Long",
        [415] = "Unsupported Media Type",
        [416] = "Requested Range Not Satisfiable",
        [417] = "Expectation Failed",
        [418] = "I'm a teapot",
        [421] = "Misdirected Request",
        [422] = "Unprocessable Entity",
        [423] = "Locked",
        [424] = "Failed Dependency",
        [426] = "Upgrade Required",
        [428] = "Precondition Required",
        [429] = "Too Many Requests",
        [431] = "Request Header Fields Too Large",
        [451] = "Unavailable For Legal Reasons",
        [499] = "Client Closed Request",
        [500] = "Internal Server Error",
        [501] = "Not Implemented",
        [502] = "Bad Gateway",
        [503] = "Service Unavailable",
        [504] = "Gateway Timeout",
        [505] = "HTTP Version Not Supported",
        [506] = "Variant Also Negotiates",
        [507] = "Insufficient Storage",
        [508] = "Loop Detected",
        [510] = "Not Extended",
        [511] = "Network Authentication Required",
        [599] = "Network Connect Timeout Error",
}

local function httpd(fd, handler)
        local readl = function()
                return readline(fd, "\r\n")
        end

        local readn = function(n)
                return read(fd, n)
        end

        local write = function (status, header, body)
                server.send(fd, status, header, body)
        end

        while true do
                local status, first, header, body = stream.recv_request(readl, readn)
                if not status then      --disconnected
                        return
                end
                if status ~= 200 then
                        write(status, {}, "")
                        socket.close(fd)
                        return
                end

                --request line
                local method, uri, ver = first:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
                assert(method and uri and ver)
                header.method = method
                header.URI = uri
                header.version = ver

                if tonumber(ver) > 1.1 then
                        write(505, {}, "")
                        socket.close(fd)
                        return 
                end

                handler(header, body, write)
        end
end


function server.listen(port, handler)
        local h = function(fd)
                httpd(fd, handler)
        end
        listen(port, h)
end

function server.send(fd, status, header, body)
        local tmp = string.format("HTTP/1.1 %d %s\r\n", status, http_err_msg[status])
        for _, v in pairs(header) do
                tmp = tmp .. v .. "\r\n"
        end
        tmp = tmp .. string.format("Content-Length: %d\r\n", #body)
        tmp = tmp .. "\r\n"
        tmp = tmp .. body
        write(fd, tmp)
end


return server
