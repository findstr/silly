local core = require "sys.core"
local socket = require "sys.socket"
local ssl = require "sys.netssl"
local stream = require "http.stream"
local dns = require "sys.dns"
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

local function send_request(io_do, fd, method, host, abs, header, body)
	local tmp
	insert(header, 1, format("%s %s HTTP/1.1", method, abs))
	insert(header, format("Host: %s", host))
	insert(header, format("Content-Length: %d", #body))
	insert(header, http_agent)
	insert(header, "Connection: keep-alive")
	insert(header, "")
	insert(header, body)
	tmp = concat(header, "\r\n")
	io_do.write(fd, tmp)
end

local function recv_response(io_do, fd)
	local readl = io_do.readline
	local readn = io_do.read
	local status, first, header, body = stream.readrequest(fd, readl, readn)
	if not status then	--disconnected
		return nil
	end
	if status ~= 200 then
		return status
	end
	local ver, status= first:match("HTTP/([%d|.]+)%s+(%d+)")
	return tonumber(status), header, body, ver
end

local function process(uri, method, header, body)
	local ip, io_do
	local scheme, host, port, path, default = parseurl(uri)
	ip = dns.resolve(host, "A")
	assert(ip, host)
	if scheme == "https" then
		io_do = ssl
	elseif scheme == "http" then
		io_do = socket
	end
	if not default then
		host = format("%s:%s", host, port)
	end
	ip = format("%s:%s", ip, port)
	local fd = io_do.connect(ip)
	if not fd then
		return 599
	end
	if not header then
		header = {}
	end
	body = body or ""
	send_request(io_do, fd, method, host, path, header, body)
	local status, header, body, ver = recv_response(io_do, fd)
	io_do.close(fd)
	return status, header, body, ver
end

function client.GET(uri, header)
	return process(uri, "GET", header)
end

function client.POST(uri, header, body)
	return process(uri, "POST", header, body)
end

return client

