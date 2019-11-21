local core = require "sys.core"
local stream = require "http.stream"
local helper = require "http.helper"
local assert = assert
local tonumber = tonumber
local format = string.format
local match = string.match
local insert = table.insert
local concat = table.concat
local client = {}
local http_agent = format("User-Agent: Silly/%s", core.version)
local function parseurl(url)
	local default = false
	local scheme, host, port, path= match(url, "(http[s]-)://([^:/]+):?(%d*)(.*)")
	if path == "" then
		path = "/"
	end
	if port == "" then
		if scheme == "https" then
			port = "443"
		elseif scheme == "http" then
			port = "80"
		else
			assert(false, "unsupport parse url scheme:" .. scheme)
		end
		default = true
	end
	return scheme, host, port, path, default
end

local function send_request(sock, method, host, abs, header, body)
	local tmp
	insert(header, 1, format("%s %s HTTP/1.1", method, abs))
	insert(header, format("Host: %s", host))
	insert(header, format("Content-Length: %d", #body))
	insert(header, http_agent)
	insert(header, "Connection: keep-alive")
	insert(header, "")
	insert(header, body)
	tmp = concat(header, "\r\n")
	sock:write(tmp)
end

local function process(method, uri, header, body)
	local scheme, host, port, path, default = parseurl(uri)
	local sock = stream.connect(scheme, host, port)
	if not sock then
		return nil
	end
	if not header then
		header = {}
	end
	body = body or ""
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

