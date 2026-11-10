local silly = require "silly"
local base64 = require "silly.encoding.base64"
local sha1 = require "silly.crypto.hash".new("sha1")
local utils = require "silly.crypto.utils"
local random = require "silly.crypto.random"
local url = require "silly.net.http.url"
local dns = require "silly.net.dns"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local h1 = require "silly.net.http.h1"
local addr = require "silly.net.addr"

local type = type
local tostring = tostring
local setmetatable = setmetatable
local pcall = silly.pcall

local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local format = string.format
local utf8len = utf8.len
local xor = utils.xor
local randombytes = random.bytes
local parseurl = url.parse
local join_addr = addr.join

---@class silly.net.websocket
local M = {}
local NIL = ""
local CLOSED<const> = "WebSocket is closed"
local MAX_READ_SIZE<const> = 0x7fffffff
local guid = [[258EAFA5-E914-47DA-95CA-C5AB0DC85B11]]

local data_type = {
	[0] = "continuation",
	[1] = "text",
	[2] = "binary",
	[8] = "close",
	[9] = "ping",
	[10] = "pong",
	["continuation"] = 0,
	["text"] = 1,
	["binary"] = 2,
	["close"] = 8,
	["ping"] = 9,
	["pong"] = 10,
}

local function check_close(data)
	if #data == 1 then
		return "Invalid Close payload", 1002
	end
	if #data >= 2 then
		local code = unpack(">I2", data)
		if not (code >= 1000 and code <= 1003 or code >= 1007 and code <= 1014 or
			code >= 3000 and code <= 4999) then
			return "Invalid Close status", 1002
		end
		if not utf8len(data, 3) then
			return "Invalid Close reason UTF-8", 1007
		end
	end
end

---@param sock silly.net.websocket.socket
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@return integer? fin, integer|string opcode_or_error, string? data, integer? closecode
local function read_frame(sock, conn)
	local tmp, err = conn:read(2)
	if not tmp then
		return nil, err
	end
	local h, l = unpack("BB", tmp)
	local fin, op, mask, payload = h >> 7, h & 0x0f, l >> 7, l & 0x7f
	if h & 0x70 ~= 0 then
		return nil, "Unexpected RSV bits", nil, 1002
	end
	if op ~= 0 and op ~= 1 and op ~= 2 and op ~= 8 and op ~= 9 and op ~= 10 then
		return nil, "Unknown frame type: " .. tostring(op), nil, 1002
	end
	if mask ~= sock.rmask then
		return nil, "Invalid frame mask", nil, 1002
	end
	if op >= 8 and (fin == 0 or payload > 125) then
		return nil, "Invalid control frame", nil, 1002
	end
	if payload == 126 then
		tmp, err = conn:read(2)
		if not tmp then
			return nil, err
		end
		payload = unpack(">I2", tmp)
		if payload < 126 then
			return nil, "Nonminimal payload length", nil, 1002
		end
	elseif payload == 127 then
		tmp, err = conn:read(8)
		if not tmp then
			return nil, err
		end
		payload = unpack(">I8", tmp)
		if payload < 65536 then
			return nil, "Invalid 64-bit payload length", nil, 1002
		end
	end
	-- Both transports bound a single read by INT_MAX.
	if payload > MAX_READ_SIZE then
		return nil, "Frame payload is too large", nil, 1009
	end
	if op < 8 then
		if sock.stashbuf then
			if op ~= 0 then
				return nil, "Expected continuation frame", nil, 1002
			end
		elseif op == 0 then
			return nil, "Unexpected continuation frame", nil, 1002
		end
		local limit = sock.readlimit
		if limit and payload > limit - sock.stashsize then
			return nil, "Message payload is too large", nil, 1009
		end
	end
	local key
	if mask == 1 then
		key, err = conn:read(4)
		if not key then
			return nil, err
		end
	end
	local data, err = conn:read(payload)
	if not data then
		return nil, err
	end
	if key then
		data = xor(key, data)
	end
	if op == 8 then
		local err, code = check_close(data)
		if err then
			return nil, err, nil, code
		end
	end
	return fin, op, data
end

---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param fin integer
---@param op integer
---@param mask integer
---@param dat string
---@return boolean, string?
local function write_frame(conn, fin, op, mask, dat)
	local hdr
	local len = #dat
	local h, l = fin << 7 | op, mask << 7
	if len <= 125 then
		hdr = pack(">I1I1", h, l | len)
	elseif len <= 0xffff then
		hdr = pack(">I1I1I2", h, l | 126, len)
	else
		hdr = pack(">I1I1I8", h, l | 127, len)
	end
	if mask == 1 then
		local masking_key = randombytes(4)
		dat = xor(masking_key, dat)
		return conn:write(hdr .. masking_key .. dat)
	else
		return conn:write(hdr .. dat)
	end
end

---@class silly.net.websocket.socket
---@field package conn silly.net.tcp.conn|silly.net.tls.conn|nil
---@field package stream silly.net.http.h1.stream.client|silly.net.http.h1.stream.server
---@field package rmask integer
---@field package wmask integer
---@field package stashtype string|nil
---@field package stashbuf string[]|nil
---@field package stashsize integer
---@field package readlimit integer?
---@field package sentclose boolean
---@field package closepayload string?
local s = {}

local function fail(sock, err, code)
	local conn = sock.conn
	if conn then
		if code and not sock.sentclose then
			pcall(write_frame, conn, 1, 8, sock.wmask, pack(">I2", code))
		end
		sock.conn = nil
		conn:close()
	end
	sock.stashbuf = nil
	sock.stashtype = nil
	sock.stashsize = 0
	return nil, err, ""
end

---@param sock silly.net.websocket.socket
function s.read(sock)
	local conn = sock.conn
	if not conn or sock.closepayload then
		return nil, CLOSED, ""
	end
	local limit = sock.readlimit
	if limit and sock.stashsize > limit then
		return fail(sock, "Message payload is too large", 1009)
	end
	local stashbuf = sock.stashbuf
	while true do
		local fin, op, data, code = read_frame(sock, conn)
		if not fin then
			return fail(sock, op, code)
		end
		if op >= 8 then
			if op == 8 then
				sock.closepayload = data
				sock.stashbuf = nil
				sock.stashtype = nil
				sock.stashsize = 0
			end
			return data, data_type[op]
		end
		local size = sock.stashsize + #data
		-- The limit may change while a payload read is suspended.
		limit = sock.readlimit
		if limit and size > limit then
			return fail(sock, "Message payload is too large", 1009)
		end
		if fin == 0 then
			sock.stashsize = size
		end
		local kind
		if not stashbuf then
			kind = data_type[op]
			if fin == 0 then
				stashbuf = {data}
				sock.stashbuf = stashbuf
				sock.stashtype = kind
			end
		else
			stashbuf[#stashbuf + 1] = data
			if fin == 1 then
				data = concat(stashbuf)
				kind = sock.stashtype
				sock.stashbuf = nil
				sock.stashtype = nil
				sock.stashsize = 0
			end
		end
		if fin == 1 then
			if kind == "text" and not utf8len(data) then
				return fail(sock, "Invalid text UTF-8", 1007)
			end
			return data, kind
		end
	end
end

---Set the maximum received message size in bytes; nil or nonpositive disables it.
---@param sock silly.net.websocket.socket
---@param limit integer?
function s.limit(sock, limit)
	if limit and limit <= 0 then
		limit = nil
	end
	sock.readlimit = limit
end

---@param sock silly.net.websocket.socket
---@param dat string?
---@param typ string
function s.write(sock, dat, typ)
	typ = typ or "binary"
	local conn = sock.conn
	if not conn or
		(sock.sentclose and typ ~= "ping" and typ ~= "pong") or
		(sock.closepayload and typ ~= "close") then
		return false, CLOSED
	end
	dat = dat or NIL
	if typ == "text" and not utf8len(dat) then
		return false, "Invalid text UTF-8"
	elseif typ == "close" then
		local err = check_close(dat)
		if err then
			return false, err
		end
	elseif typ == "continuation" then
		return false, "Unexpected continuation frame"
	end
	if #dat > 125 and typ ~= "text" and typ ~= "binary" then
		return false, "All control frames MUST have a payload length of 125 bytes or less"
	end
	local ok, err
	local wmask = sock.wmask
	local len = #dat
	local op = assert(data_type[typ], typ)
	if op == 8 then
		sock.sentclose = true
	end
	if len >= 2^16 then
		local off = 1
		local nxt = 1
		local fin = 0
		while fin == 0 do
			nxt = off + 2^16 - 1
			local tmp = dat:sub(off, nxt)
			if nxt >= len then
				fin = 1
			end
			off = nxt + 1
			ok, err = write_frame(conn, fin, op, wmask, tmp)
			if not ok then
				break
			end
			op = 0
		end
	else
		ok, err = write_frame(conn, 1, op, wmask, dat)
	end
	return ok, err
end

---@param sock silly.net.websocket.socket
---@return boolean, string?
function s.close(sock)
	local conn = sock.conn
	if not conn then
		return false, CLOSED
	end
	-- A failed Close frame must not prevent releasing the transport.
	if not sock.sentclose then
		pcall(sock.write, sock, sock.closepayload or "", "close")
	end
	sock.conn = nil
	sock.stashbuf = nil
	sock.stashtype = nil
	sock.stashsize = 0
	return conn:close()
end

local function has_token(value, token, ignorecase)
	if type(value) == "table" then
		value = concat(value, ",")
	end
	if type(value) ~= "string" then
		return false
	end
	if ignorecase then
		value = value:lower()
	end
	for item in value:gmatch("[^,]+") do
		if item:match("^[ \t]*(.-)[ \t]*$") == token then
			return true
		end
	end
	return false
end

local function valid_upgrade(header)
	return has_token(header["upgrade"], "websocket", true) and
		has_token(header["connection"], "upgrade", true)
end

---@param stream silly.net.http.h1.stream.server
---@return boolean, string? error
local function handshake(stream)
	local header = stream.header
	local key = header and header["sec-websocket-key"]
	local version = header and header["sec-websocket-version"]
	if type(version) == "string" and version ~= "13" then
		stream:respond(426, {["sec-websocket-version"] = "13"}, true)
		return false, "Unsupported WebSocket version"
	end
	if stream.method ~= "GET" or stream.version ~= "1.1" or not header or
		type(header["host"]) ~= "string" or header["host"] == "" or not valid_upgrade(header) or
		version ~= "13" or type(key) ~= "string" or #key ~= 24 or
		not key:match("^[A-Za-z0-9+/]+==$") then
		stream:respond(400, {}, true)
		return false, "Invalid WebSocket opening handshake"
	end
	local ack = {
		["connection"] = "Upgrade",
		["upgrade"] = "websocket",
		["sec-websocket-accept"] = base64.encode(sha1:digest(key .. guid)),
	}
	return stream:respond(101, ack, true)
end

local s_mt = {
	__index = s,
	__close = s.close,
}

---@param stream silly.net.http.h1.stream.client|silly.net.http.h1.stream.server
---@param isclient boolean
---@return silly.net.websocket.socket
local function newsocket(stream, isclient)
	local rmask = isclient and 0 or 1
	local wmask = isclient and 1 or 0
	---@class silly.net.websocket.socket
	local sock = {
		conn = stream.conn,
		stream = stream,
		rmask = rmask,
		wmask = wmask,
		stashtype = nil,
		stashbuf = nil,
		stashsize = 0,
		readlimit = nil,
		sentclose = false,
		closepayload = nil,
	}
	setmetatable(sock, s_mt)
	return sock
end

---@param url string
---@param header table|nil
---@return silly.net.websocket.socket|nil, string|nil
function M.connect(url, header)
	local conn, err
	local u, err = parseurl(url)
	if not u then
		return nil, err
	end
	if u.scheme ~= "ws" and u.scheme ~= "wss" or u.path:find("#", 1, true) then
		return nil, "Invalid WebSocket URL"
	end
	local ip, err = dns.lookup(u.host, dns.A)
	if not ip then
		return nil, format("dns lookup %s failed: %s", u.host, err)
	end
	local a = join_addr(ip, u.port)
	local key = base64.encode(randombytes(16))
	if u.scheme == "wss" then
		conn, err = tls.connect(a, {hostname = u.host})
	else
		conn, err = tcp.connect(a)
	end
	if not conn then
		return nil, err
	end
	header = header or {}
	header["connection"] = "Upgrade"
	header["upgrade"] = "websocket"
	header["sec-websocket-version"] = 13
	header["sec-websocket-key"] = key
	local stream = h1.newstream(u.scheme, conn, u.authority)
	local ok, err = stream:request("GET", u.path, header)
	if not ok then
		stream:close()
		return nil, err
	end
	stream:closewrite()
	local ok, err = stream:waitresponse()
	if not ok then
		stream:close()
		return nil, err
	end
	local status = stream.status
	if not status or status ~= 101 then
		stream:close()
		return nil, format("websocket.connect fail:%s", status or err)
	end
	local response = stream.header
	local protocol = response["sec-websocket-protocol"]
	if stream.version ~= "1.1" or not valid_upgrade(response) or
		response["sec-websocket-accept"] ~= base64.encode(sha1:digest(key .. guid)) or
		response["sec-websocket-extensions"] ~= nil or
		protocol and (type(protocol) ~= "string" or not has_token(header["sec-websocket-protocol"], protocol)) then
		stream:close()
		return nil, "Invalid WebSocket upgrade response"
	end
	return newsocket(stream, true), nil
end

---@param stream silly.net.http.h1.stream.server
function M.upgrade(stream)
	local ok, err = handshake(stream)
	if not ok then
		return nil, err
	end
	local sock = newsocket(stream, false)
	stream.conn = nil
	return sock, nil
end

return M
