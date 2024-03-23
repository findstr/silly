local core = require "core"
local helper = require "core.http.helper"
local hpack = require "http2.hpack"
local builder = require "http2.framebuilder"

local pairs = pairs
local wakeup = core.wakeup
local move = table.move
local remove = table.remove
local concat = table.concat
local format = string.format
local pack = string.pack
local unpack = string.unpack
local setmetatable = setmetatable
local parseuri = helper.parseuri

local hpack_new = hpack.new
local hpack_pack = hpack.pack
local hpack_unpack = hpack.unpack
local hpack_hardlimit = hpack.hardlimit

local build_header = builder.header
local build_body = builder.body
local build_setting = builder.setting
local build_winupdate = builder.winupdate

local M = {}

local FRAME_DATA<const>		= 0
local FRAME_HEADERS<const>	= 1
local FRAME_PRIORITY<const>	= 2
local FRAME_RST<const>		= 3
local FRAME_SETTINGS<const>	= 4
local FRAME_PUSHPROMISE<const>	= 5
local FRAME_PING<const>		= 6
local FRAME_GOAWAY<const>	= 7
local FRAME_WINUPDATE<const>	= 8
local FRAME_CONTINUATION<const>	= 9

local SETTINGS_HEADER_TABLE_SIZE<const> = 1
local SETTINGS_ENABLE_PUSH<const>	= 2
local SETTINGS_MAX_CONCURRENT<const>	= 3
local SETTINGS_WIN_SIZE<const>		= 4
local SETTINGS_MAX_FRAME_SIZE<const>	= 5
local SETTINGS_MAX_HEADER_SIZE<const>	= 6

local ACK<const>			= 0x01
local END_STREAM<const>			= 0x01
local END_HEADERS<const>		= 0x04
local PADDED<const>			= 0x08
local PRIORITY<const>			= 0x20

local default_header_table_size<const> = 4096
local default_frame_size<const> = 16384
local default_window_size<const> = 65535
local client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
local client_preface_size = #client_preface

local setting_field = {
	[SETTINGS_ENABLE_PUSH] = "enable_push",
	[SETTINGS_MAX_CONCURRENT] = "stream_max",
	[SETTINGS_WIN_SIZE] = "window_size",
	[SETTINGS_MAX_FRAME_SIZE] = "frame_max_size",
	[SETTINGS_MAX_HEADER_SIZE] = "max_header_size",
}

local mt = {__index = M}
local client_channel = {}
local server_stream_q = {}

local function read_frame(socket)
	local read = socket.read
	local x9 = read(socket, 9)
	if not x9 then
		return nil
	end
	local n, t, f, id = unpack(">I3I1I1I4", x9)
	local dat = n > 0 and read(socket, n) or ""
	return t, f, dat, id
end

local function try_wakeup_connect(ch)
	local wait = ch.wait_for_conn
	local n, m = #wait, ch.stream_max - ch.stream_count
	if n == 0 or m <= 0 then
		return
	end
	if n < m then
		m = n
	end
	for i = 1, m do
		local co = wait[i]
		wait[i] = nil
		wakeup(co, "ok")
	end
	ch.stream_count = ch.stream_count + m
	if m < n then
		m = m + 1
		move(wait, m, n, 1)
		for i = n-m+2, n do
			wait[i] = nil
		end
	end
end

local function try_read_header(ch, flag, dat)
	local header
	local offset = 1
	local strip = 0
	if flag & PADDED == PADDED then
		offset = 2
		strip = unpack(">I1", dat)
	end
	if flag & PRIORITY == PRIORITY then
		offset = offset + 5
	end
	if offset > 1 then
		dat = dat:sub(offset, -(strip + 1))
	end
	if flag & END_HEADERS == END_HEADERS then --all headers
		header = hpack_unpack(ch.recv_hpack, dat)
	else
		local socket = ch.socket
		local tbl = {dat}
		repeat
			local t, f, d = read_frame(socket)
			if not t and t ~= FRAME_CONTINUATION then
				--todo:check t, maybe should ack error
				return nil
			end
			tbl[#tbl + 1] = d
		until f & END_HEADERS == END_HEADERS
		header = hpack_unpack(ch.recv_pack, tbl)
	end
	return header
end

local function local_close(s)
	s.localclose = true
	if s.active and s.remoteclose then
		local ch = s.channel
		ch.stream_count = ch.stream_count - 1
		try_wakeup_connect(s.channel)
	end
end

local function remote_close(s)
	s.remoteclose = true
	if s.active and s.localclose then
		local ch = s.channel
		ch.stream_count = ch.stream_count - 1
		try_wakeup_connect(ch)
	end
end

local function frame_header_client(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	if not s then
		--todo:ack error
		return
	end
	local header = try_read_header(ch, flag, dat)
	if not header then
		return
	end
	s.header = header
	if flag & END_STREAM == END_STREAM then
		streams[id] = nil
		remote_close(s)
	end
	local co = s.co
	if co then
		s.co = nil
		core.wakeup(co, "ok")
	end
end

local function frame_header_server(ch, id, flag, dat)
	local header = try_read_header(ch, flag, dat)
	if not header then
		return
	end
	local uri = header[':path']
	local path, form = parseuri(uri)
	local s = setmetatable({
		version = "HTTP/2",
		header = header,
		method = header[':method'],
		path = path,
		form = form,
		--private members
		id = id,
		co = false,
		active = false,
		channel = ch,
		localclose = false,
		remoteclose = false,
	}, mt)
	if flag & END_STREAM == END_STREAM then
		s.remoteclose = true
	else
		ch.streams[id] = s
	end
	server_stream_q[#server_stream_q + 1] = s
	core.fork(ch.handler)
end

local function frame_data(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	if not s then
		--todo: ack error
		return
	end
	if flag & PADDED == PADDED then
		dat = dat:sub(2,-1)
	end
	if flag & END_STREAM == END_STREAM then
		ch.socket:write(build_winupdate(0, 0, #dat))
		s.remoteclose = true
		if s.active and s.localclose then
			ch.stream_count = ch.stream_count - 1
			try_wakeup_connect(ch)
		end
		streams[id] = nil
	else
		ch.socket:write(build_winupdate(id, 0, #dat))
	end
	local co = s.co
	if co then
		s.co = nil
		wakeup(co, dat)
	else
		s[#s + 1] = dat
	end
end

local function frame_settings(ch, _, flag, dat)
	for i = 1, #dat, 6 do
		local id, val = unpack(">I2I4", dat, i)
		if id == SETTINGS_HEADER_TABLE_SIZE then
			hpack_hardlimit(ch.recv_hpack, val)
		else
			local fname = setting_field[id]
			if fname then
				ch[fname] = val
			end
		end
	end
end

local function frame_ping(ch, _, flag, dat)
	ch.socket:write(pack(">I3I1I1I4", #dat, FRAME_PING, 1, 0) .. dat)
end

local function frame_rst(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	if s then
		streams[id] = nil
		s.localclose = true
		s.remoteclose = true
		if s.active then
			ch.stream_count = ch.stream_count - 1
			try_wakeup_connect(ch)
		end
		local co = s.co
		if co then
			core.wakeup(co, "rst")
		end
	end
end

local function frame_goaway(ch, _, flag, dat)
	local wait = ch.wait_for_conn
	local err = "goaway:" .. dat
	for i = 1, #wait do
		wakeup(wait[i], err)
	end
	ch.socket:close()
	ch.socket = nil
	local wakeup = core.wakeup
	local streams = ch.streams
	for k, s in pairs(streams) do
		s.channel = nil
		s.localclose = true
		s.remoteclose = true
		streams[k] = nil
		local co = s.co
		if co then
			wakeup(co, err)
		end
	end
end

local function frame_winupdate(ch, id, flag, dat)
	if id == 0 then
		local n = ch.window_size + unpack(">I4", dat)
		if n > 0 then
			local dat = remove(ch, 1)
			if dat then
				n = n - #dat
				ch.socket:write(dat)
			end
		end
		ch.window_size = n
	end
end

local frame_client = {
	[FRAME_HEADERS] = frame_header_client,
	[FRAME_DATA] = frame_data,
	[FRAME_RST] = frame_rst,
	[FRAME_SETTINGS] = frame_settings,
	[FRAME_PING] = frame_ping,
	[FRAME_GOAWAY] = frame_goaway,
	[FRAME_WINUPDATE] = frame_winupdate,
}

local frame_server = {
	[FRAME_HEADERS] = frame_header_server,
	[FRAME_DATA] = frame_data,
	[FRAME_RST] = frame_rst,
	[FRAME_SETTINGS] = frame_settings,
	[FRAME_PING] = frame_ping,
	[FRAME_GOAWAY] = frame_goaway,
	[FRAME_WINUPDATE] = frame_winupdate,
}

local function common_dispatch(ch, frame_process)
	local socket = ch.socket
	while ch.socket do
		local t,f,d,id = read_frame(socket)
		if not t then
			ch.socket = nil
			break
		end
		local func = frame_process[t]
		if func then
			func(ch, id, f, d)
		end
	end
	local t = ch.streams
	for _, v in pairs(t) do
		local co = v.co
		if co then
			wakeup(co, "channel closed")
		end
		v.channel = nil
		v.localclose = true
		v.remoteclose = true
	end
end

local function client_dispatch(ch)
	return function()
		common_dispatch(ch, frame_client)
		local tag = ch.tag
		if client_channel[tag] == ch then
			client_channel[tag] = nil
		end
		local wait = ch.wait_for_conn
		for i = 1, #wait do
			wakeup(wait[i], "channel closed")
		end
	end
end

local function handshake_as_client(ch, socket)
	ch.send_hpack = hpack_new(default_header_table_size)
	ch.recv_hpack = hpack_new(default_header_table_size)
	local write = socket.write
	write(socket, client_preface)
	local dat = build_setting(0x0,
		SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, 100,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	write(socket, dat)
	local t, f, dat, id = read_frame(socket)
	if not t or t ~= FRAME_SETTINGS then
		return false, "expect settings"
	end
	frame_settings(ch, id, f, dat)
	write(socket, build_setting(0x01))
	write(socket, build_winupdate(0, 0, 1*1024*1024))
	while true do
		local t,f,dat,id = read_frame(socket)
		if not t then
			return false, "handshake closed"
		end
		local cb = frame_client[t]
		if cb then
			cb(ch, id, f, dat)
		end
		if t == FRAME_SETTINGS and f & ACK == ACK then
			break
		end
	end
	ch.dispatchco = core.fork(client_dispatch(ch))
	return true, "ok"
end

local function handshake_as_server(socket, ch)
	local dat = build_setting(0x0,
		SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, 100,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	local write = socket.write
	local read = socket.read
	local ok = write(socket, dat)
	if not ok then
		return false
	end
	dat = read(socket, client_preface_size)
	if dat ~= client_preface then
		return false
	end
	local t,f,dat,id = read_frame(socket)
	if not t or t ~= FRAME_SETTINGS then
		return false
	end
	frame_settings(ch, id, f, dat)
	write(socket, build_setting(0x01))
	write(socket, build_winupdate(0, 0, 1*1024*1024))
	while true do
		local t,f,dat,id = read_frame(socket)
		if not t then
			return false
		end
		local cb = frame_server[t]
		if cb then
			cb(ch, id, f, dat)
		end
		if t == FRAME_SETTINGS and f & ACK == ACK then
			break
		end
	end
	return true
end

function M.httpd(handler)
	return function(socket, addr)
		local ch = {
			--client and server common
			socket = socket,
			streams = {},
			send_hpack = hpack_new(default_header_table_size),
			recv_hpack = hpack_new(default_header_table_size),
			stream_max = 100,
			window_size = default_window_size,
			frame_max_size = default_frame_size,
			--server more
			handler = function()
				handler(remove(server_stream_q, 1))
			end
		}
		local ok = handshake_as_server(socket, ch)
		if ok then
			common_dispatch(ch, frame_server)
		end
	end
end

local function open_stream(ch)
	if ch.stream_count >= ch.stream_max then
		local t = ch.wait_for_conn
		t[#t + 1] = core.running()
		local reason = core.wait()
		if reason ~= "ok" then
			return false, reason
		end
	end
	local id = ch.stream_idx
	ch.stream_idx = id + 2
	local stream = setmetatable({
		id = id,
		co = false,
		active = true,
		channel = ch,
		localclose = false,
		remoteclose = false,
		header = false,
		sendheader = nil,
		version = "HTTP/2",
	}, mt)
	ch.streams[id] = stream
	return stream, "ok"
end

function M.new(tag, socket)
	local ch = client_channel[tag]
	if not ch then
		if not socket then
			return nil, "socket required"
		end
		local wait = {}
		ch = {
			--client and server common
			socket = socket,
			header = false,
			streams = {},
			send_hpack = false,
			recv_hpack = false,
			stream_max = 1000,
			window_size = default_window_size,
			frame_max_size = default_frame_size,
			--client more
			tag = tag,
			dispatchco = false,
			wait_for_conn = wait,
			stream_idx = 1,
			stream_count = 1,
		}
		client_channel[tag] = ch
		local ok, reason = handshake_as_client(ch, socket)
		if ok then
			try_wakeup_connect(ch)
		else
			client_channel[tag] = nil
			for i = 1, #wait do
				wakeup(wait[i], reason)
			end
			return ok, reason
		end
	end
	return open_stream(ch)
end

function M.request(s, method, path, header, close)
	local ch = s.channel
	if not ch then
		return false, "channel closed"
	end
	if s.localclose then
		return false, "local closed"
	end
	local host = header[":authority"]
	header[":authority"] = nil
	local hdr = hpack_pack(ch.send_hpack, header,
		":authority", host,
		":method", method,
		":path", path,
		":scheme", "https")
	if close then
		local_close(s)
	end
	local dat = build_header(s.id, ch.frame_max_size, hdr, close)
	return ch.socket:write(dat)
end

function M.readheader(s)
	local header = s.header
	if not header then
		local co = core.running()
		s.co = co
		local reason = core.wait()
		if reason ~= "ok" then
			return false, reason
		end
		header = s.header
	end
	return tonumber(header[':status']), header
end

function M.respond(s, status, header, close)
	local ch = s.channel
	if not ch then
		return false, "channel closed"
	end
	if s.localclose then
		return false, "local closed"
	end
	local hdr = hpack_pack(ch.send_hpack, header, ":status", status)
	local dat = build_header(s.id, ch.frame_max_size, hdr, close)
	if close then
		local_close(s)
		return ch.socket:write(dat)
	else
		s.sendheader = dat
	end
end

local function write_func(close)
	return function(s, dat)
		local ch = s.channel
		if not ch then
			return false, "channel closed"
		end
		if s.localclose then
			return false, "local closed"
		end
		if close then
			local_close(s)
		end
		local header = s.sendheader
		if header then
			s.sendheader = nil
			ch.socket:write(header)
		end
		dat = build_body(s.id, ch.frame_max_size, dat, close)
		local win = ch.window_size
		if win <= 0 then
			ch[#ch + 1] = dat
			return true, "ok"
		else
			ch.window_size = win - #dat
			return ch.socket:write(dat)
		end
	end
end

M.write = write_func(false)
local write_end = write_func(true)
function M.close(s, data)
	local header = s.sendheader
	if header then
		s.sendheader = nil
		s.channel.socket:write(header)
	end
	if not s.localclose then
		data = data or ""
		write_end(s, data)
		local_close(s)
	end
end

function M.read(s)
	local rc = s.remoteclose
	local dat = s[1]
	if not dat then
		if rc then
			return "", rc
		end
		s.co = core.running()
		core.wait()
		rc = s.remoteclose
	end
	dat = remove(s, 1)
	return dat, rc
end

function M.readall(s)
	local co = core.running()
	while not s.remoteclose do
		s.co = co
		local dat, _ = core.wait()
		if dat then
			s[#s + 1] = dat
		end
	end
	return concat(s)
end

function M.socket(s)
	return s.channel.socket
end

return M

