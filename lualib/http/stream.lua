local tcp = require "sys.net.tcp"
local dns = require "sys.dns"
local tls = require "sys.tls"
local tonumber = tonumber
local format = string.format
local setmetatable = setmetatable
local M = {}

local function readheader(sock)
	local header = {}
	local tmp = sock:readline()
	if not tmp then
		return nil
	end
	while tmp ~= "\r\n" do
		local k, v = tmp:match("([^:]+):%s*(.+)\r\n")
		k = k:lower(k)
		if header[k] then
			header[k] = header[k] .. ";" .. v
		else
			header[k] = v
		end
		tmp = sock:readline()
		if not tmp then
			return nil
		end
	end
	return header
end

local function read_body(hdr, sock)
	local body
	local encoding = hdr["transfer-encoding"]
	if encoding then
		if encoding ~= "chunked" then
			return 501
		end
		body = ""
		while true do
			local n = sock:readline()
			local sz = tonumber(n, 16)
			if not sz or sz == 0 then
				break
			end
			body = body .. sock:read(sz)
			sock:readline()
		end
	else
		local len = hdr["content-length"]
		if len then
			local len = tonumber(len)
			body = sock:read(len)
		end
	end
	return 200, body
end

local function read_multipart_formdata(boundary, sock)
	local files = {}
	local boundary_start = "--" .. boundary
	local trunc = -#boundary_start-1-2
	local l = sock:readline()
	repeat
		local hdr = readheader(sock)
		local body = sock:readline(boundary_start)
		local term = sock:readline("\r\n")
		files[#files + 1] = {
			header = hdr,
			content = body:sub(1, trunc)
		}
	until term == '--\r\n'
	return 200, files
end

local function recv_request(sock)
	local status, body
	local first = sock:readline()
	local header = readheader(sock)
	if not header then
		return nil, nil
	end
	local typ = header["content-type"]
	if typ and typ:find("multipart/form-data", 1, true) then
		local bd = typ:match("boundary=([%w-]+)")
		status, body = read_multipart_formdata(bd, sock)
	else
		status, body = read_body(header, sock)
	end
	local res = {
		sock = sock,
		status = status,
		header = header,
		body = body,
	}
	return first, res
end

local function wrap_one(func)
	return function(self, x)
		local fd = self[1]
		if fd then
			return func(fd, x)
		else
			return false
		end
	end
end

local function wrap_close(func)
	return function(self)
		local ok = false
		local fd = self[1]
		if fd then
			ok = func(fd)
			self[1] = nil
		end
		return ok
	end
end

local function gc(self)
	self:close()
end

local tls_mt = {
	close = wrap_close(tls.close),
	read = wrap_one(tls.read),
	write = wrap_one(tls.write),
	readline = wrap_one(tls.readline),
	recvrequest = recv_request,
	__gc = gc,
	__index = nil,
}

local tcp_mt = {
	close = wrap_close(tcp.close),
	read = wrap_one(tcp.read),
	write = wrap_one(tcp.write),
	readline = wrap_one(tcp.readline),
	recvrequest = recv_request,
	__gc = gc,
	__index = nil,
}

tls_mt.__index = tls_mt
tcp_mt.__index = tcp_mt

local scheme_io = {
	["https"] = tls_mt,
	["wss"] = tls_mt,
	["http"] = tcp_mt,
	["ws"] = tcp_mt,
}

local scheme_connect = {
	["https"] = tls.connect,
	["wss"] = tls.connect,
	["http"] = tcp.connect,
	["ws"] = tcp.connect,
}

function M.accept(scheme, fd)
	--NOTE: use `{fd}` but not `{fd=fd}`
	--because array cost less memory
	return setmetatable({fd}, scheme_io[scheme])
end

function M.connect(scheme, host, port)
	local ip = dns.lookup(host, dns.A)
	assert(ip, host)
	local ip = format("%s:%s", ip, port)
	local fd = scheme_connect[scheme](ip, nil, host)
	if not fd then
		return nil
	end
	--NOTE: use `{fd}` but not `{fd=fd}`
	--because array cost less memory
	return setmetatable({fd}, scheme_io[scheme])
end

return M

