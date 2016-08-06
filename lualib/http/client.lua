local socket = require "socket"
local stream = require "http.stream"
local dns = require "dns"

local client = {}

local connect = socket.connect
local readline = socket.readline
local read = socket.read
local write = socket.write

local function parsehost(url)
        local host, port, abs = string.match(url, "http://([^:/]+):?(%d*)([%w-_/]*)")
        if abs == "" then
                abs = "/"
        end
        return host, port, abs
end

local function send_request(fd, method, host, abs, header, body)
        local tmp = ""
        table.insert(header, 1, string.format("%s %s HTTP/1.1", method, abs))
        table.insert(header, string.format("Host: %s", host))
        table.insert(header, string.format("Content-Length: %d", #body))
        table.insert(header, string.format("User-Agent: Silly/0.2"))
        tmp = tmp .. table.concat(header, "\r\n")
        tmp = tmp .. "\r\n\r\n"
        tmp = tmp .. body
        write(fd, tmp)
end

local function recv_response(fd)
       local readl = function()
                return readline(fd, "\r\n")
        end
        local readn = function(n)
                return read(fd, n)
        end
        local status, first, header, body = stream.recv_request(readl, readn)
        if not status then      --disconnected
                return nil
        end
        if status ~= 200 then
                socket.close(fd)
                return status
        end
        local ver, status= first:match("HTTP/([%d|.]+)%s+(%d+)")
        return status, header, body, ver
end

local function process(uri, header, body)
        header = header or {}
        body = body or ""
        local ip
        local host, port, abs = parsehost(uri)
        if dns.isdomain(host) then
                ip = dns.query(host)
        else
                ip = host
        end
        if not port or port == "" then
                ip = ip .. "@80"
        else
                ip = string.format("%s@%s", ip, port)
        end
        local fd = connect(ip)
        if fd < 0 then
                return 599
        end
        if port ~= "" then
                host = host .. ":" .. port
        end
        send_request(fd, "GET", host, abs, header, body)
        local status, header, body, ver = recv_response(fd)
        socket.close(fd)
        return status, header, body, ver
end

function client.GET(uri, header)
        return process(uri, header)
end

function client.POST(uri, header, body)
        return process(uri, header, body)
end

return client

