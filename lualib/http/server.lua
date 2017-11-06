local core = require "sys.core"
local socket = require "sys.socket"
local stream = require "http.stream"

local server = {}

local listen = socket.listen
local readline = socket.readline
local read = socket.read
local write = socket.write

local http_err_msg = {
	[100] = "Continue",
	[101] = "Switching Protocols",
	[102] = "Processing",
	[200] = "OK",
	[201] = "Created",
	[202] = "Accepted",
	[203] = "Non-authoritative Information",
	[204] = "No Content",
	[205] = "Reset Content",
	[206] = "Partial Content",
	[207] = "Multi-Status",
	[208] = "Already Reported",
	[226] = "IM Used",
	[300] = "Multiple Choices",
	[301] = "Moved Permanently",
	[302] = "Found",
	[303] = "See Other",
	[304] = "Not Modified",
	[305] = "Use Proxy",
	[307] = "Temporary Redirect",
	[308] = "Permanent Redirect",
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[402] = "Payment Required",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[406] = "Not Acceptable",
	[407] = "Proxy Authentication Required",
	[408] = "Request Timeout",
	[409] = "Conflict",
	[410] = "Gone",
	[411] = "Length Required",
	[412] = "Precondition Failed",
	[413] = "Payload Too Large",
	[414] = "Request-URI Too Long",
	[415] = "Unsupported Media Type",
	[416] = "Requested Range Not Satisfiable",
	[417] = "Expectation Failed",
	[418] = "I'm a teapot",
	[421] = "Misdirected Request",
	[422] = "Unprocessable Entity",
	[423] = "Locked",
	[424] = "Failed Dependency",
	[426] = "Upgrade Required",
	[428] = "Precondition Required",
	[429] = "Too Many Requests",
	[431] = "Request Header Fields Too Large",
	[451] = "Unavailable For Legal Reasons",
	[499] = "Client Closed Request",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[502] = "Bad Gateway",
	[503] = "Service Unavailable",
	[504] = "Gateway Timeout",
	[505] = "HTTP Version Not Supported",
	[506] = "Variant Also Negotiates",
	[507] = "Insufficient Storage",
	[508] = "Loop Detected",
	[510] = "Not Extended",
	[511] = "Network Authentication Required",
	[599] = "Network Connect Timeout Error",
}

local function parse_uri(str)
	local form = {}
	local start = string.find(str, "?", 1, true)
	if not start then
		return str, form
	end
	assert(start > 1)
	local uri = string.sub(str, 1, start - 1)
	local f = string.sub(str, start + 1)
	for k, v in string.gmatch(f, "([^=&]+)=([^&]+)") do
		form[k] = v
	end
	return uri, form
end

local function httpd(fd, handler)
	socket.limit(fd, 1024 * 512)
	local readl = function()
		return readline(fd, "\r\n")
	end

	local readn = function(n)
		return read(fd, n)
	end

	local write = function (status, header, body)
		server.send(fd, status, header, body)
	end
	local pcall = core.pcall
	while true do
		local status, first, header, body = stream.recv_request(readl, readn)
		if not status then	--disconnected
			return
		end
		if status ~= 200 then
			write(status, {}, "")
			socket.close(fd)
			return
		end

		--request line
		local method, uri, ver = first:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
		assert(method and uri and ver)
		header.method = method
		header.version = ver
		header.uri, header.form = parse_uri(uri)

		if tonumber(ver) > 1.1 then
			write(505, {}, "")
			socket.close(fd)
			return
		end

		if header["Content-Type"] == "application/x-www-form-urlencoded" then
			for k, v in string.gmatch(body, "(%w+)=(%w+)") do
				header.form[k] = v
			end
			body = ""
		end
		local ok, err = pcall(handler, header, body, write)
		if not ok then
			core.log(err)
			socket.close(fd)
			return
		end
		if header["Connection"] == "close" then
			socket.close(fd)
			return
		end
	end
end

function server.listen(port, handler)
	local h = function(fd)
		httpd(fd, handler)
	end
	listen(port, h)
end

function server.send(fd, status, header, body)
	table.insert(header, 1, string.format("HTTP/1.1 %d %s", status, http_err_msg[status]))
	table.insert(header, string.format("Content-Length: %d", #body))
	local tmp = table.concat(header, "\r\n")
	tmp = tmp .. "\r\n\r\n"
	tmp = tmp .. body
	write(fd, tmp)
end


return server

