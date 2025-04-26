local core = require "core"
local helper = require "core.http.helper"
local logger = require "core.logger"
local statusname = require "core.http.statusname"
local type = type
local tonumber = tonumber
local lower = string.lower
local format = string.format
local gmatch = string.gmatch
local concat = table.concat
local setmetatable = setmetatable
local parsetarget = helper.parsetarget

local M = {}

local request_line<const> = "%s %s HTTP/1.1\r\n"
local response_line<const> = "HTTP/1.1 %d %s\r\n"
local chunked<const> = "chunked"
local fmt_urlencoded<const> = "application/x-www-form-urlencoded"
local valid_methods = {
	["GET"] = true,
	["POST"] = true,
	["PUT"] = true,
	["DELETE"] = true,
	["OPTIONS"] = true,
}

---@param fd integer
---@param readline fun(fd: integer, delim: string?): string|nil, string?
---@return table<string, string>|nil, string?
local function readheader(fd, readline)
	local header = {}
	local tmp, err = readline(fd)
	if not tmp then
		return nil, err
	end
	while tmp ~= "\r\n" do
		local k, v = tmp:match("^(%S+):%s*(.-)%s*$")
		if not k then
			return nil, "invalid header"
		end
		k = lower(k)
		local value = header[k]
		if value then
			if type(value) == "string" then
				header[k] = {value, v}
			else
				value[#value + 1] = v
			end
		else
			header[k] = v
		end
		tmp, err = readline(fd)
		if not tmp then
			return nil, err
		end
	end
	--[[
	According to RFC 9112, "If a message is received with both a
	Transfer-Encoding and a Content-Length header field, the Transfer-Encoding
	overrides the Content-Length. Such a message might indicate an attempt to
	perform request smuggling (Section 11.2) or response splitting (Section 11.1)
	and ought to be handled as an error. An intermediary that chooses to forward
	the message MUST first remove the received Content-Length field and process
	the Transfer-Encoding (as described below) prior to forwarding the message downstream.
	]]
	if header["transfer-encoding"] then
		header["content-length"] = nil
	end
	return header, nil
end

---@param fd integer
---@param  transport core.net.tcp|core.net.tls
---@return string?, string? error
local function read_chunk(fd, transport)
	local readline = transport.readline
	local n, err = readline(fd)
	if not n then
		return nil, err
	end
	local sz = tonumber(n, 16)
	if not sz or sz == 0 then
		return "", "EOF"
	end
	local dat, err = transport.read(fd, sz)
	if not dat then
		return nil, err
	end
	readline(fd)
	return dat, nil
end

---@param fmt string
---@param arg1 integer|string
---@param arg2 integer|string
---@param header table<string, string>?
---@return string
local function compose(fmt, arg1, arg2, header)
	local first = format(fmt, arg1, arg2)
	local buf = {first, nil, nil, nil, nil, nil}
	if header then
		for k, v in pairs(header) do
			if type(v) == "table" then
				for _, vv in ipairs(v) do
					buf[#buf + 1] = k
					buf[#buf + 1] = ": "
					buf[#buf + 1] = vv
					buf[#buf + 1] = "\r\n"
				end
			else
				buf[#buf + 1] = k
				buf[#buf + 1] = ": "
				buf[#buf + 1] = v
				buf[#buf + 1] = "\r\n"
			end
		end
	end
	buf[#buf + 1] = "\r\n"
	return concat(buf)
end

--- @class core.http.h1stream_mt
local stream_mt = {
	---@overload fun(s: core.http.h1stream, method: string, path: string, header: table<string, string>, _:boolean): boolean, string?
	request = function(s, method, path, header)
		s.method = method
		local hdr = compose(request_line, method, path, header)
		return s.transport.write(s.fd, hdr)
	end,
	respond =function(s, status, header, close)
		local hdr = compose(response_line, status, statusname[status], header)
		local fd = s.fd
		local transport = s.transport
		local ok, err = transport.write(fd, hdr)
		if close then
			s.fd = nil
			transport.close(fd)
		end
		return ok, err
	end,
	---@param s core.http.h1stream
	readheader = function(s)
		local fd = s.fd
		local readline = s.transport.readline
		local first, err = readline(fd)
		if not first then
			return nil, err
		end
		local header, err = readheader(fd, readline)
		if not header then
			return nil, err
		end
		local ver, status = first:match("HTTP/([%d|.]+)%s+(%d+)")
		status = tonumber(status)
		s.version = ver
		s.header = header
		if header["content-length"] then
			local len = tonumber(header["content-length"])
			s.contentlength = len
			s.eof = len == 0
		elseif header["transfer-encoding"] == chunked then
			s.contentlength = chunked
		else
			s.eof = true
		end
		return tonumber(status), header
	end,
	readtrailer = function(s)
		--TODO: don't implement
		return nil
	end,
	read = function(s)
		if s.eof then
			return "", "EOF"
		end
		local fd = s.fd
		local transport = s.transport
		local contentlength = s.contentlength
		if not contentlength then
			return "", "no body"
		end
		if contentlength == chunked then
			local dat, err = read_chunk(fd, transport)
			s.eof = not dat or #dat == 0
			return dat, err
		end
		-- there two conditions:
		-- first it read all body data,
		-- second the connections is broken
		s.eof = true
		local body, err = transport.read(fd, contentlength)
		if not body then
			return "", err
		end
		return body, nil
	end,
	readall = function(s)
		if s.eof then
			return "", "EOF"
		end
		local contentlength = s.contentlength
		if not contentlength then
			return "", "no body"
		end
		if contentlength == chunked then
			local buf = {}
			repeat
				local dat, err = s:read()
				if not dat then
					return nil, err
				end
				buf[#buf + 1] = dat
			until s.eof
			return concat(buf), nil
		end
		return s:read()
	end,
	write = function(s, data)
		return s.transport.write(s.fd, data)
	end,
	writechunk = function(s, data)
		local header = format("%x\r\n", #data)
		local body = header .. data .. "\r\n"
		return s.transport.write(s.fd, body)
	end,
	close = function(s, data)
		local fd = s.fd
		if fd then
			s.fd = nil
			local transport = s.transport
			if data then
				transport.write(fd, data)
			end
			return transport.close(fd)
		end
	end,
	__index = nil,
	---@param s core.http.h1stream
	__close = function(s)
		s:close()
	end,
}

stream_mt.__index = stream_mt

--- @class core.http.h1stream:core.http.h1stream_mt
--- @field fd integer
--- @field remoteaddr string
--- @field transport core.net.tcp|core.net.tls
--- @field version string
--- @field header table<string, string>?
--- @field scheme string
--- @field eof boolean
--- @field method string?
--- @field path string?
--- @field query table<string, string>?
--- @field contentlength integer|string|nil

---@param scheme string
---@param fd integer
---@param transport core.net.tcp|core.net.tls
---@return core.http.h1stream
function M.new(scheme, fd, transport, addr)
	return setmetatable({
		fd = fd,
		remoteaddr = addr,
		transport = transport,
		version = "HTTP/1.1",
		header = nil,
		scheme = scheme,
		method = nil,
		path = nil,
		query = nil,
		contentlength = nil,
		eof = false,
	}, stream_mt)
end

function M.httpd(handler, fd, transport, addr)
	local pcall = core.pcall
	local write = transport.write
	local readline = transport.readline
	while true do
		local first, err = readline(fd)
		if not first then
			break
		end
		local header, _ = readheader(fd, readline)
		if not header then
			local dat = compose(response_line, 400, statusname[400])
			write(fd, dat)
			break
		end
		local eof = false
		---@type string|number
		local contentlength = header["content-length"]
		if contentlength then
			contentlength = tonumber(contentlength)
			if not contentlength then
				local dat = compose(response_line, 400, statusname[400])
				write(fd, dat)
				break
			end
			eof = contentlength == 0
		elseif header["transfer-encoding"] == chunked then
			contentlength = chunked
		end
		--request line
		local method, target, ver =
		    first:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
		if not valid_methods[method] then
			write(fd, compose(response_line, 405, statusname[405]))
			break
		end
		if not target or not ver then
			write(fd, compose(response_line, 400, statusname[400]))
			break
		end
		local path, query = parsetarget(target)
		local stream = setmetatable({
			fd = fd,
			transport = transport,
			method = method,
			version = ver,
			path = path,
			header = header,
			query = query,
			remoteaddr = addr,
			contentlength= contentlength,
			eof = eof,
		}, stream_mt)
		if tonumber(ver) > 1.1 then
			stream:respond(505, {}, "")
			break
		end
		if header["content-type"] == fmt_urlencoded then
			local body, err = stream:readall()
			if not body then
				logger.error(err)
				break
			end
			for k, v in gmatch(body, "(%w+)=([^%s&]+)") do
				query[k] = v
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
	transport.close(fd)
end

return M

