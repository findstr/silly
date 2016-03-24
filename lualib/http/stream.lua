local socket = require "socket"
local stream = {}

function stream.recv_request(readl, readn)
        local header = {}
        local body = ""
        local first = readl()
        tmp = readl()
        if not tmp then
                return nil
        end
        while tmp ~= "\r\n" do
                local k, v = tmp:match("(.+):%s+(.+)\r\n")
                if header[k] then
                        header[k] = header[k] .. ";" .. v
                else
                        header[k] = v
                end
                tmp = readl()
                if not tmp then
                        return nil
                end
        end

        if header["Transfer-Encoding"] then
                return 501
        end

        if header["Content-Length"] then
                local len = tonumber(header["Content-Length"])
                if len > 4096 then
                        return 400
                end
                body = readn(len)
        end

        return 200, first, header, body
end

return stream

