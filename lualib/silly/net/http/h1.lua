local silly = require "silly"
local buffer = require "silly.adt.buffer"
local helper = require "silly.net.http.helper"
local logger = require "silly.logger"
local statusname = require "silly.net.http.statusname"
local type = type
local assert = assert
local tonumber = tonumber
local lower = string.lower
local format = string.format
local setmetatable = setmetatable
local parsetarget = helper.parsetarget

local M = {}

--- @class silly.net.http.h1.stream
--- connection
--- @field remoteaddr string
--- @field conn silly.net.tcp.conn|silly.net.tls.conn
--- protocol
--- @field version string
--- @field method string
--- @field path string
--- @field keepalive boolean
--- read fields
--- @field header table<string, string>
--- @field trailer table<string, string>
--- @field package readexpect integer|string
--- @field package recvbuf silly.adt.buffer
--- @field package recvbytes integer
--- write fields
--- @field package sendbuf string[]
--- @field package sendsize integer
--- @field package writeheader table<string, string>?
--- @field package writeexpect integer|string
--- @field package writebytes integer
--- @field package writeclosed boolean
--- private fields
--- @field package allowbody boolean
--- @field package eof boolean
--- @field package err string?

--- @class silly.net.http.h1.stream.client : silly.net.http.h1.stream
--- @field scheme string
--- @field status integer?
--- @field package hasresponse boolean
--- @field package release fun(conn: silly.net.tcp.conn|silly.net.tls.conn, broken: boolean)?
local h1c = {}

--- @class silly.net.http.h1.stream.server : silly.net.http.h1.stream
--- @field query table<string, string>?
local h1s = {}

local request_line<const> = "%s %s HTTP/1.1\r\n"
local chunked<const> = "chunked"
local eof<const> = "eof"
local response_line = setmetatable({}, {__index = function(t, k)
	local v = format("HTTP/1.1 %d %s\r\n", k, statusname[k])
	t[k] = v
	return v
end})

local valid_methods = {
	["GET"] = true,
	["POST"] = true,
	["PUT"] = true,
	["DELETE"] = true,
	["OPTIONS"] = true,
	["HEAD"] = true,
	["CONNECT"] = true,
}

-- RFC 9112: Methods whose request never has a body
local bodyless_request = {
	["GET"] = true,
	["HEAD"] = true,
	["DELETE"] = true,
	["CONNECT"] = true,
}

local function bodyless_response(method, status)
	-- RFC 9112:
	-- Status codes that never have a response body
	-- Methods whose response never has a body
	return (method == "HEAD" or status == 204 or status == 304 or status // 100 == 1) or
		(method == "CONNECT" and status >= 200 and status < 300)
end

local function compose_header(buf, header)
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

---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param header table<string, string|string[]>
---@param timeout integer? -- ms
---@return boolean, string?
local function readheader(conn, header, timeout)
	local tmp, err = conn:read("\n", timeout)
	if not tmp then
		return false, err
	end
	if #tmp == 0 then
		return false, "broken header"
	end
	while tmp ~= "\r\n" do
		local k, v = tmp:match("^(%S+):%s*(.-)%s*$")
		if not k then
			return false, "invalid header"
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
		tmp, err = conn:read("\n", timeout)
		if err then
			return false, err
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
	return true, nil
end

---@param s silly.net.http.h1.stream
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param timeout integer?
---@return number?, string? error
local function read_chunk(s, conn, timeout)
	local line, err = conn:read("\n", timeout)
	if err then
		return nil, err
	end
	local hex = line:match("^([0-9A-Fa-f]+)")
	local sz = tonumber(hex, 16)
	if not sz then
		local err = "invalid chunk size"
		return nil, err
	end
	if sz == 0 then
		-- read trailer
		local ok, err = readheader(conn, s.trailer, timeout)
		if not ok then
			return nil, err
		end
		s.eof = true
		return s.recvbuf:size(), nil
	end
	local dat, err = conn:read(sz, timeout)
	if err then
		return nil, err
	end
	local crlf, err = conn:read(2, timeout)
	if crlf ~= "\r\n" then
		local err = "invalid chunk ending"
		return nil, err
	end
	s.recvbytes = s.recvbytes + sz
	return s.recvbuf:append(dat), nil
end

---@param s silly.net.http.h1.stream
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param bytes integer
---@param timeout integer?
---@return number?, string? error
local function read_eof(s, conn, bytes, timeout)
	local b, err = conn:read(bytes, timeout)
	if not b then --we need process eof
		return nil, err
	end
	if #b == 0 then
		bytes = conn:unreadbytes()
		if bytes > 0 then
			b, err = conn:read(bytes, timeout)
			if err then
				return nil, err
			end
		end
		s.eof = true
	end
	local size
	if #b > 0 then
		s.recvbytes = s.recvbytes + #b
		size = s.recvbuf:append(b)
	else
		size = s.recvbuf:size()
	end
	return size, nil
end

---@param s silly.net.http.h1.stream
---@param size integer
---@param timeout integer? --ms
local function read(s, size, timeout)
	local recvbuf = s.recvbuf
	local dat, totalsize = recvbuf:read(size)
	if dat then
		return dat, nil
	end
	local err = s.err
	if err then
		return nil, err
	end
	if s.eof then
		return "", "end of file"
	end
	local conn = s.conn
	local len = s.readexpect
	if len == chunked then
		while totalsize and totalsize < size and not s.eof do
			totalsize, err = read_chunk(s, conn, timeout)
		end
	elseif len == eof then
		totalsize, err = read_eof(s, conn, size - totalsize, timeout)
	elseif len > 0 then
		local left = len - s.recvbytes
		local need = size - totalsize
		if need > left then
			need = left
		end
		totalsize, err = read_eof(s, conn, need, timeout)
		if totalsize and not s.eof then
			s.eof = s.recvbytes == len
		end
	end
	if totalsize then
		if totalsize < size then
			return "", "end of file"
		end
		return recvbuf:read(size), nil
	end
	s.err = err
	return nil, err
end

---@param s silly.net.http.h1.stream
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param len integer
---@param timeout integer? --ms
---@return boolean, string? error
local function read_all_body(s, conn, len, timeout)
	if len == chunked then
		while not s.eof do
			local size, err = read_chunk(s, conn, timeout)
			if not size then
				return false, err
			end
		end
	elseif len == eof then
		while not s.eof do
			local size, err = read_eof(s, conn, 4096, timeout)
			if not size then
				return false, err
			end
		end
	elseif len > 0 then
		local left = len - s.recvbytes
		local size, err = read_eof(s, conn, left, timeout)
		if not size then
			return false, err
		end
		if size < left then
			assert(s.eof)
			return false, "body broken"
		end
		s.eof = true
	end
	return true, nil
end

---@param s silly.net.http.h1.stream
---@param timeout integer? --ms
local function readall(s, timeout)
	local err = s.err
	if err then
		local dat = s.recvbuf:readall()
		if #dat > 0 then
			return dat, nil
		end
		return nil, err
	end
	if s.eof then
		local dat = s.recvbuf:readall()
		return dat, #dat == 0 and "end of file" or nil
	end
	local conn = s.conn
	local len = s.readexpect
	local ok, err = read_all_body(s, conn, len, timeout)
	if not ok then
		s.err = err
		return nil, err
	end
	local dat = s.recvbuf:readall()
	return dat, #dat == 0 and "end of file" or nil
end

---@param s silly.net.http.h1.stream
---@param close boolean
local function flush_header(s, close)
	local header = s.writeheader
	if not header then
		return
	end
	s.writeheader = nil
	local cl = header["content-length"]
	if cl then
		s.writeexpect = tonumber(cl) or 0
	elseif header["transfer-encoding"] == chunked then
		s.writeexpect = chunked
	elseif s.allowbody then
		if close then
			header["content-length"] = "0"
			s.writeexpect = 0
		else
			header["transfer-encoding"] = chunked
			s.writeexpect = chunked
		end
	end
	local buf = s.sendbuf
	compose_header(buf, header)
	buf[#buf + 1] = "\r\n"
end

---@param s silly.net.http.h1.stream
local function flushwrite(s)
	local buf = s.sendbuf
	local n = #buf
	if n == 0 then
		return
	end
	local ok, err = s.conn:write(buf)
	if not ok then -- sliently error
		s.err = err
	end
	s.writebytes = s.writebytes + s.sendsize
	s.sendsize = 0
	for i = 1, n do
		buf[i] = nil
	end
end

---@param s silly.net.http.h1.stream
---@param data string
local function write(s, data)
	local err = s.err
	if err then
		return false, err
	end
	if s.writeclosed then
		return false, "write closed"
	end
	flush_header(s, false)
	local writeexpect = s.writeexpect
	if writeexpect == 0 then
		-- No body expected, writing is an error
		return false, "write not allowed (no body expected)"
	end
	local buf = s.sendbuf
	local size = s.sendsize
	size = size + #data
	if writeexpect == chunked then
		buf[#buf + 1] = format("%x\r\n", #data)
		buf[#buf + 1] = data
		buf[#buf + 1] = "\r\n"
	else
		if size + s.writebytes > writeexpect then
			return false, "write exceed content-length size"
		end
		buf[#buf + 1] = data
	end
	s.sendsize = size
	if size >= 4*1024 then
		flushwrite(s)
	end
	return true, nil
end

---@param s silly.net.http.h1.stream
---@param data string?
---@param trailer table<string, string|string[]>?
local function close_write(s, data, trailer)
	if data then
		write(s, data)
	end
	flush_header(s, true)
	if s.writeexpect == chunked then
		local buf = s.sendbuf
		buf[#buf + 1] = "0\r\n"
		if trailer then
			compose_header(buf, trailer)
		end
		buf[#buf + 1] = "\r\n"
	end
	flushwrite(s)
end

---@param s silly.net.http.h1.stream
local function check_close_error(s)
	local err = s.err
	if err then
		return err
	end
	local writeexpect = s.writeexpect
	if writeexpect ~= chunked then
		if s.writebytes < writeexpect then
			return "write not complete"
		end
	end
	if not s.writeclosed then
		return "writing not closed"
	end
	local readexpect = s.readexpect
	if readexpect == chunked or readexpect == eof then
		if not s.eof then
			return "read not complete"
		end
	else
		if s.recvbytes < readexpect then
			return "read not complete"
		end
	end
	return nil
end

local function newstream(scheme, conn, ver, method, path, header, readexpect)
	---@type silly.net.http.h1.stream
	local stream = {
		--- connection
		conn = conn,
		remoteaddr = conn.remoteaddr,
		--- protocol
		scheme = scheme,
		version = ver,
		method = method,
		path = path,
		keepalive = true,
		--- read fields
		header = header,
		trailer = {},
		recvbuf = buffer.new(),
		readexpect = readexpect,
		recvbytes = 0,
		--- write fields
		sendbuf = {},
		sendsize = 0,
		writeexpect = 0,
		writebytes = 0,
		writeclosed = false,
		--- misc
		allowbody = false,
		eof = false,
		err = nil,
	}
	return stream
end

-------------------------------------client

---@param s silly.net.http.h1.stream.client
---@param timeout integer?
local function waitresponse(s, timeout)
	local conn = s.conn
	local first, err = conn:read("\n", timeout)
	if err then
		return false, err
	end
	local ok, err = readheader(conn, s.header, timeout)
	if not ok then
		return false, err
	end
	local ver, status = first:match("HTTP/([%d|.]+)%s+(%d+)")
	if not ver or not status then
		return false, "invalid response line"
	end
	status = tonumber(status)
	s.version = ver
	s.status = status
	-- RFC 9112: Determine if response has a body
	local nobody = bodyless_response(s.method, status)
	if not nobody then
		local header = s.header
		local cl = header["content-length"]
		if cl then
			local n = tonumber(cl)
			if not n or n < 0 then
				return false, "invalid content-length"
			end
			s.readexpect = n
		elseif header["transfer-encoding"] == chunked then
			s.readexpect = chunked
		else
			-- RFC 9112: No Content-Length and no chunked, read until EOF
			s.readexpect = eof
		end
	else
		-- No body expected
		s.readexpect = 0
		s.eof = true
	end
	return true, nil
end

---@param s silly.net.http.h1.stream.client
---@param method string
---@param path string
---@param header table<string, string>
---@return boolean, string?
function h1c.request(s, method, path, header)
	s.method = method
	s.path = path
	s.keepalive = header["connection"] ~= "close"
	local buf = s.sendbuf
	buf[#buf + 1] = format(request_line, method, path)
	s.writeheader = header
	s.allowbody = not bodyless_request[method]
	local expect = header["expect"]
	local expect100 = expect and lower(expect) == "100-continue"
	if expect100 then
		flush_header(s, false)
		flushwrite(s)
		local ok, err = waitresponse(s)
		if not ok then
			s.err = err
			return false, err
		end
		if s.status ~= 100 then
			s.hasresponse = true
		end
	end
	return true, nil
end

---@param s silly.net.http.h1.stream.client
---@param timeout integer? --ms
---@return boolean, string? error
local function client_waitresponse(s, timeout)
	if s.hasresponse then
		return true, nil
	end
	s.hasresponse = true
	local err = s.err
	if err then
		return false, err
	end
	local ok, err = waitresponse(s, timeout)
	if not ok then
		s.err = err
	end
	return ok, err
end

h1c.waitresponse = client_waitresponse

---@param s silly.net.http.h1.stream.client
---@param size integer
---@param timeout integer? --ms
---@return string?, string? error
function h1c.read(s, size, timeout)
	if not s.writeclosed then
		return nil, "should closewirte first"
	end
	local ok, err = client_waitresponse(s, timeout)
	if not ok then
		return nil, err
	end
	return read(s, size, timeout)
end

---@param s silly.net.http.h1.stream.client
---@param timeout integer? --ms
---@return string?, string? error
function h1c.readall(s, timeout)
	if not s.writeclosed then
		return nil, "should closewirte first"
	end
	local ok, err = client_waitresponse(s, timeout)
	if not ok then
		return nil, err
	end
	return readall(s, timeout)
end

---@param s silly.net.http.h1.stream.client
---@param data string
---@return boolean, string? error
function h1c.write(s, data)
	if s.writeclosed then
		return false, "write closed"
	end
	return write(s, data)
end

---@param s silly.net.http.h1.stream.client
---@param data string?
---@param trailer table<string, string|string[]>|nil
function h1c.closewrite(s, data, trailer)
	if s.writeclosed then
		return
	end
	close_write(s, data, trailer)
	s.writeclosed = true
end

function h1c.flush(s)
	flush_header(s, false)
	flushwrite(s)
end

---@param s silly.net.http.h1.stream.client
function h1c.close(s)
	local conn = s.conn
	if not conn then
		return
	end
	s.conn = nil
	local release = s.release
	if not release then
		conn:close()
		return
	end
	local err = check_close_error(s)
	local broken = err or
		s.method == "CONNECT" or
		s.readexpect == eof or
		(not s.keepalive) or
		(s.header and s.header["connection"] == "close")
	release(conn, broken)
end

local h1c_mt = {
	__index = h1c,
	__gc = function(s)
		local conn = s.conn
		if conn then
			s.conn = nil
			s.release(conn, true)
		end
	end,
	__close = h1c.close,
}

---@param scheme string
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param release fun(conn: silly.net.tcp.conn|silly.net.tls.conn, broken: boolean)?
---@return silly.net.http.h1.stream.client
function M.newstream(scheme, conn, release)
	local s = newstream(scheme, conn, "HTTP/1.1", "", "", {}, 0)
	---@cast s silly.net.http.h1.stream.client
	s.release = release
	s.status = nil
	s.hasresponse = false
	setmetatable(s, h1c_mt)
	return s
end

----------------server

---@param s silly.net.http.h1.stream.server
---@param status integer
---@param header table<string, string>
function h1s.respond(s, status, header)
	local buf = s.sendbuf
	buf[#buf + 1] = response_line[status]
	s.writeheader = header
	local nobody = bodyless_response(s.method, status)
	s.allowbody = not nobody
	if nobody then
		header["content-length"] = nil
		header["transfer-encoding"] = nil
	end
end

h1s.read = read
h1s.readall = readall

---@param s silly.net.http.h1.stream.server
function h1s.write(s, data)
	if s.writeclosed then
		return false, "write closed"
	end
	return write(s, data)
end

---@param s silly.net.http.h1.stream.server
function h1s.flush(s)
	flush_header(s, false)
	flushwrite(s)
end

local function server_closewrite(s, data, trailer)
	if s.writeclosed then
		return
	end
	close_write(s, data, trailer)
	s.writeclosed = true
end

h1s.closewrite = server_closewrite

local h1s_mt = {
	__index = h1s,
	__gc = function(s)
		local conn = s.conn
		if conn then
			s.conn = nil
			conn:close()
		end
	end,
}

local err_400 = response_line[400] .. "\r\n"
local err_405 = response_line[405] .. "\r\n"

---@param handler fun(s: silly.net.http.h1.stream.server)
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param scheme string
function M.httpd(handler, conn, scheme)
	local pcall = silly.pcall
	while true do
		local first, err = conn:read("\n")
		if err then
			break
		end
		local header = {}
		local ok, err = readheader(conn, header)
		if not ok then
			-- RFC 9112: Send 400 Bad Request for malformed headers
			conn:write(err_400)
			break
		end
		local err
		---@type string|number
		local len = header["content-length"]
		if len then
			len = tonumber(len)
			if not len or len < 0 then
				-- RFC 9112: Invalid Content-Length (not a number or negative)
				conn:write(err_400)
				break
			end
		elseif header["transfer-encoding"] == chunked then
			len = chunked
		else
			-- RFC 9112: No Content-Length and no Transfer-Encoding means no body
			len = 0
		end
		--request line
		local method, target, ver =
		    first:match("(%w+)%s+(.-)%s+HTTP/([%d|.]+)\r\n")
		if not valid_methods[method] then
			-- RFC 9112: Send 405 Method Not Allowed for invalid method
			conn:write(err_405)
			break
		end
		if not target or not ver then
			-- RFC 9112: Send 400 Bad Request for malformed request line
			conn:write(err_400)
			break
		end
		if tonumber(ver) > 1.1 then
			conn:write(err_405)
			break
		end
		local path, query = parsetarget(target)
		---@type silly.net.http.h1.stream.server
		local stream = newstream(scheme, conn, ver, method, path, header, len)
		---@cast stream silly.net.http.h1.stream.server
		stream.query = query
		setmetatable(stream, h1s_mt)
		local ok, err = pcall(handler, stream)
		if not ok then
			stream.conn = nil
			logger.error(err)
			break
		end
		server_closewrite(stream)
		if check_close_error(stream) then
			stream.conn = nil
			break
		end
		if header["connection"] == "close" then
			stream.conn = nil
			break
		end
		-- prevent stream gc to close the connection
		stream.conn = nil
	end
	conn:close()
end

return M

