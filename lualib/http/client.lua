local core = require "sys.core"
local stream = require "http.stream"
local helper = require "http.helper"
local pairs = pairs
local assert = assert
local tonumber = tonumber
local format = string.format
local match = string.match
local insert = table.insert
local concat = table.concat
local client = {}
local http_agent = format("user-agent: Silly/%s", core.version)
local parseurl = helper.parseurl

local function send_request(sock, method, host, abs, header, body)
	local tmp
	local buf = {
		format("%s %s HTTP/1.1", method, abs),
		nil,nil,nil,nil,nil,
	}
	if header then
		if not header.host then
			buf[#buf + 1] = format("host: %s", host)
		end
		if not header['user-agent'] then
			buf[#buf + 1] = http_agent
		end
		for k, v in pairs(header) do
			buf[#buf + 1] = format("%s: %s", k, v)
	end
	else
		buf[#buf + 1] = format("host: %s", host)
		buf[#buf + 1] = http_agent
	end
	if body then
		buf[#buf + 1] = format("content-length: %d", #body)
		buf[#buf + 1] = ""
		buf[#buf + 1] = body
	else
		buf[#buf + 1] = "\r\n"
	end
	tmp = concat(buf, "\r\n")
	sock:write(tmp)
end

local function process(method, uri, header, body)
	local scheme, host, port, path, default = parseurl(uri)
	local sock = stream.connect(scheme, host, port)
	if not sock then
		return nil
	end
	if not default then
		host = format("%s:%s", host, port)
	end
	send_request(sock, method, host, path, header, body)
	local first, res = sock:recvrequest()
	if not first then	--disconnected
		return nil
	end
	if res.status ~= 200 then
		return res
	end
	local ver, status= first:match("HTTP/([%d|.]+)%s+(%d+)")
	res.version = ver
	res.status = tonumber(status)
	return res
end

local function request(method, uri, header, data)
	if method == 'GET' and data then
		local buf = helper.urlencode(data)
		if uri:find("?", 1, true) then
			uri = uri .. "&" .. buf
		else
			uri = uri .. "?" .. buf
		end
		data = nil
	end
	return process(method, uri, header, data)
end

client.request = request

function client.GET(uri, header, param)
	local res = request("GET", uri, header, param)
	if res then
		res.sock:close()
		res.sock = nil
	end
	return res
end

function client.POST(uri, header, body)
	local res = request("POST", uri, header, body)
	if res then
		res.sock:close()
		res.sock = nil
	end
	return res
end

return client

