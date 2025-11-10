local silly = require "silly"
local time = require "silly.time"
local buffer = require "silly.adt.buffer"
local queue = require "silly.adt.queue"
local logger = require "silly.logger"
local helper = require "silly.net.http.helper"
local hpack = require "silly.http2.hpack"
local builder = require "silly.http2.framebuilder"

local assert = assert
local pairs = pairs
local tonumber = tonumber
local format = string.format
local wakeup = silly.wakeup
local pack = string.pack
local unpack = string.unpack
local setmetatable = setmetatable
local parsetarget = helper.parsetarget

local hpack_new = hpack.new
local hpack_pack = hpack.pack
local hpack_unpack = hpack.unpack
local hpack_hardlimit = hpack.hardlimit

local build_header = builder.header
local build_body = builder.body
local build_rst = builder.rst
local build_setting = builder.setting
local build_winupdate = builder.winupdate
local build_goaway = builder.goaway

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

local SETTINGS_HEADER_TABLE_SIZE<const>    = 1
local SETTINGS_ENABLE_PUSH<const>	   = 2
local SETTINGS_MAX_CONCURRENT<const>	   = 3
local SETTINGS_INITIAL_WINDOW_SIZE <const> = 4
local SETTINGS_MAX_FRAME_SIZE<const>	   = 5
local SETTINGS_MAX_HEADER_LIST_SIZE<const> = 6

local ACK<const>			= 0x01
local END_STREAM<const>			= 0x01
local END_HEADERS<const>		= 0x04
local PADDED<const>			= 0x08
local PRIORITY<const>			= 0x20

local STATE_NONE<const>			= 0x00
local STATE_HEADER<const>               = 0x01
local STATE_DATA <const>                = 0x02
local STATE_TRAILER <const>             = 0x03
local STATE_CLOSE<const>		= 0x10
local STATE_END<const>		        = STATE_CLOSE | 0x01
local STATE_RST<const>		        = STATE_CLOSE | 0x02

--- @alias silly.net.http.h2.state `STATE_NONE` | `STATE_HEADER` | `STATE_DATA` | `STATE_TRAILER` | `STATE_CLOSE` | `STATE_END` | `STATE_RST`

local default_header_table_size<const> = 4096
local default_frame_size<const> = 16384
local default_window_size<const> = 65535
local max_stream_per_channel<const> = 100
local client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
local client_preface_size = #client_preface

local NO_ERROR<const>			=0x00	--Graceful shutdown	[RFC9113, Section 7]
local PROTOCOL_ERROR<const>		=0x01	--Protocol error detected	[RFC9113, Section 7]
local INTERNAL_ERROR<const> 		=0x02	--Implementation fault	[RFC9113, Section 7]
local FLOW_CONTROL_ERROR<const>		=0x03	--Flow-control limits exceeded	[RFC9113, Section 7]
local SETTINGS_TIMEOUT<const>		=0x04	--Settings not acknowledged	[RFC9113, Section 7]
local STREAM_CLOSED<const> 		=0x05	--Frame received for closed stream	[RFC9113, Section 7]
local FRAME_SIZE_ERROR<const>		=0x06	--Frame size incorrect	[RFC9113, Section 7]
local REFUSED_STREAM<const> 		=0x07	--Stream not processed	[RFC9113, Section 7]
local CANCEL<const> 			=0x08	--Stream cancelled	[RFC9113, Section 7]
local COMPRESSION_ERROR<const>		=0x09	--Compression state not updated	[RFC9113, Section 7]
local CONNECT_ERROR<const> 		=0x0a	--TCP connection error for CONNECT method	[RFC9113, Section 7]
local ENHANCE_YOUR_CALM<const>		=0x0b	--Processing capacity exceeded	[RFC9113, Section 7]
local INADEQUATE_SECURITY<const>	=0x0c	--Negotiated TLS parameters not acceptable	[RFC9113, Section 7]
local HTTP_1_1_REQUIRED<const>		=0x0d	--Use HTTP/1.1 for the request	[RFC9113, Section 7]

local CLOSED_STREAM_COUNT<const> = 100
local MAX_STREAM_ID<const> = 0x7fffffff-2
local TIMEOUT<const> = {}

local err_str = setmetatable({
	[0x00] = "Graceful shutdown",
	[0x01] = "Protocol error detected",
	[0x02] = "Implementation fault",
	[0x03] = "Flow-control limits exceeded",
	[0x04] = "Settings not acknowledged",
	[0x05] = "Frame received for closed stream",
	[0x06] = "Frame size incorrect",
	[0x07] = "Stream not processed",
	[0x08] = "Stream cancelled",
	[0x09] = "Compression state not updated",
	[0x0a] = "TCP connection error for CONNECT method",
	[0x0b] = "Processing capacity exceeded",
	[0x0c] = "Negotiated TLS parameters not acceptable",
	[0x0d] = "Use HTTP/1.1 for the request",
}, {
	__index = function(t, k)
		local v = format("Unknown error code: %d", k)
		t[k] = v
		return v
	end,
})

local pseudo_header_server = {
	[":method"] = 0x01,
	[":scheme"] = 0x02,
	[":path"] = 0x04,
	[":authority"] = 0x08,
}

local pseudo_must_mask = 0x07  -- :method, :scheme, :path

-- RFC 7540 Section 8.1.2.2: Connection-specific header fields forbidden in HTTP/2
local forbidden_headers = {
	["connection"] = true,
	["keep-alive"] = true,
	["proxy-connection"] = true,
	["transfer-encoding"] = true,
	["upgrade"] = true,
}

--- @class silly.net.http.h2.channel
--- connection
--- @field scheme string
--- @field remoteaddr string
--- @field conn silly.net.tcp.conn|silly.net.tls.conn
--- streams
--- @field streamidx integer
--- @field streamcount integer
--- @field streams table<integer, silly.net.http.h2.stream>
--- @field streammax integer
--- send control
--- @field framemaxsize integer
--- @field sendbuf string[]
--- @field sendwindow integer
--- @field waitforwrite silly.adt.queue
--- @field initialwindowsize integer
--- recv control
--- @field recvwindebt integer
--- hpack
--- @field sendhpack silly.http2.hpack
--- @field recvhpack silly.http2.hpack
--- misc
--- @field closingq silly.adt.queue
--- @field enablepush boolean
--- @field goaway boolean
local C = {}
local channel_mt = {
	__index = C,
}

--- @class silly.net.http.h2.stream
--- @field channel silly.net.http.h2.channel
--- @field remoteaddr string
--- protocol
--- @field scheme string
--- @field version string
--- @field method string
--- @field path string
--- @field header table<string, string|string[]>
--- @field trailer table<string, string|string[]>
--- @field status integer?
--- @field query table<string, string>?
--- stream
--- @field id integer
--- @field active boolean
--- @field localstate silly.net.http.h2.state
--- @field remotestate silly.net.http.h2.state
--- @field remoteerror string?
--- read
--- @field readco thread?
--- @field readtype silly.net.http.h2.state?
--- @field readneed integer
--- recv(passive read)
--- @field recvbuf silly.adt.buffer
--- @field recvwindebt integer
--- @field recvbytes integer
--- @field recvexpect integer?
--- write
--- @field writeco thread?
--- @field writedat string?
--- @field writeoffset integer
--- @field writelength integer
--- @field writeeoffset boolean
--- @field writeheader string?
--- @field sendwindow integer
local S = {}
local stream_mt = {
	__index = S,
	__close = function(t) t:close() end,
}

--- @class silly.net.http.h2.channel.client: silly.net.http.h2.channel
--- @field dispatchco thread?
--- @field scheme string

--- @class silly.net.http.h2.channel.server: silly.net.http.h2.channel
--- @field handler fun(s:silly.net.http.h2.stream): any

---@param scheme string
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param addr string
---@return silly.net.http.h2.channel
local function newchannel(scheme, conn, addr)
	---@type silly.net.http.h2.channel
	local ch = {
		--- connection
		scheme = scheme,
		conn = conn,
		remoteaddr = addr,
		--- streams
		streamidx = -1,
		streamcount = 0,
		streams = {},
		streammax = max_stream_per_channel,
		--- send control
		initialwindowsize = default_window_size,  -- Stream initial window size (from SETTINGS)
		framemaxsize = default_frame_size,
		sendbuf = {},
		sendwindow = default_window_size,         -- Connection-level send window
		waitforwrite = queue.new(),
		--- recv control
		recvwindebt = 0,
		--- hpack
		sendhpack = hpack_new(default_header_table_size),
		recvhpack = hpack_new(default_header_table_size),
		--- misc
		closingq = queue.new(),
		enablepush = false,
		goaway = false,
	}
	return setmetatable(ch, channel_mt)
end


---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@return integer?, integer?, string?, integer?
local function read_frame(conn)
	local x9, err = conn:read(9)
	if err then
		return nil, nil, nil, nil
	end
	local n, t, f, id = unpack(">I3I1I1I4", x9)
	-- RFC 7540 Section 4.1: Ignore the reserved bit (bit 32) in stream identifier
	id = id & 0x7FFFFFFF
	local dat
	if n > 0 then
		dat, err = conn:read(n)
		if err then
			return nil, nil, nil, nil
		end
	else
		dat = ""
	end
	return t, f, dat, id
end

---@param ch silly.net.http.h2.channel
---@param stream_id integer
---@param flag integer
---@param dat string
---@return string[]?, integer?
local function read_header(ch, stream_id, flag, dat)
	local offset = 1
	local min_length = 0
	if flag & PRIORITY == PRIORITY then
		min_length = min_length + 5
		if #dat < min_length then
			return nil, FRAME_SIZE_ERROR
		end
		-- RFC 7540 Section 5.3.1: A stream cannot depend on itself
		-- Priority data: 4 bytes (E bit + 31-bit dependency) + 1 byte weight
		local dependency = unpack(">I4", dat, offset)
		dependency = dependency & 0x7FFFFFFF  -- Clear E bit, get stream dependency
		if dependency == stream_id then
			return nil, PROTOCOL_ERROR
		end
		offset = offset + 5
	end
	if offset > 1 then
		dat = dat:sub(offset, -1)
	end
	local header_list = {}
	if flag & END_HEADERS == END_HEADERS then --all headers
		local ok = hpack_unpack(ch.recvhpack, dat, header_list)
		if not ok then
			return nil, COMPRESSION_ERROR
		end
	else
		local conn = ch.conn
		local tbl = {dat}
		repeat
			local t, f, d, id = read_frame(conn)
			if not t then
				-- Connection closed/failed
				return nil, nil
			end
			if t ~= FRAME_CONTINUATION or id ~= stream_id then
				-- Interleaved frame of wrong type or on wrong stream is a PROTOCOL_ERROR
				return nil, PROTOCOL_ERROR
			end
			tbl[#tbl + 1] = d
		until f & END_HEADERS == END_HEADERS
		local ok = hpack_unpack(ch.recvhpack, tbl, header_list)
		if not ok then
			return nil, COMPRESSION_ERROR
		end
	end
	return header_list, nil
end

---@param hlist string[]
---@param header table<string, string|string[]>
local function map_header(hlist, header)
	for i = 1, #hlist, 2 do
		local k = hlist[i]
		local v = hlist[i + 1]
		local hv = header[k]
		if hv then
			if type(hv) == "table" then
				hv[#hv + 1] = v
			else
				header[k] = {hv, v}
			end
		else
			header[k] = v
		end
	end
end

---@param hlist string[]
---@param first_header boolean
---@return integer?
local function check_req_header(hlist, first_header)
	local header_mask = 0
	local normal_header_appeared = false
	-- RFC 7540 Section 8.1.2: Header field names MUST be lowercase
	-- RFC 7540 Section 8.1.2.1: Validate pseudo-header fields
	-- RFC 7540 Section 8.1.2.2: Connection-specific header fields
	for i = 1, #hlist, 2 do
		local k = hlist[i]
		local v = hlist[i + 1]
		if k:match("%u") then
			return PROTOCOL_ERROR
		end
		if k:byte(1) == 58 then  -- 58 is ':' in ASCII
			-- RFC 7540 Section 8.1: Trailing header fields MUST NOT include pseudo-header fields
			if not first_header then
				return PROTOCOL_ERROR
			end
			-- RFC 7540 Section 8.1.2.1: Valid request pseudo-headers are :method, :scheme, :authority, :path
			-- RFC 7540 Section 8.1.2.3: Pseudo-headers MUST appear exactly once
			local mask = pseudo_header_server[k]
			if not mask or normal_header_appeared or header_mask & mask ~= 0 then
				-- Unknown or response-only pseudo-header (e.g., :status) in request
				return PROTOCOL_ERROR
			end
			-- RFC 7540 Section 8.1.2.3: :path pseudo-header field MUST NOT be empty
			if k == ":path" and v == "" then
				return PROTOCOL_ERROR
			end
			header_mask = header_mask | mask
		else
			normal_header_appeared = true
			-- RFC 7540 Section 8.1.2.2: Connection-specific header fields MUST NOT be used
			if forbidden_headers[k] then
				return PROTOCOL_ERROR
			end
			-- RFC 7540 Section 8.1.2.2: TE header field MAY contain "trailers" only
			if k == "te" and v ~= "trailers" then
				return PROTOCOL_ERROR
			end
		end
	end
	-- RFC 7540 Section 8.1.2.3:
	-- All HTTP/2 requests MUST include exactly one valid value for the
	-- :method, :scheme, and :path pseudo-header fields
	-- This check only applies to initial headers, not trailers
	if first_header and (header_mask & pseudo_must_mask) ~= pseudo_must_mask then
		-- Missing one of :method, :scheme, or :path
		return PROTOCOL_ERROR
	end
	return nil
end

local function check_content_length(header)
	local clen = header['content-length']
	if not clen then
		return true, nil
	end
	clen = tonumber(clen)
	if not clen or clen < 0 then
		return false, PROTOCOL_ERROR
	end
	return true, clen
end

------------channel functions

local function channel_newstream(ch, id, active, method, path, header)
	---@type silly.net.http.h2.stream
	local stream = {
		channel = ch,
		remoteaddr = ch.remoteaddr,
		-- protocol
		scheme = ch.scheme,
		version = "HTTP/2",
		method = method,
		path = path,
		header = header,
		trailer = {},
		status = nil,
		-- stream
		id = id,
		active = active,
		localstate = STATE_NONE,
		remotestate = STATE_NONE,
		remoteerror = nil,
		-- read
		readco = nil,
		readtype = nil,
		readneed = 0,
		-- recv(passive read)
		recvbuf = buffer.new(),
		recvwindebt = 0,
		recvbytes = 0,
		recvexpect = nil,
		-- write
		writeco = nil,
		writedat = nil,
		writeoffset = 0,
		writelength = 0,
		writeeoffset = false,
		writeheader = nil,
		sendwindow = ch.initialwindowsize,  -- Stream-level send window
	}
	setmetatable(stream, stream_mt)
	return stream
end

---@param ch silly.net.http.h2.channel
local function channel_flushwrite(ch)
	local sendbuf = ch.sendbuf
	local windebt = ch.recvwindebt
	local n = #sendbuf
	if windebt > 0 then
		sendbuf[n + 1] = build_winupdate(0, 0, windebt)
		ch.recvwindebt = 0
		n = n + 1
	end
	if n == 0 then
		return
	end
	local conn = ch.conn
	if conn then
		conn:write(sendbuf)
	end
	for i = 1, n do
		sendbuf[i] = nil
	end
end

---@param ch silly.net.http.h2.channel
---@param dat string
local function channel_write(ch, dat)
	local buf = ch.sendbuf
	local n = #buf
	buf[n + 1] = dat
	if n == 0 and ch.recvwindebt == 0 then
		silly.fork(channel_flushwrite, ch)
	end
end

---@param ch silly.net.http.h2.channel
---@param increment integer
local function channel_windebt(ch, increment)
	if increment == 0 then
		return
	end
	local n = ch.recvwindebt
	n = n + increment
	ch.recvwindebt = n
	if n == increment and #ch.sendbuf == 0 then
		silly.fork(channel_flushwrite, ch)
	end
end

---@param ch silly.net.http.h2.channel
---@param errorcode integer
local function channel_goaway(ch, errorcode)
	ch.goaway = true
	if errorcode == NO_ERROR then
		channel_write(ch, build_goaway(ch.streamidx, errorcode))
		return
	end
	local buf = ch.sendbuf
	for i = 1, #buf do
		buf[i] = nil
	end
	channel_write(ch, build_goaway(ch.streamidx, errorcode))
	channel_flushwrite(ch)
	ch.conn:close()
	ch.conn = nil
	--TODO: wakeup all stream
end

---@param ch silly.net.http.h2.channel
function C.isfull(ch)
	return ch.streamcount >= ch.streammax
end

---@param ch silly.net.http.h2.channel
function C.isalive(ch)
	local conn = ch.conn
	return conn and conn:isalive() and ch.streamidx < MAX_STREAM_ID
end

---@param ch silly.net.http.h2.channel
function C.isidle(ch)
	return ch.streamcount == 0
end

---@param ch silly.net.http.h2.channel
---@return silly.net.http.h2.stream?, string?
function C.openstream(ch)
	if ch.streamcount >= ch.streammax then
		return nil, "stream count exceeded"
	end
	local id = ch.streamidx
	-- RFC 7540: Stream identifiers cannot be reused
	-- If we've exhausted the stream ID space, the connection must be closed
	if id >= MAX_STREAM_ID then
		return nil, "stream id exhausted"
	end
	id = id + 2
	local stream = channel_newstream(ch, id, true, "", "", {})
	ch.streamidx = id
	ch.streams[id] = stream
	ch.streamcount = ch.streamcount + 1
	return stream, nil
end

---@param ch silly.net.http.h2.channel
function C.close(ch)
	local conn = ch.conn
	if not conn then
		return
	end
	ch.conn = nil
	conn:close()
	local t = ch.streams
	for k, v in pairs(t) do
		t[k] = nil
		local co = v.readco
		if co then
			v.readco = nil
			wakeup(co, "channel closed")
		end
		co = v.writeco
		if co then
			v.writeco = nil
			wakeup(co, "channel closed")
		end
		v.channel = nil
		v.localstate = STATE_RST
		v.remotestate = STATE_RST
		v.remoteerror = "channel closed"
	end
	ch.streamcount = 0
end

---------------------------stream

---@param s silly.net.http.h2.stream
---@param dat string|table|nil
local function stream_readwakeup(s, dat)
	local co = s.readco
	if co then
		s.readtype = nil
		s.readco = nil
		s.readneed = 0
		wakeup(co, dat)
	end
end

---@param s silly.net.http.h2.stream
local function read_timer(s)
	stream_readwakeup(s, TIMEOUT)
end

local function stream_flushdebt(s)
	local recvwindebt = s.recvwindebt
	if recvwindebt > 0 then
		s.recvwindebt = 0
		channel_write(s.channel, build_winupdate(s.id, 0, recvwindebt))
	end
end

---@param s silly.net.http.h2.stream
---@param state silly.net.http.h2.state
---@param size integer
---@param timeout integer?
---@return string?, string? error
local function stream_readwait(s, state, size, timeout)
	local dat
	stream_flushdebt(s)
	s.readtype = state
	s.readneed = size
	s.readco = silly.running()
	if timeout then
		local timer = time.after(timeout, read_timer, s)
		dat = silly.wait()
		if dat == TIMEOUT then
			return nil, "read timeout"
		end
		time.cancel(timer)
	else
		dat = silly.wait()
	end
	if dat then
		return dat, nil
	end
	return nil, s.remoteerror
end

---@param s silly.net.http.h2.stream
---@param data string
---@param endstream boolean
---@return boolean, string?
local function stream_writewait(s, data, endstream)
	assert(not s.writeco, "[silly.net.http.h2] write can't be called in race")
	local ch = s.channel
	local swin = s.sendwindow
	local chwin = ch.sendwindow
	local dlen = #data
	local win = swin < chwin and swin or chwin
	if win >= dlen then
		s.sendwindow = swin - dlen
		ch.sendwindow = chwin - dlen
		channel_write(ch, build_body(s.id, ch.framemaxsize, data, endstream))
		return true, nil
	end
	channel_write(ch, build_body(s.id, ch.framemaxsize, data, false, 0, win))
	swin = swin - win
	chwin = chwin - win
	ch.sendwindow = chwin
	s.sendwindow = swin
	s.writedat = data
	s.writeoffset = win
	s.writelength = dlen - win
	s.writeeoffset = endstream
	if chwin <= 0 then
		ch.waitforwrite:push(s)
	end
	s.writeco = silly.running()
	local err = silly.wait()
	if err then
		s.remoteerror = err
		return false, err
	end
	assert(s.writelength == 0)
	return true, nil
end

---@param s silly.net.http.h2.stream
---@param err string?
local function stream_writewakeup(s, err)
	local co = s.writeco
	if co then
		s.writedat = nil
		s.writeoffset = 0
		s.writelength = 0
		s.writeeoffset = false
		s.writeco = nil
		wakeup(co, err)
	end
end

---@param id integer
---@param ch silly.net.http.h2.channel
---@param errorcode integer
local function stream_reset(id, ch, errorcode)
	channel_write(ch, build_rst(id, errorcode))
	local s = ch.streams[id]
	if not s then
		return
	end
	local err = err_str[errorcode]
	s.localstate = STATE_RST
	s.remoteerror = "local reset"
	stream_readwakeup(s, nil)
	stream_writewakeup(s, err)
end

---@param s silly.net.http.h2.stream
---@param state silly.net.http.h2.state
---@param err string
local function stream_remoteend(s, state, err)
	s.remotestate = state
	s.remoteerror = err
	if state == STATE_END then
		-- RFC 7540 Section 8.1.2.6: Validate content-length matches actual received length
		if s.recvexpect and s.recvbytes ~= s.recvexpect then
			channel_goaway(s.channel, PROTOCOL_ERROR)
			return
		end
		local readtype = s.readtype
		if readtype == STATE_CLOSE then
			stream_readwakeup(s, s.recvbuf:readall())
		else
			stream_readwakeup(s, nil)
		end
		stream_writewakeup(s, err)
	else
		stream_readwakeup(s, nil)
		stream_writewakeup(s, err)
	end

end

---@param s silly.net.http.h2.stream
local function stream_trysend(s)
	local sendinglen = s.writelength
	if sendinglen == 0 then
		return
	end
	local ch = s.channel
	local swin = s.sendwindow
	local chwin = ch.sendwindow
	local win = swin < chwin and swin or chwin
	if win <= 0 then
		return
	end
	local sendingdat = s.writedat
	local sendingoff = s.writeoffset
	if win > sendinglen then
		win = sendinglen
	end
	s.sendwindow = s.sendwindow - win
	ch.sendwindow = ch.sendwindow - win
	local left = sendinglen - win
	local endstream = left == 0 and s.writeeoffset
	channel_write(ch, build_body(s.id, ch.framemaxsize, sendingdat, endstream, sendingoff, win))
	s.writeoffset = sendingoff + win
	s.writelength = left
	if left == 0 then
		stream_writewakeup(s, nil)
	elseif ch.sendwindow <= 0 then
		ch.waitforwrite:push(s)
	end
end

---@param s silly.net.http.h2.stream
---@param method string
---@param path string
---@param header table<string, string|string[]>
function S.request(s, method, path, header)
	local ch = s.channel
	s.method = method
	s.path = path
	local host = header["host"]
	header["host"] = nil
	s.writeheader = hpack_pack(ch.sendhpack, header,
		":authority", host,
		":method", s.method,
		":path", s.path,
		":scheme", ch.scheme)
	return true, nil
end

---@param s silly.net.http.h2.stream
---@param status integer
---@param header table<string, string|string[]|number>
---@return boolean, string|?
function S.respond(s, status, header)
	local ch = s.channel
	if not ch then
		return false, s.remoteerror
	end
	s.status = status
	s.writeheader = hpack_pack(ch.sendhpack, header, ":status", s.status)
	return true, nil
end

function S.flush(s)
	local header = s.writeheader
	if not header then
		return
	end
	local ch = s.channel
	if not ch then
		return
	end
	s.writeheader = nil
	local dat = build_header(s.id, ch.framemaxsize, header, false)
	channel_write(ch, dat)
end

---@param s silly.net.http.h2.stream
---@param data string
---@return boolean, string?
function S.write(s, data)
	if not data or #data == 0 then
		return true, nil
	end
	if s.localstate >= STATE_CLOSE then
		return false, "local closed"
	end
	local ch = s.channel
	if not ch then
		return false, s.remoteerror
	end
	local header = s.writeheader
	if header then
		s.writeheader = nil
		local dat = build_header(s.id, ch.framemaxsize, header, false)
		channel_write(ch, dat)
	end
	return stream_writewait(s, data, false)
end

---@param s silly.net.http.h2.stream
---@param data string|nil
---@param trailer table<string, string|string[]|number>|nil
function S.closewrite(s, data, trailer)
	if s.localstate >= STATE_CLOSE then
		return false, "local closed"
	end
	s.localstate = STATE_END
	local empty = not (data or trailer)
	local ch = s.channel
	local header = s.writeheader
	if header then
		s.writeheader = nil
		local dat = build_header(s.id, ch.framemaxsize, header, empty)
		channel_write(s.channel, dat)
	elseif empty then
		channel_write(ch, build_body(s.id, ch.framemaxsize, "", true))
	end
	if data then
		local ok, err = stream_writewait(s, data, not trailer)
		if not ok then
			return false, err
		end
	end
	if trailer then
		local ch = s.channel
		local hdr = hpack_pack(ch.sendhpack, trailer)
		local dat = build_header(s.id, ch.framemaxsize, hdr, true)
		channel_write(ch, dat)
	end
end

---@param s silly.net.http.h2.stream
---@param timeout integer? --ms
---@return boolean, string? error
function S.waitresponse(s, timeout)
	if s.remotestate < STATE_HEADER then
		local dat, err = stream_readwait(s, STATE_HEADER, 0, timeout)
		if not dat then
			return false, err
		end
	end
	return true, nil
end

---@param s silly.net.http.h2.stream
function S.close(s)
	local ch = s.channel
	if not ch then
		return
	end
	-- Only send RST_STREAM if we haven't already closed locally
	-- If localstate < STATE_CLOSE, we haven't sent END_STREAM or RST yet
	-- If remotestate < STATE_CLOSE, remote hasn't closed yet
	if s.remotestate >= STATE_CLOSE then
		s:closewrite()
		ch.streams[s.id] = nil
		s.channel = nil
		return
	end
	stream_reset(s.id, ch, CANCEL)
	local streams = ch.streams
	local closingq = ch.closingq
	local n = closingq:push(s)
	for i = CLOSED_STREAM_COUNT+1, n do
		local s = closingq:pop()
		streams[s.id] = nil
		s.channel = nil
	end
end

---@param s silly.net.http.h2.stream
---@param size integer
---@param timeout integer? --ms
---@return string?, string? error
function S.read(s, size, timeout)
	local recvbuf = s.recvbuf
	local dat = recvbuf:read(size)
	if dat then
		stream_flushdebt(s)
		return dat, nil
	end
	local remotestate = s.remotestate
	if remotestate == STATE_END then
		return "", "end of stream"
	elseif remotestate == STATE_RST then
		return nil, s.remoteerror
	end
	return stream_readwait(s, STATE_DATA, size, timeout)
end

---@param s silly.net.http.h2.stream
---@param timeout integer? --ms
---@return string?, string?
function S.readall(s, timeout)
	local remotestate = s.remotestate
	if remotestate >= STATE_CLOSE then
		local dat = s.recvbuf:readall()
		if #dat > 0 then
			return dat, nil
		end
		if remotestate == STATE_END then
			return "", "end of stream"
		else
			return nil, s.remoteerror
		end
	end
	return stream_readwait(s, STATE_CLOSE, 0, timeout)
end

---@param s silly.net.http.h2.stream
function S.eof(s)
	return s.remotestate == STATE_END
end
-----------------------------frame functions-------------------------------
---@param ch silly.net.http.h2.channel
---@param increment integer
local function channel_winupdate(ch, increment)
	-- Connection-level WINDOW_UPDATE: update connection send window
	local owindow = ch.sendwindow
	local nwindow = owindow + increment
	-- RFC 7540 Section 6.9.1: Window size MUST NOT exceed 2^31-1
	if nwindow > 0x7FFFFFFF then
		channel_goaway(ch, FLOW_CONTROL_ERROR)
		return
	end
	ch.sendwindow = nwindow
	if increment <= 0 then
		return
	end
	local waitq = ch.waitforwrite
	while true do
		local s = waitq:pop()
		if not s then
			break
		end
		stream_trysend(s)
	end
end

---@param s silly.net.http.h2.stream
---@param increment integer
local function stream_winupdate(s, increment)
	-- Connection-level WINDOW_UPDATE: update connection send window
	local owindow = s.sendwindow
	local nwindow = owindow + increment
	-- RFC 7540 Section 6.9.1: Window size MUST NOT exceed 2^31-1
	if nwindow > 0x7FFFFFFF then
		stream_reset(s.id, s.channel, FLOW_CONTROL_ERROR)
		return
	end
	s.sendwindow = nwindow
	if increment > 0 then
		stream_trysend(s)
	end
end

---@param ch silly.net.http.h2.channel
---@param id integer
---@param flag integer
---@param dat string
local function frame_data(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	-- RFC 7540 Section 5.1: Check stream state
	if not s or s.remotestate >= STATE_CLOSE then
		-- Stream is idle. Receiving DATA is a connection error.
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	channel_windebt(ch, #dat)
	s.remotestate = STATE_DATA
	local readtype = s.readtype
	local endstream = flag & END_STREAM == END_STREAM
	if #dat > 0 then
		local total = s.recvbuf:append(dat)
		-- RFC 7540 Section 8.1.2.6: Track received data length for content-length validation
		s.recvbytes = s.recvbytes + #dat
		if readtype == STATE_DATA and total < s.readneed or readtype == STATE_CLOSE then
			channel_write(ch, build_winupdate(id, 0, #dat))
		else
			s.recvwindebt = s.recvwindebt + #dat
		end
		if readtype == STATE_DATA and total >= s.readneed then
			stream_readwakeup(s, s.recvbuf:read(s.readneed))
		end
	end
	if endstream then
		stream_remoteend(s, STATE_END, "end of stream")
	end
end

---@param ch silly.net.http.h2.channel
---@param stream_id integer
---@param flag integer
---@param dat string
local function frame_settings(ch, stream_id, flag, dat)
	-- RFC 7540 Section 6.5: SETTINGS frames MUST be sent on stream 0
	if stream_id ~= 0 then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end

	-- RFC 7540 Section 6.5.3: ACK SETTINGS frames must have empty payload
	if flag & ACK == ACK then
		if #dat ~= 0 then
			channel_goaway(ch, FRAME_SIZE_ERROR)
			return
		end
		return
	end

	-- RFC 7540 Section 6.5: SETTINGS frames are composed of zero or more parameters
	-- Each parameter is 6 octets (2 octets identifier + 4 octets value)
	if #dat % 6 ~= 0 then
		channel_goaway(ch, FRAME_SIZE_ERROR)
		return
	end

	for i = 1, #dat, 6 do
		local id, val = unpack(">I2I4", dat, i)
		-- RFC 7540 Section 6.5.2: Validate SETTINGS parameter values
		if id == SETTINGS_ENABLE_PUSH then
			-- SETTINGS_ENABLE_PUSH can only be 0 or 1
			if val ~= 0 and val ~= 1 then
				channel_goaway(ch, PROTOCOL_ERROR)
				return
			end
			ch.enablepush = (val == 1)
		elseif id == SETTINGS_INITIAL_WINDOW_SIZE  then
			-- SETTINGS_INITIAL_WINDOW_SIZE: max value is 2^31-1 (0x7FFFFFFF)
			if val > 0x7FFFFFFF then
				channel_goaway(ch, FLOW_CONTROL_ERROR)
				return
			end
			-- RFC 7540 Section 6.9.2: Adjust all existing stream windows by the difference
			local delta = val - ch.initialwindowsize
			ch.initialwindowsize = val
			if delta ~= 0 then
				for _, s in pairs(ch.streams) do
					stream_winupdate(s, delta)
				end
			end
		elseif id == SETTINGS_MAX_FRAME_SIZE then
			-- SETTINGS_MAX_FRAME_SIZE: must be between 2^14 (16384) and 2^24-1 (16777215)
			if val < 16384 or val > 16777215 then
				channel_goaway(ch, PROTOCOL_ERROR)
				return
			end
			ch.framemaxsize = val
		elseif id == SETTINGS_HEADER_TABLE_SIZE then
			hpack_hardlimit(ch.recvhpack, val)
		elseif id == SETTINGS_MAX_CONCURRENT then
			ch.streammax = val
		elseif id == SETTINGS_MAX_HEADER_LIST_SIZE then
			-- SETTINGS_MAX_HEADER_LIST_SIZE is advisory only, no error checking needed
		else
			logger.warn("[h2stream] unknown settings id:", id)
		end
	end
	-- RFC 7540 Section 6.5.3: Must immediately emit a SETTINGS frame with ACK flag
	channel_write(ch, build_setting(ACK))
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param dat string
local function frame_priority(ch, streamid, _, dat)
	-- RFC 7540 Section 6.3: PRIORITY frame always identifies a stream
	-- If received with stream identifier 0x0, this is a connection error
	if streamid == 0 then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 5.3.1: A stream cannot depend on itself
	-- PRIORITY frame payload: 5 bytes (4 bytes dependency + 1 byte weight)
	if #dat ~= 5 then
		-- Invalid frame size
		channel_goaway(ch, FRAME_SIZE_ERROR)
		return
	end
	local dependency = unpack(">I4", dat)
	dependency = dependency & 0x7FFFFFFF  -- Clear E bit
	if dependency == streamid then
		-- Stream depends on itself
		stream_reset(streamid, ch, PROTOCOL_ERROR)
		return
	end
	-- We don't implement priority, so just ignore it
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param flag integer
---@param dat string
local function frame_ping(ch, streamid, flag, dat)
	-- RFC 7540 Section 6.7: PING frames are not associated with any individual stream
	-- If a PING frame is received with a stream identifier field value other than 0x0,
	-- the recipient MUST respond with a connection error of type PROTOCOL_ERROR
	if streamid ~= 0 then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 6.7: PING frames MUST contain exactly 8 bytes
	if #dat ~= 8 then
		channel_goaway(ch, FRAME_SIZE_ERROR)
		return
	end
	-- RFC 7540 Section 6.7: If ACK flag is set, do not respond
	if flag & ACK == ACK then
		-- This is a PING response, do nothing
		return
	end
	-- Send PING response with ACK flag
	channel_write(ch, pack(">I3I1I1I4", #dat, FRAME_PING, ACK, 0) .. dat)
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param dat string
local function frame_rst(ch, streamid, _, dat)
	local s = ch.streams[streamid]
	if not s then
		-- RST_STREAM on an idle stream is a connection error.
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 6.4: RST_STREAM frames MUST be 4 octets in length
	if #dat ~= 4 then
		channel_goaway(ch, FRAME_SIZE_ERROR)
		return
	end
	stream_remoteend(s, STATE_RST, err_str[unpack(">I4", dat)])
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
local function frame_goaway(ch, streamid, _, _)
	-- RFC 7540 Section 6.8: GOAWAY frames MUST be sent on stream 0
	if streamid ~= 0 then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	ch.goaway = true
end

---@param ch silly.net.http.h2.channel
---@param id integer
---@param flag integer
---@param dat string
local function frame_winupdate(ch, id, flag, dat)
	-- RFC 7540 Section 6.9: WINDOW_UPDATE frames MUST be 4 octets in length
	if #dat ~= 4 then
		channel_goaway(ch, FRAME_SIZE_ERROR)
		return
	end
	local increment = unpack(">I4", dat)
	-- RFC 7540 Section 6.9.1: Flow control window increment of 0 MUST be treated as error
	if id == 0 then
		if increment == 0 then
			-- Connection-level WINDOW_UPDATE with increment=0 is a connection error
			channel_goaway(ch, PROTOCOL_ERROR)
			return
		end
		channel_winupdate(ch, increment)
	else
		-- Stream-level WINDOW_UPDATE: update stream send window
		local s = ch.streams[id]
		if not s then
			-- RFC 7540 Section 6.9: WINDOW_UPDATE for a closed stream should be ignored
			-- Only WINDOW_UPDATE for an idle stream (never existed) is a connection error
			if id > ch.streamidx then
				-- Stream ID is greater than any we've seen, this is an idle stream
				channel_goaway(ch, PROTOCOL_ERROR)
			end
			-- Ignore WINDOW_UPDATE for closed streams
			return
		end
		if increment == 0 then
			-- Stream-level WINDOW_UPDATE with increment=0 is a stream error
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		stream_winupdate(s, increment)
	end
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param flag integer
---@param dat string
local function frame_continuation(ch, streamid, flag, dat)
	-- RFC 7540 Section 6.10: CONTINUATION frames are only valid following
	-- HEADERS/PUSH_PROMISE without END_HEADERS. Legal CONTINUATION frames
	-- are consumed internally by try_read_header().
	-- If we see one here, it's orphaned (appears after END_HEADERS).
	channel_goaway(ch, PROTOCOL_ERROR)
end

------------------------------------client/server handshake------------------------------------
local M = {}

---@param args {ch: silly.net.http.h2.channel, frame_process: table}
local function common_dispatch(args)
	local ch = args.ch
	local frame_process = args.frame_process
	local conn = ch.conn
	while true do
		local t,f,d,id = read_frame(conn)
		if not t then
			break
		end
		-- Validate frame size according to SETTINGS_MAX_FRAME_SIZE
		local frame_len = #d
		if frame_len > ch.framemaxsize then
			-- Send GOAWAY with FRAME_SIZE_ERROR
			channel_goaway(ch, FRAME_SIZE_ERROR)
			break
		end
		-- RFC 7540 Section 6.1: Validate padding
		if f & PADDED == PADDED then
			if #d < 1 then
				-- Frame too small to contain pad length
				channel_goaway(ch, PROTOCOL_ERROR)
				break
			end
			local pad_length = unpack(">I1", d)
			-- Padding length must be less than frame payload length
			if pad_length >= #d then
				-- Invalid pad length
				channel_goaway(ch, PROTOCOL_ERROR)
				break
			end
			-- Remove pad length byte and padding
			d = d:sub(2, -(pad_length + 1))
		end
		local func = frame_process[t]
		if func then
			func(ch, id, f, d)
		end
	end
	ch:close()
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param flag integer
---@param dat string
local function frame_header_client(ch, streamid, flag, dat)
	local s = ch.streams[streamid]
	if not s then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	local remotestate = s.remotestate
	-- RFC 7540: Check stream state
	if remotestate >= STATE_CLOSE then
		channel_goaway(ch, STREAM_CLOSED)
		return
	end
	local hlist, err = read_header(ch, streamid, flag, dat)
	if not hlist then
		channel_goaway(ch, err)
		return
	end
	local ok, clen = check_content_length(hlist)
	if not ok then
		channel_goaway(ch, err)
		return
	end
	if remotestate == STATE_NONE then
		local header = s.header
		s.remotestate = STATE_HEADER
		map_header(hlist, header)
		local status = header[":status"]
		header[":status"] = nil
		s.recvexpect = clen
		s.status = tonumber(status)
		if s.readtype == STATE_HEADER then
			stream_readwakeup(s, "")
		end
	else
		s.remotestate = STATE_TRAILER
		map_header(hlist, s.trailer)
	end
	if flag & END_STREAM == END_STREAM then
		stream_remoteend(s, STATE_END, "end of stream")
	end
end

local frame_client = {
	[FRAME_HEADERS] = frame_header_client,
	[FRAME_DATA] = frame_data,
	[FRAME_PRIORITY] = frame_priority,
	[FRAME_RST] = frame_rst,
	[FRAME_SETTINGS] = frame_settings,
	[FRAME_PING] = frame_ping,
	[FRAME_GOAWAY] = frame_goaway,
	[FRAME_WINUPDATE] = frame_winupdate,
	[FRAME_CONTINUATION] = frame_continuation,
}

---@param ch silly.net.http.h2.channel.client
local function handshake_as_client(ch)
	local conn = ch.conn
	local ok, err = conn:write {
		client_preface,
		build_setting(0x0,
			SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, max_stream_per_channel,
			SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
		),
	}
	if not ok then
		return false, err
	end
	local t, f, dat, id = read_frame(conn)
	if not t or t ~= FRAME_SETTINGS then
		return false, "expect settings"
	end
	frame_settings(ch, id, f, dat)
	local ok, err = conn:write(build_setting(0x01))
	if not ok then
		return false, err
	end
	while true do
		local t,f,dat,id = read_frame(conn)
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
	ch.dispatchco = silly.fork(common_dispatch, {ch = ch, frame_process = frame_client})
	return true, nil
end

---@param s silly.net.http.h2.stream
local function server_handler(s)
	local ch = s.channel
	if not ch then
		return
	end
	---@cast ch silly.net.http.h2.channel.server
	ch.handler(s)
	s:closewrite()
	s:close()
end

---@param ch silly.net.http.h2.channel.server
local function frame_header_server(ch, id, flag, dat)
	local hlist, errcode = read_header(ch, id, flag, dat)
	if not hlist then
		-- RFC 7540 Section 4.3: COMPRESSION_ERROR is a connection error
		channel_goaway(ch, errcode)
		return
	end
	local s = ch.streams[id]
	local first_header = not s
	if ch.goaway and first_header then
		stream_reset(id, ch, PROTOCOL_ERROR)
		return
	end
	if not first_header and s.remotestate >= STATE_CLOSE then
		channel_goaway(ch, STREAM_CLOSED)
		return
	end
	local err = check_req_header(hlist, first_header)
	if err then
		-- RFC 7540 Section 8.1.2: Invalid request headers are stream errors
		stream_reset(id, ch, PROTOCOL_ERROR)
		return
	end
	if first_header then
		-- RFC 7540 Section 5.1.1: Validate stream identifier
		-- 1. Client-initiated streams MUST use odd-numbered identifiers
		if id % 2 == 0 then
			channel_goaway(ch, PROTOCOL_ERROR)
			return
		end
		-- 2. Stream identifier MUST be numerically greater than all previous streams
		local stream_max = ch.streammax
		local stream_idx = ch.streamidx
		local stream_count = ch.streamcount
		if id <= stream_idx then
			-- Stream ID went backwards - connection error (PROTOCOL_ERROR)
			channel_goaway(ch, STREAM_CLOSED)
			return
		elseif id == stream_idx then
			-- id == stream_idx, stream was already used and closed - stream error
			stream_reset(id, ch, STREAM_CLOSED)
			return
		end
		-- RFC 7540 Section 5.1.2: Check concurrent stream limit
		-- Streams in "open" or "half-closed" states count toward the limit
		if stream_count >= stream_max then
			-- Exceeded advertised concurrent stream limit
			stream_reset(id, ch, REFUSED_STREAM)
			return
		end
		ch.streamidx = id
		ch.streamcount = stream_count + 1
		local header = {}
		map_header(hlist, header)
		local ok, clen = check_content_length(header)
		if not ok then
			stream_reset(id, ch, err)
			return
		end
		local path, query = parsetarget(header[':path'])
		local s = channel_newstream(ch, id, false, header[':method'], path, header)
		s.recvexpect = clen
		s.query = query
		if flag & END_STREAM == END_STREAM then
			-- RFC 7540 Section 8.1.2.6: Validate content-length for requests without body
			stream_remoteend(s, STATE_END, "end of stream")
		else
			s.remotestate = STATE_HEADER
		end
		ch.streams[id] = s
		silly.fork(server_handler, s)
	else
		-- RFC 7540 Section 8.1: Trailing header blocks MUST have END_STREAM flag
		if flag & END_STREAM ~= END_STREAM then
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		-- RFC 7540 Section 8.1: Trailing header fields MUST NOT include pseudo-header fields
		local err = check_req_header(hlist, false)
		if err then
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		map_header(hlist, s.trailer)
		stream_remoteend(s, STATE_END, "end of stream")
	end
end


local frame_server = {
	[FRAME_HEADERS] = frame_header_server,
	[FRAME_DATA] = frame_data,
	[FRAME_PRIORITY] = frame_priority,
	[FRAME_RST] = frame_rst,
	[FRAME_SETTINGS] = frame_settings,
	[FRAME_PING] = frame_ping,
	[FRAME_GOAWAY] = frame_goaway,
	[FRAME_WINUPDATE] = frame_winupdate,
	[FRAME_CONTINUATION] = frame_continuation,
	[FRAME_PUSHPROMISE] = function(ch, id, f, d)
		-- RFC 7540 Section 8.2: A client cannot push.
		-- Servers MUST treat the receipt of a PUSH_PROMISE frame as a connection error.
		channel_goaway(ch, PROTOCOL_ERROR)
	end,
}

---@param ch silly.net.http.h2.channel.server
local function handshake_as_server(ch)
	local conn = ch.conn
	-- According to RFC 7540, server must validate connection preface BEFORE sending SETTINGS
	-- If preface is invalid, server should send GOAWAY with PROTOCOL_ERROR
	local dat = conn:read(client_preface_size)
	if not dat then
		return false
	end
	if dat ~= client_preface then
		-- Send GOAWAY with PROTOCOL_ERROR before closing
		channel_goaway(ch, PROTOCOL_ERROR)
		return false
	end

	-- Only after valid preface, send SETTINGS frame
	dat = build_setting(0x0,
		SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, max_stream_per_channel,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	conn:write(dat)
	local t,f,dat,id = read_frame(conn)
	if not t or t ~= FRAME_SETTINGS then
		return false
	end
	frame_settings(ch, id, f, dat)
	conn:write(build_setting(0x01))
	while true do
		local t,f,dat,id = read_frame(conn)
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
	return true, nil
end

---@param scheme string
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param addr string
---@return silly.net.http.h2.channel.client?, string? error
function M.newchannel(scheme, conn, addr)
	local ch = newchannel(scheme, conn, addr)
	--- @cast ch silly.net.http.h2.channel.client
	ch.scheme = scheme
	local ok, err = handshake_as_client(ch)
	if ok then
		return ch, nil
	end
	return nil, err
end

---@param handler fun(s:silly.net.http.h2.stream)
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param addr string
function M.httpd(handler, conn, addr)
	local ch = newchannel("https", conn, addr)
	--- @cast ch silly.net.http.h2.channel.server
	ch.handler = handler
	local ok = handshake_as_server(ch)
	if ok then
		common_dispatch({ch = ch, frame_process = frame_server})
	end
end

return M
