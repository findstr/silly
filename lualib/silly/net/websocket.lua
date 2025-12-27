local http = require "silly.net.http"
local base64 = require "silly.encoding.base64"
local sha1 = require "silly.crypto.hash".new("sha1")
local utils = require "silly.crypto.utils"
local helper = require "silly.net.http.helper"
local dns = require "silly.net.dns"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local h1 = require "silly.net.http.h1"

local pairs = pairs
local tostring = tostring
local setmetatable = setmetatable

local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local format = string.format
local xor = utils.xor
local randomkey = utils.randomkey
local parseurl = helper.parseurl

---@class silly.net.websocket
local M = {}
local NIL = ""
local guid = [[258EAFA5-E914-47DA-95CA-C5AB0DC85B11]]

local checklist = {
	["upgrade"] = "websocket",
	["connection"] = "Upgrade",
	["sec-websocket-version"] = "13",
}

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

---@param conn silly.net.tcp.conn|silly.net.tls.conn
local function read_frame(conn, needmask)
	local dat
	local tmp, err = conn:read(2)
	if err then -- the frame header is not read, treat as EOF
		return nil, err, ""
	end
	local masking_key
	local h,l = unpack("<I1I1", tmp)
	local fin, op, mask, payload =
		(h & 0x80) >> 7, h & 0x0f,
		(l & 0x80) >> 7, l & 0x7f
	if needmask ~= mask then
		return nil, needmask == 1 and "need mask but got none" or "got mask but need none"
	end
	if payload == 126 then
		tmp, err = conn:read(2)
		if err then
			return nil, err, ""
		end
		payload = unpack(">I2", tmp)
	elseif payload == 127 then
		tmp, err = conn:read(8)
		if err then
			return nil, err, ""
		end
		payload = unpack(">I8", tmp)
	end
	if mask == 1 then
		masking_key, err = conn:read(4)
		if not masking_key then
			return nil, err, ""
		end
		dat, err = conn:read(payload)
		if err then
			return nil, err, ""
		end
		dat = xor(masking_key, dat)
	else
		dat, err = conn:read(payload)
		if err then
			return nil, err, ""
		end
	end
	return fin, op, dat
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
	if len < 125 then
	elseif len < 0xffff then
		len = 126
	else
		len = 127
	end
	local h, l = fin << 7 | op, mask << 7 | len
	if len == 126 then
		hdr = pack(">I1I1I2", h, l, #dat)
	elseif len == 127 then
		hdr = pack(">I1I1I8", h, l, #dat)
	else
		hdr = pack(">I1I1", h, l)
	end
	if mask == 1 then
		local masking_key = randomkey(4)
		dat = xor(masking_key, dat)
		return conn:write(hdr .. masking_key .. dat)
	else
		return conn:write(hdr .. dat)
	end
end

---@class silly.net.websocket.socket
---@field package conn silly.net.tcp.conn|silly.net.tls.conn
---@field package stream silly.net.http.h1.stream.client|silly.net.http.h1.stream.client
---@field package rmask integer
---@field package wmask integer
---@field package stashtype string|nil
---@field package stashbuf string[]|nil
local s = {}

---@param sock silly.net.websocket.socket
function s.read(sock)
	local conn = sock.conn
	local rmask = sock.rmask
	local stashbuf = sock.stashbuf
	if not stashbuf then -- read first frame
		local fin, op, dat = read_frame(conn, rmask)
		if not fin then
			return nil, op, ""
		end
		local format = data_type[op]
		if not format then
			return nil, "unknown frame type:" .. tostring(op), ""
		end
		if fin ~= 0 then
			return dat, format
		end
		stashbuf = {dat}
		sock.stashtype = format
		sock.stashbuf = stashbuf
	end
	local fin = 0
	while fin == 0 do
		local op, dat, err
		fin, op, dat = read_frame(conn, rmask)
		if not fin then
			return nil, op, ""
		end
		if op ~= 0 then
			return dat, data_type[op]
		end
		stashbuf[#stashbuf + 1] = dat
	end
	local dat = concat(stashbuf)
	local format = sock.stashtype
	sock.stashbuf = nil
	sock.stashtype = nil
	return dat, format
end

---@param sock silly.net.websocket.socket
---@param dat string?
---@param typ string
function s.write(sock, dat, typ)
	typ = typ or "binary"
	dat = dat or NIL
	if #dat > 125 and typ ~= "text" and typ ~= "binary" then
		return false, "all control frames MUST have a payload length of 125 bytes or less"
	end
	local ok, err
	local conn = sock.conn
	local wmask = sock.wmask
	local len = #dat
	local op = assert(data_type[typ], typ)
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
	sock:write("", "close")
	local conn = sock.conn
	local ok, err = conn:close()
	sock.conn = nil
	return ok, err
end

---@param stream silly.net.http.h1.stream.server
---@return boolean, string? error
local function handshake(stream)
	local respond = stream.respond
	if stream.method ~= "GET" then
		respond(stream, 400, {})
		return false, "method not GET"
	end
	local header = stream.header
	if not header then
		respond(stream, 400, {})
		return false, "header not found"
	end
	for k, v in pairs(checklist) do
		local verify = header[k]
		if verify and verify ~= v then
			respond(stream, 400, {})
			return false, "header " .. k .. " mismatch"
		end
	end
	local key = header["sec-websocket-key"]
	if not key then
		respond(stream, 400, {})
		return false, "sec-websocket-key not found"
	end
	key = base64.encode(sha1:digest(key .. guid))
	local ack = {
		["connection"] = "Upgrade",
		["upgrade"] = "websocket",
		["sec-websocket-accept"] = key,
	}
	respond(stream, 101, ack)
	return true, nil
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
	}
	setmetatable(sock, s_mt)
	return sock
end

---@param url string
---@param header table|nil
---@return silly.net.websocket.socket|nil, string|nil
function M.connect(url, header)
	local conn, err
	local scheme, host, port, path = parseurl(url)
	local ip = dns.lookup(host, dns.A)
	if not ip then
		return nil, "dns lookup failed"
	end
	assert(ip, host)
	local addr = format("%s:%s", ip, port)
	if scheme == "wss" then
		conn, err = tls.connect(addr, {hostname = host})
	else
		conn, err = tcp.connect(addr)
	end
	if not conn then
		return nil, err
	end
	header = header or {}
	header["connection"] = "Upgrade"
	header["host"] = host
	header["upgrade"] = "websocket"
	header["sec-websocket-version"] = 13
	header["sec-websocket-key"] = base64.encode(randomkey(16))
	local stream = h1.newstream(scheme, conn)
	local ok, err = stream:request("GET", path, header)
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
	return newsocket(stream, true), nil
end

---@param stream silly.net.http.h1.stream.server
function M.upgrade(stream)
	local ok, err = handshake(stream)
	if not ok then
		return nil, err
	end
	local sock = newsocket(stream, false)
	stream:closewrite()
	return sock, nil
end

return M

