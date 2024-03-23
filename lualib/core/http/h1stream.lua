local core = require "core"
local helper = require "core.http.helper"
local time = require "core.time"
local logger = require "core.logger"
local statusname = require "core.http.statusname"
local tonumber = tonumber
local format = string.format
local gmatch = string.gmatch
local concat = table.concat
local setmetatable = setmetatable
local parseuri = helper.parseuri
local M = {}

local fmt_urlencoded<const> = "application/x-www-form-urlencoded"

local function readheader(sock)
	local header = {}
	local tmp, err = sock:readline()
	if not tmp then
		return nil, err
	end
	while tmp ~= "\r\n" do
		local k, v = tmp:match("([^:]+):%s*(.+)\r\n")
		k = k:lower(k)
		if header[k] then
			header[k] = header[k] .. ";" .. v
		else
			header[k] = v
		end
		tmp, err = sock:readline()
		if not tmp then
			return nil, err
		end
	end
	return header, nil
end

local function read_body(hdr, sock)
	local body = ""
	local encoding = hdr["transfer-encoding"]
	if encoding then
		if encoding ~= "chunked" then
			return nil, "not support encodeing:" .. encoding
		end
		local buf = {}
		while true do
			local now = time.now()
			local n = sock:readline()
			local sz = tonumber(n, 16)
			if not sz or sz == 0 then
				break
			end
			local dat, err = sock:read(sz)
			if not dat then
				return nil, err
			end
			buf[#buf + 1] = dat
			sock:readline()
		end
		body = concat(buf)
	elseif hdr["content-type"] ~= fmt_urlencoded then
		local len = hdr["content-length"]
		if len then
			local len = tonumber(len)
			body = sock:read(len)
		end
	end
	return body, nil
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
	return files, nil
end

local function compose_request(method, path, header)
	local buf = {
		format("%s %s HTTP/1.1", method, path),
		nil,nil,nil,nil,nil,
	}
	for k, v in pairs(header) do
		buf[#buf + 1] = format("%s: %s", k, v)
	end
	buf[#buf + 1] = "\r\n"
	return concat(buf, "\r\n")
end

local function compose_response(status, header)
	local buf = {
		format("HTTP/1.1 %d %s", status, statusname[status])
	}
	if header then
		for k, v in pairs(header) do
			buf[#buf + 1] = format("%s: %s", k, v)
		end
	end
	buf[#buf + 1] = "\r\n"
	return concat(buf, "\r\n")
end

local stream_mt = {
	request = function(s, method, path, header)
		local hdr = compose_request(method, path, header)
		return s.sock:write(hdr)
	end,
	respond =function(s, status, header, close)
		local hdr = compose_response(status, header)
		local ok, err = s.sock:write(hdr)
		if close then
			s.sock:close()
		end
		return ok, err
	end,
	readheader = function(s)
		local sock = s.sock
		local first, err = sock:readline()
		if not first then
			return nil, err
		end
		local header, err = readheader(sock)
		if not header then
			return nil, err
		end
		local ver, status= first:match("HTTP/([%d|.]+)%s+(%d+)")
		s.version = ver
		s.header = header
		return tonumber(status), header
	end,
	read = function(s)
		local sock = s.sock
		local header = s.header
		local typ = header["content-type"]
		local body, err
		if typ and typ:find("multipart/form-data", 1, true) then
			local bd = typ:match("boundary=([%w-]+)")
			body, err = read_multipart_formdata(bd, sock)
		else
			body, err = read_body(header, sock)
		end
		return body, err
	end,
	readall = nil,
	write = function(s, data)
		return s.sock:write(data)
	end,
	close = function(s, data)
		if data then
			s.sock:write(data)
		end
		return s.sock:close()
	end,
	socket = function(s)
		return s.sock
	end,
	__index = nil
}
stream_mt.readall = stream_mt.read
stream_mt.__index = stream_mt

function M.new(socket)
	return setmetatable({
		sock = socket,
		version = "HTTP/1.1",
		header = false,
	}, stream_mt)
end

function M.httpd(handler)
	return function(socket, addr)
		local pcall = core.pcall
		while true do
			local first, err = socket:readline()
			if not first then
				break
			end
			local header, err = readheader(socket)
			if not header then
				local dat = compose_response(400, {})
				socket:write(dat)
				break
			end
			--request line
			local method, uri, ver =
			    first:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
			assert(method and uri and ver)
			local path, form = parseuri(uri)
			local stream = setmetatable({
				sock = socket,
				method = method,
				version = ver,
				path = path,
				header = header,
				form = form,
			}, stream_mt)
			if tonumber(ver) > 1.1 then
				stream:respond(505, {}, "")
				break
			end
			if header["content-type"] == fmt_urlencoded then
				local n = header["content-length"]
				local body, _ = socket:read(n)
				if not body then
					break
				end
				for k, v in gmatch(body, "(%w+)=([^%s&]+)") do
					form[k] = v
				end
			end
			local ok, err = pcall(handler, stream)
			if not ok then
				logger.error(err)
				break
			end
			if header["connection"] == "close" then
				break
			end
		end
		socket:close()
	end
end

return M

