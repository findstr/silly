local socket = require "sys.socket"
local stream = {}

function stream.recv_request(readl, readn)
	local header = {}
	local body = ""
	local first = readl()
	local tmp = readl()
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
	local encoding = header["Transfer-Encoding"]
	if encoding then
		if encoding ~= "chunked" then
			return 501
		end
		while true do
			local n = readl()
			local sz = tonumber(n, 16)
			if not sz or sz == 0 then
				break
			end
			body = body .. readn(sz)
			readl()
		end
	end
	local len = header["Content-Length"]
	if len then
		local len = tonumber(len)
		body = readn(len)
	end

	return 200, first, header, body
end

return stream

