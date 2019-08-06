local socket = require "sys.socket"
local tonumber = tonumber
local stream = {}

local function readheader(fd, readl)
	local header = {}
	local tmp = readl(fd, "\r\n")
	if not tmp then
		return nil
	end
	while tmp ~= "\r\n" do
		local k, v = tmp:match("(.+):%s+(.+)\r\n")
		k = k:lower(k)
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
	return header
end

local function read_body(hdr, fd, readl, readn)
	local body
	local encoding = hdr["transfer-encoding"]
	if encoding then
		if encoding ~= "chunked" then
			return 501
		end
		body = ""
		while true do
			local n = readl(fd, "\r\n")
			local sz = tonumber(n, 16)
			if not sz or sz == 0 then
				break
			end
			body = body .. readn(fd, sz)
			readl(fd, "\r\n")
		end
	else
		local len = hdr["content-length"]
		if len then
			local len = tonumber(len)
			body = readn(fd, len)
		end
	end
	return 200, body

end

local function read_multipart_formdata(boundary, fd, readl, readn)
	local files = {}
	local boundary_start = "--" .. boundary
	local trunc = -#boundary_start-1-2
	local l = readl(fd, "\r\n")
	repeat
		local hdr = readheader(fd, readl)
		local body = readl(fd, boundary_start)
		local term = readl(fd, "\r\n")
		files[#files + 1] = {
			header = hdr,
			content = body:sub(1, trunc)
		}
	until term == '--\r\n'
	return 200, files
end

function stream.readrequest(fd, readl, readn)
	local status, body
	local first = readl(fd, "\r\n")
	local header = readheader(fd, readl)
	if not header then
		return
	end
	local typ = header["content-type"]
	if typ and typ:find("multipart/form-data", 1, true) then
		local bd = typ:match("boundary=([%w-]+)")
		status, body = read_multipart_formdata(bd, fd, readl, readn)
	else
		status, body = read_body(header, fd, readl, readn)
	end
	return status, first, header, body
end

return stream

