local core = require "sys.core"
local helper = require "http.helper"
local stream = require "http2.stream"
local tonumber = tonumber
local parseurl = helper.parseurl

local M = {}

local function wrap_request(method)
	return function(url, header, body)
		local _, host, port, path = parseurl(url)
		local stream, err = stream.connect(host, port)
		if not stream then
			return nil, err
		end
		header = header or {}
		header['host'] = host
		if body then
			header['content-length'] = #body
		end
		local ok, err = stream:req(method, path, header, not body)
		if not ok then
			return nil, err
		end
		if body then
			stream:write(body)
		end
		local header, err = stream:read()
		if not header then
			return nil, err
		end
		local status = tonumber(header[':status'])
		header[':status'] = nil
		local body = stream:readall()
		stream:close()
		return status, header, body
	end
end

M.GET = wrap_request("GET")
M.POST = wrap_request("POST")
M.listen = stream.listen

return M

