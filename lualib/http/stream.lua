local socket = require "sys.socket"
local tonumber = tonumber
local stream = {}

function stream.readrequest(fd, readl, readn)
	local header = {}
	local body = ""
	local first = readl(fd, "\r\n")
	local tmp = readl(fd, "\r\n")
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
		tmp = readl(fd, "\r\n")
		if not tmp then
			return nil
		end
	end
	local encoding = header["Transfer-Encoding"]
	if encoding then
		if encoding ~= "chunked" then
			return 501
		end
		while true do
			local n = readl(fd, "\r\n")
			local sz = tonumber(n, 16)
			if not sz or sz == 0 then
				break
			end
			body = body .. readn(fd, sz)
			readl(fd, "\r\n")
		end
	end
	local len = header["Content-Length"]
	if len then
		local len = tonumber(len)
		body = readn(fd, len)
	end

	return 200, first, header, body
end

return stream

