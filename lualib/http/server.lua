local socket = require "socket"
local stream = require "http.stream"

local server = {}

local listen = socket.listen
local readline = socket.readline
local read = socket.read
local write = socket.write

local host_handler = {}

local http_err_msg = {
        [100] = "Continue",

        [200] = "OK",
}

local function http_handler(fd)
        local header = {}
        local status = 200

        local write = function (status, header, body)
                server.send(fd, status, header, body)
        end

        --request line
        local request = readline(fd, "\r\n")
        local method, uri, ver = request:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
        assert(method and uri and ver)
        header.method = method
        header.URI = uri
        header.version = ver

        --option
        request = readline(fd, "\r\n")
        while request ~= "\r\n" do
                local k, v = request:match("(.+):%s+(.+)\r\n")
                assert(k, v)
                if header[k] then
                        header[k] = header[k] .. ";" .. v
                else
                        header[k] = v
                end
                request = readline(fd, "\r\n")
        end

        --body
        local body = ""

        host_handler[header.Host](status, header, body, write)
end


function server.listen(port, host, handler)
        host_handler[host] = handler
        listen(port, http_handler)
end

function server.send(fd, status, header, body)
        local tmp = string.format("HTTP/1.1 %d %s\r\n", status, http_err_msg[status])
        for _, v in pairs(header) do
                tmp = tmp .. v .. "\r\n"
        end
        tmp = tmp .. "\r\n"
        tmp = tmp .. body
        write(fd, tmp)
end


return server

