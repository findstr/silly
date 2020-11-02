local client = require "http.client"
local server = require "http.server"
local crypto = require "sys.crypto"
local json = require "sys.json"
local pairs = pairs
local concat = table.concat
local pack = string.pack
local unpack = string.unpack

local M = {}
local NIL = ""
local guid = [[258EAFA5-E914-47DA-95CA-C5AB0DC85B11]]
local func_cache = setmetatable({}, {__mode="kv"})
local func_mask_cache = {
	[0] = func_cache,
	[1] = setmetatable({}, {__mode="kv"}),
}

local checklist = {
	["upgrade"] = "websocket",
	["connection"] = "Upgrade",
	["sec-websocket-version"] = "13",
}

local data_type = {
	[0] = "undefined",
	[1] = "text",
	[2] = "binary",
	[8] = "close",
	[9] = "ping",
	[10] = "pong",
	["text"] = 1,
	["binary"] = 2,
	["close"] = 8,
	["ping"] = 9,
	["pong"] = 10,
}

local function read_frame(r, sock)
	local dat
	local tmp = r(sock, 2)
	local op, mask, payload, masking_key
	local h,l = tmp:byte(1), tmp:byte(2)
	local fin, op, mask, payload =
		(h & 0x80) >> 7, h & 0x0f,
		(l & 0x80) >> 7, l & 0x7f
	if payload == 126 then
		tmp = r(sock, 2)
		payload = unpack(">I2", tmp)
	elseif payload == 127 then
		payload = unpack(">I8", tmp)
	end
	if mask == 1 then
		local buf = {}
		masking_key = r(sock, 4)
		dat = r(sock, payload)
		dat = crypto.xor(masking_key, dat)
	else
		dat = r(sock, payload)
	end
	return fin, op, dat
end

local function write_frame(w, sock, fin, op, mask, dat)
	local hdr
	local len = #dat
	if len > 125 then
		len = 126
	end
	local h, l = fin << 7 | op, mask << 7 | len
	if len == 126 then
		hdr = pack("<I1I1I2", h, l, #dat)
	else
		hdr = pack("<I1I1", h, l)
	end
	if mask == 1 then
		local masking_key = crypto.randomkey(4)
		dat = crypto.xor(masking_key, dat)
		return w(sock, hdr .. masking_key .. dat)
	else
		return w(sock, hdr .. dat)
	end
end

local function wrap_read(r)
	local f = func_cache[r]
	if f then
		return f
	end
	f = function(sock)
		local fin = 0
		local format
		local buf = {}
		while fin == 0 do
			local op, dat
			fin, op, dat = read_frame(r, sock)
			if op ~= 0 then
				format = data_type[op]
			end
			buf[#buf + 1] = dat
		end
		return concat(buf), format
	end
	func_cache[r] = f
	return f
end

local function wrap_write(w, mask)
	local f = func_mask_cache[mask][w]
	if f then
		return f
	end
	--local MAX_FRAGMENT = 64*1024-1
	f = function(sock, dat, typ)
		local ok
		typ = typ or "binary"
		dat = dat or NIL
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
				ok = write_frame(w, sock, fin, op, mask, tmp)
				if not ok then
					break
				end
				op = 0
			end
		else
			ok = write_frame(w, sock, 1, op, mask, dat)
		end
		return ok
	end
	func_mask_cache[mask][w] = f
	return f
end

local function wrap_close(c)
	local f = func_cache[c]
	if f then
		return f
	end
	f = function(sock)
		sock:write(nil, "close")
		return c(sock)
	end
	func_cache[c] = f
	return f
end

local function handshake(req)
	local sock = req.sock
	local header = req.header
	local write = server.write
	if req.method ~= "GET" then
		write(sock, 400)
		return
	end
	for k, v in pairs(checklist) do
		local verify = header[k]
		if verify and verify ~= v then
			write(sock, 400)
			return
		end
	end
	local key = header["sec-websocket-key"]
	if not key then
		write(sock, 400)
		return
	end
	key = crypto.base64encode(crypto.sha1(key .. guid))
	local ack = {
		"connection: Upgrade",
		"upgrade: websocket",
		"sec-websocket-accept: " .. key,
	}
	return write(sock, 101, ack)
end

local function wrap_handshake(handler)
	return function(req)
		local sock = req.sock
		if handshake(req) then
			--hook origin read function
			sock.read = wrap_read(sock.read)
			sock.write = wrap_write(sock.write, 0)
			sock.close = wrap_close(sock.close)
			handler(sock)
		else
			sock:close()
		end
	end
end

function M.listen(conf)
	conf.handler = wrap_handshake(conf.handler)
	return server.listen(conf)
end

function M.connect(uri, param)
	local key = crypto.base64encode(crypto.randomkey(16))
	local req = client.request("GET", uri, {
		"connection: Upgrade",
		"upgrade: websocket",
		"sec-websocket-version: 13",
		"sec-websocket-key: " .. key,
	}, param)
	if not req or req.status ~= 101 then
		return nil, "websocket.connect fail"
	end
	local sock = req.sock
	sock.read = wrap_read(sock.read)
	sock.write = wrap_write(sock.write, 1)
	sock.close = wrap_close(sock.close)
	return sock
end

return M

