local http = require "core.http"
local base64 = require "core.base64"
local sha1 = require "core.crypto.hash".new("sha1")
local utils = require "core.crypto.utils"

local pairs = pairs
local tostring = tostring
local setmetatable = setmetatable

local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local xor = utils.xor
local randomkey = utils.randomkey

---@class core.websocket
local M = {}
local NIL = ""
local guid = [[258EAFA5-E914-47DA-95CA-C5AB0DC85B11]]
local func_mask_cache = {
	[0] = setmetatable({}, {__mode="kv"}),
	[1] = setmetatable({}, {__mode="kv"}),
}

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


local function read_frame(fd, r, needmask)
	local dat
	local tmp, err = r(fd, 2)
	if not tmp then -- the frame header is not read, treat as EOF
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
		tmp, err = r(fd, 2)
		if not tmp then
			return nil, err, ""
		end
		payload = unpack(">I2", tmp)
	elseif payload == 127 then
		tmp, err = r(fd, 8)
		if not tmp then
			return nil, err, ""
		end
		payload = unpack(">I8", tmp)
	end
	if mask == 1 then
		masking_key, err = r(fd, 4)
		if not masking_key then
			return nil, err, ""
		end
		dat, err = r(fd, payload)
		if not dat then
			return nil, err, ""
		end
		dat = xor(masking_key, dat)
	else
		dat, err = r(fd, payload)
		if not dat then
			return nil, err, ""
		end
	end
	return fin, op, dat
end

---@param w fun(fd:integer, data:string):boolean, string?
---@return boolean, string?
local function write_frame(w, fd, fin, op, mask, dat)
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
		return w(fd, hdr .. masking_key .. dat)
	else
		return w(fd, hdr .. dat)
	end
end

---@param r async fun(fd:integer, n:integer):string?, string?
local function wrap_read(r, mask)
	local f = func_mask_cache[mask][r]
	if f then
		return f
	end
	f = function(sock)
		local stashbuf = sock.stashbuf
		local fd = sock.fd
		if not stashbuf then -- read first frame
			local fin, op, dat = read_frame(fd, r, mask)
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
			fin, op, dat = read_frame(fd, r, mask)
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
	func_mask_cache[mask][r] = f
	return f
end


local function wrap_write(w, mask)
	local f = func_mask_cache[mask][w]
	if f then
		return f
	end
	--local MAX_FRAGMENT = 64*1024-1
	f = function(sock, dat, typ)
		typ = typ or "binary"
		dat = dat or NIL
		if #dat > 125 and typ ~= "text" and typ ~= "binary" then
			return false, "all control frames MUST have a payload length of 125 bytes or less"
		end
		local ok, err
		local fd = sock.fd
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
				ok, err = write_frame(w, fd, fin, op, mask, tmp)
				if not ok then
					break
				end
				op = 0
			end
		else
			ok, err = write_frame(w, fd, 1, op, mask, dat)
		end
		return ok, err
	end
	func_mask_cache[mask][w] = f
	return f
end

local function wrap_close(c)
	local f = func_mask_cache[0][c]
	if f then
		return f
	end
	---@param sock core.websocket.socket
	f = function(sock)
		sock:write(nil, "close")
		return c(sock.fd)
	end
	func_mask_cache[0][c] = f
	return f
end

local function handshake(stream)
	local write = stream.respond
	if stream.method ~= "GET" then
		write(stream, 400)
		return
	end
	local header = stream.header
	if not header then
		write(stream, 400)
		return
	end
	for k, v in pairs(checklist) do
		local verify = header[k]
		if verify and verify ~= v then
			write(stream, 400)
			return
		end
	end
	local key = header["sec-websocket-key"]
	if not key then
		write(stream, 400)
		return
	end
	key = base64.encode(sha1:digest(key .. guid))
	local ack = {
		["connection"] = "Upgrade",
		["upgrade"] = "websocket",
		["sec-websocket-accept"] = key,
	}
	return write(stream, 101, ack)
end

---@param stream core.http.h1stream
---@param isclient boolean
---@return core.websocket.socket
local function upgrade(stream, isclient)
	local transport = stream.transport
	local read = transport.read
	local write = transport.write
	local close = transport.close
	local rmask = isclient and 0 or 1
	local wmask = isclient and 1 or 0
	---@class core.websocket.socket
	local sock = {
		fd = stream.fd,
		stream = stream,
		read = wrap_read(read, rmask),
		write = wrap_write(write, wmask),
		close = wrap_close(close),
		stashtype = nil,
		stashbuf = nil,
	}
	return sock
end

local function wrap_handshake(handler)
	---@param stream core.http.h1stream
	return function(stream)
		if handshake(stream) then
			local sock = upgrade(stream, false)
			handler(sock)
		else
			stream:close()
		end
	end
end

---@class core.websocket.listen.conf:core.http.transport.listen.conf
---@field handler fun(sock: core.websocket.socket)

---@param conf core.websocket.listen.conf
function M.listen(conf)
	conf.handler = wrap_handshake(conf.handler)
	return http.listen(conf)
end

---@param url string
---@param header table|nil
---@return core.websocket.socket|nil, string|nil
function M.connect(url, header)
	url = url:gsub("^ws", "http")
	header = header or {}
	header["connection"] = "Upgrade"
	header["upgrade"] = "websocket"
	header["sec-websocket-version"] = 13
	header["sec-websocket-key"] = base64.encode(randomkey(16))
	local stream, err = http.request("GET", url, header)
	if not stream then
		return nil, err
	end
	local status, _ = stream:readheader()
	if not status or status ~= 101 then
		return nil, "websocket.connect fail"
	end
	return upgrade(stream, true), nil
end

return M

