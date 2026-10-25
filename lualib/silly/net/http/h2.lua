local silly = require "silly"
local task = require "silly.task"
local base64 = require "silly.encoding.base64"
local time = require "silly.time"
local buffer = require "silly.adt.buffer"
local queue = require "silly.adt.queue"
local logger = require "silly.logger"
local helper = require "silly.net.http.helper"
local hpack = require "silly.http2.hpack"
local builder = require "silly.http2.framebuilder"
local errno = require "silly.errno"

local type = type
local error = error
local pairs = pairs
local tonumber = tonumber
local tointeger = math.tointeger
local sub = string.sub
local format = string.format
local concat = table.concat
local wakeup = task.wakeup
local unpack = string.unpack
local EEOF<const> = errno.EOF
local ETIMEDOUT<const> = errno.TIMEDOUT
local setmetatable = setmetatable
local parsetarget = helper.parsetarget
local pcall = silly.pcall

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
local build_ping = builder.ping

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

local GOAWAY_LOCAL<const> = 1
local GOAWAY_REMOTE<const> = 2

local STATE_NONE<const>			= 0x00
local STATE_HEADER<const>               = 0x01
local STATE_DATA <const>                = 0x02
local STATE_TRAILER <const>             = 0x03
local STATE_CLOSE<const>		= 0x10
local STATE_END<const>		        = STATE_CLOSE | 0x01
local STATE_RST<const>		        = STATE_CLOSE | 0x02

--- @alias silly.net.http.h2.state `STATE_NONE` | `STATE_HEADER` | `STATE_DATA` | `STATE_TRAILER` | `STATE_CLOSE` | `STATE_END` | `STATE_RST`

local max_header_wire_size<const> = 65535
local max_header_list_size<const> = 65535
local default_header_table_size<const> = 4096
local default_frame_size<const> = 16384
local default_window_size<const> = 65535
local stream_init_window_size <const> = default_window_size
local max_window_size<const> = 0x7fffffff
local channel_init_window_size<const> = 4*1024*1024 - default_window_size
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

local MAX_STREAM_ID<const> = 0x7fffffff
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
local pseudo_connect_mask = 0x09  -- :method, :authority

-- RFC 7540 Section 8.1.2.2: Connection-specific header fields forbidden in HTTP/2
local forbidden_headers = {
	["connection"] = true,
	["keep-alive"] = true,
	["proxy-connection"] = true,
	["transfer-encoding"] = true,
	["upgrade"] = true,
}

global _

--- @class silly.net.http.h2.waiter
--- @field package waitq silly.adt.queue<silly.net.http.h2.waiter>
--- @field package co thread? -- Present while queued; cleared before wakeup.
--- @field package err string? -- Failure reason, set before waking with nil.
--- @field package exception string? -- Encoding exception, rethrown by the requester.
--- @field package method string
--- @field package path string
--- @field package header table
--- @field package endstream boolean?

--- @class silly.net.http.h2.channel
--- connection
--- @field scheme string
--- @field conn silly.net.tcp.conn|silly.net.tls.conn|nil -- Cleared after transport closure
--- @field authority string
--- @field package writeco thread? -- Scheduled connection flush
--- @field package isclient boolean -- Fixed channel role, independent of queues and transport lifetime
--- streams
--- @field package streamidx integer -- Highest locally initiated stream ID queued for sending
--- @field package laststreamid integer -- Highest peer-initiated stream ID seen; used in outgoing GOAWAY. Client stays at 0 because push is disabled.
--- @field package streamcount integer -- Protocol-active streams, independent of application ownership
--- @field package streammax integer -- Peer limit on locally initiated concurrent streams
--- @field package streams table<integer, silly.net.http.h2.stream>
--- send control
--- @field package sendframemaxsize integer
--- @field package sendbuf string[]
--- @field package sendwindow integer
--- @field package sendwaitq silly.adt.queue<silly.net.http.h2.stream> -- Streams waiting for connection send credit
--- @field package initialwindowsize integer
--- recv control
--- @field package recvframemaxsize integer
--- @field package recvwindebt integer
--- @field package recvwindowsize integer -- Connection receive capacity, expanded after handshake
--- hpack
--- @field package sendhpack silly.http2.hpack
--- @field package recvhpack silly.http2.hpack
--- misc
--- @field package errstr string? -- Shutdown reason for GOAWAY or transport failure
--- @field package enablepush boolean
--- @field package goaway integer -- GOAWAY_LOCAL (sent) | GOAWAY_REMOTE (received)
--- @field package goawaylast integer? -- Last stream ID received in peer GOAWAY
--- @field package goawaysentlast integer? -- Preserve the cutoff when sending a later error GOAWAY
--- @field package lastrecvtime integer
--- @field package keepaliveinterval integer?
--- @field package keepalivetimeout integer?
--- @field package keepalivewhileidle boolean?
--- @field package timer integer?
--- @field package pingtoken string?
--- @field package openwaitq silly.adt.queue<silly.net.http.h2.waiter>? -- Client only: created on first pending admission; cleared on transport closure

local C = {}
local channel_mt = {
	__index = C,
}

--- @class silly.net.http.h2.stream
--- @field package channel silly.net.http.h2.channel -- Fixed ownership; closed records release
--- @field remoteaddr string
--- protocol
--- @field scheme string
--- @field version string
--- @field method string
--- @field path string
--- @field header table<string, string|string[]>
--- @field trailer table<string, string|string[]>
--- @field status integer?
--- @field headeronly boolean? -- Client: initial headers end response; valid after waitresponse succeeds
--- @field query table<string, string>?
--- stream
--- @field package id integer -- Assigned before a client request is returned
--- @field package active boolean -- Stream initiated locally
--- @field package closed boolean -- Protocol ended and removed from the channel; completed data stays readable
--- @field package errstr string? -- Set before either state enters STATE_RST
--- @field package localstate silly.net.http.h2.state
--- @field package remotestate silly.net.http.h2.state
--- read
--- @field package readco thread?
--- @field package readtype silly.net.http.h2.state?
--- @field package readneed integer
--- recv(passive read)
--- @field package recvbuf silly.adt.buffer
--- @field package recvwindowsize integer -- Receive capacity including buffered bytes; available credit subtracts recvbuf:size().
--- @field package recvbytes integer
--- @field package recvexpect integer?
--- write
--- @field package writeco thread? -- DATA flow control
--- @field package writedat string?
--- @field package writeoffset integer
--- @field package writeeof boolean -- Set END_STREAM when pending DATA finishes
--- @field package sendwindow integer
--- @field package sendwaiting boolean -- Enqueued for connection DATA window credit
local S = {}
local stream_mt = {
	__index = S,
	__close = nil,
}

--- @class silly.net.http.h2.channel.client: silly.net.http.h2.channel
--- @field package dispatchco thread?

--- @class silly.net.http.h2.channel.server: silly.net.http.h2.channel
--- @field package handler fun(s:silly.net.http.h2.stream)

---@param scheme string
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param authority string
---@param isclient boolean
---@return silly.net.http.h2.channel
local function newchannel(scheme, conn, authority, isclient)
	---@type silly.net.http.h2.channel
	local ch = {
		--- connection
		scheme = scheme,
		isclient = isclient,
		authority = authority,
		conn = conn,
		--- streams
		streamidx = -1,
		laststreamid = 0,
		streamcount = 0,
		streammax = max_stream_per_channel,
		streams = {},
		--- send control
		initialwindowsize = default_window_size,      -- Stream initial window size (from SETTINGS)
		sendframemaxsize = default_frame_size,
		sendbuf = {},
		sendwindow = default_window_size,             -- Connection-level send window
		sendwaitq = queue.new(),
		--- recv control
		recvframemaxsize = default_frame_size,
		recvwindebt = 0,
		recvwindowsize = default_window_size,
		--- hpack
		sendhpack = hpack_new(default_header_table_size),
		recvhpack = hpack_new(default_header_table_size),
		--- misc
		enablepush = false,
		goaway = 0,
		lastrecvtime = time.monotonic(),
	}
	return setmetatable(ch, channel_mt)
end

-- On failure, return nil and a local GOAWAY code or transport error text.
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param ch silly.net.http.h2.channel
---@return integer? typ
---@return integer|string flags_or_error
---@return string? payload
---@return integer? streamid
local function read_frame(conn, ch)
	local x9, err = conn:read(9)
	if err then
		return nil, err
	end
	---@cast x9 string -- A successful transport read always returns data.
	local n, t, f, id = unpack(">I3I1I1I4", x9)
	-- RFC 7540 Section 4.1: Ignore the reserved bit (bit 32) in stream identifier
	id = id & 0x7FFFFFFF
	local dat
	if n > 0 then
		if n > ch.recvframemaxsize then
			return nil, FRAME_SIZE_ERROR
		end
		dat, err = conn:read(n)
		if err then
			return nil, err
		end
	else
		dat = ""
	end
	ch.lastrecvtime = time.monotonic()
	return t, f, dat, id
end

---@param dat string
---@return string?, integer?
local function strip_padding(dat)
	local n = #dat
	if n == 0 then
		return nil, FRAME_SIZE_ERROR
	end
	local pad_length = unpack(">I1", dat)
	if pad_length >= n then
		return nil, PROTOCOL_ERROR
	end
	-- Remove pad length byte and padding.
	return sub(dat, 2, -(pad_length + 1))
end

---@param ch silly.net.http.h2.channel
---@param stream_id integer
---@param flag integer
---@param dat string
---@return string[]?, integer|string|nil
local function read_header(ch, stream_id, flag, dat)
	if flag & PADDED ~= 0 then
		local payload, code = strip_padding(dat)
		if not payload then
			return nil, code
		end
		dat = payload
	end
	local offset = 1
	if flag & PRIORITY == PRIORITY then
		if #dat < 5 then
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
	if #dat > max_header_wire_size then
		return nil, ENHANCE_YOUR_CALM
	end
	---@type string|string[]
	local payload
	if flag & END_HEADERS == 0 then
		local conn = ch.conn
		---@cast conn silly.net.tcp.conn|silly.net.tls.conn -- Called while receiving a frame.
		local fragments = {dat}
		local wire_size = #dat
		repeat
			local typ, flags, fragment, id = read_frame(conn, ch)
			if not typ then
				return nil, flags
			end
			if typ ~= FRAME_CONTINUATION or id ~= stream_id then
				return nil, PROTOCOL_ERROR
			end
			wire_size = wire_size + #fragment
			if wire_size > max_header_wire_size then
				return nil, ENHANCE_YOUR_CALM
			end
			fragments[#fragments + 1] = fragment
		until flags & END_HEADERS ~= 0
		payload = fragments
	else
		payload = dat
	end
	local header_list, limited = hpack_unpack(ch.recvhpack, payload, max_header_list_size)
	if not header_list then
		local code = limited and ENHANCE_YOUR_CALM or COMPRESSION_ERROR
		return nil, code
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
	local cookie = header.cookie
	if type(cookie) == "table" then
		-- RFC 9113 Section 8.2.3: restore the field before application delivery.
		header.cookie = concat(cookie, "; ")
	end
end

-- RFC 9113 Section 8.2.1: validate names and values before exposing HTTP fields.
local function valid_header(k, v)
	if not k:find("^:?[!#$%%&'*+.^_`|~0-9a-z-]+$") then
		return false
	end
	-- Frontiers reject leading/trailing SP or HTAB; the body rejects NUL, CR and LF.
	return v == "" or v:find("^%f[^%z \t][^%z\r\n]*%f[%z \t]$") ~= nil
end

---@param hlist string[]
---@param first_header boolean
---@return integer?
local function check_req_header(hlist, first_header)
	local header_mask = 0
	local normal_header_appeared = false
	local method, authority
	-- RFC 7540 Section 8.1.2: Header field names MUST be lowercase
	-- RFC 7540 Section 8.1.2.1: Validate pseudo-header fields
	-- RFC 7540 Section 8.1.2.2: Connection-specific header fields
	for i = 1, #hlist, 2 do
		local k = hlist[i]
		local v = hlist[i + 1]
		if not valid_header(k, v) then
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
			if k == ":method" then
				if v == "" or v:find("[^!#$%%&'*+.^_`|~0-9A-Za-z-]") then
					return PROTOCOL_ERROR
				end
				method = v
			elseif k == ":scheme" then
				if not v:match("^[A-Za-z][A-Za-z0-9+.-]*$") then
					return PROTOCOL_ERROR
				end
			elseif k == ":path" and v == "" then
				return PROTOCOL_ERROR
			elseif k == ":authority" then
				authority = v
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
	if first_header then
		if method == "CONNECT" then
			if header_mask ~= pseudo_connect_mask or authority == "" then
				return PROTOCOL_ERROR
			end
		elseif (header_mask & pseudo_must_mask) ~= pseudo_must_mask then
			return PROTOCOL_ERROR
		end
	end
	return nil
end

local function check_content_length(header)
	-- Accept Lua numeric syntax, but require a nonnegative length within Lua's integer range.
	-- Surrounding whitespace is rejected by HTTP field validation before this check.
	local values = header['content-length']
	if not values then
		return true, nil
	end
	if type(values) ~= "table" then
		local n = tointeger(values)
		if not n or n < 0 then
			return false, PROTOCOL_ERROR
		end
		return true, n
	end
	local expected
	for _, value in pairs(values) do
		local n = tointeger(value)
		if not n or n < 0 or expected and n ~= expected then
			return false, PROTOCOL_ERROR
		end
		expected = n
	end
	return true, expected
end

------------channel functions

local function channel_newstream(ch, id, active, method, path, header)
	---@type silly.net.http.h2.stream
	local stream = {
		channel = ch,
		remoteaddr = ch.conn.remoteaddr,
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
		closed = false,
		localstate = STATE_NONE,
		remotestate = STATE_NONE,
		errstr = nil,
		-- read
		readco = nil,
		readtype = nil,
		readneed = 0,
		-- recv(passive read)
		recvbuf = buffer.new(),
		recvwindowsize = stream_init_window_size,
		recvbytes = 0,
		recvexpect = nil,
		-- write
		writeco = nil,
		writedat = nil,
		writeoffset = 0,
		sendwaiting = false,
		writeeof = false,
		sendwindow = ch.initialwindowsize,  -- Stream-level send window
	}
	setmetatable(stream, stream_mt)
	return stream
end

---@param ch silly.net.http.h2.channel
local function channel_flushwrite(ch)
	ch.writeco = nil
	local conn = ch.conn
	if not conn then
		return
	end
	local sendbuf = ch.sendbuf
	local windebt = ch.recvwindebt
	local n = #sendbuf
	if windebt > 0 then
		n = n + 1
		sendbuf[n] = build_winupdate(0, 0, windebt)
		ch.recvwindebt = 0
	end
	if n == 0 then
		return
	end
	conn:write(sendbuf)
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
	if not ch.writeco then
		ch.writeco = task.fork(channel_flushwrite, ch)
	end
end

---@param ch silly.net.http.h2.channel
---@param increment integer
local function channel_windebt(ch, increment)
	if increment == 0 then
		return
	end
	ch.recvwindebt = ch.recvwindebt + increment
	if not ch.writeco then
		ch.writeco = task.fork(channel_flushwrite, ch)
	end
end

local function channel_canceltimer(ch)
	if ch.timer then
		time.cancel(ch.timer)
		ch.timer = nil
	end
end

---@param ch silly.net.http.h2.channel
---@param s silly.net.http.h2.stream
local function channel_delstream(ch, s)
	if s.closed then
		return
	end
	s.closed = true
	ch.streams[s.id] = nil
	ch.streamcount = ch.streamcount - 1
end

---@param ch silly.net.http.h2.channel
local function channel_checkclose(ch)
	local conn = ch.conn
	if not conn then
		return true
	end
	local goaway = ch.goaway
	if goaway == 0 then
		return false
	end
	-- A server receiving client GOAWAY can still accept that client's queued requests.
	if goaway & GOAWAY_LOCAL == 0 and not ch.isclient then
		return false
	end
	if ch.streamcount > 0 then
		return false
	end
	local openwaitq = ch.openwaitq
	if openwaitq and openwaitq:size() > 0 then
		return false
	end
	channel_canceltimer(ch)
	ch.pingtoken = nil
	channel_flushwrite(ch)
	conn:close()
	ch.conn = nil
	ch.openwaitq = nil
	return true
end

---@param ch silly.net.http.h2.channel
---@param err string
local function channel_failopen(ch, err)
	local waitq = ch.openwaitq
	if not waitq then
		return
	end
	while true do
		local waiter = waitq:pop()
		if not waiter then
			break
		end
		local co = waiter.co
		---@cast co thread
		waiter.co = nil
		waiter.err = err
		wakeup(co, nil)
	end
end

---@param ch silly.net.http.h2.channel
---@param err string
local function channel_clearstream(ch, err)
	local streams = ch.streams
	for _, s in pairs(streams) do
		channel_delstream(ch, s)
		-- Connection failure cannot invalidate a direction that already completed.
		if s.localstate ~= STATE_END then
			s.errstr = err
			s.localstate = STATE_RST
		end
		if s.remotestate ~= STATE_END then
			s.errstr = err
			s.remotestate = STATE_RST
		end
		s.sendwaiting = false
		local co = s.readco
		if co then
			s.readco = nil
			s.readtype = nil
			s.readneed = 0
			-- Readers derive EOF or failure from the receive state; wakeup values are data.
			wakeup(co, nil)
		end
		co = s.writeco
		if co then
			s.writeco = nil
			s.writedat = nil
			-- Writers take the error from the wakeup value; nil means success.
			wakeup(co, err)
		end
	end
	ch.sendwaitq:clear()
end

---@param ch silly.net.http.h2.channel
---@param err integer|string -- Nonzero local GOAWAY code, or transport/peer text without sending GOAWAY
local function channel_abort(ch, err)
	local conn = ch.conn
	if not conn then
		return
	end
	channel_canceltimer(ch)
	ch.pingtoken = nil
	local errorcode
	if type(err) == "number" then
		errorcode = err
		err = err_str[errorcode]
	end
	---@cast err string -- Numeric codes have been translated through err_str.
	ch.errstr = err
	local buf = ch.sendbuf
	for i = 1, #buf do
		buf[i] = nil
	end
	ch.recvwindebt = 0
	if errorcode then
		ch.goaway = ch.goaway | GOAWAY_LOCAL
		local last = ch.goawaysentlast or ch.laststreamid
		ch.goawaysentlast = last
		logger.warn("[h2] channel goaway with error:", errorcode)
		channel_write(ch, build_goaway(last, errorcode))
		channel_flushwrite(ch)
	end
	channel_clearstream(ch, err)
	channel_failopen(ch, err)
	conn:close()
	ch.conn = nil
	ch.openwaitq = nil
end

local function channel_keepalivetimeout(ch)
	ch.timer = nil
	if not ch.conn then
		return
	end
	channel_abort(ch, "PING timeout")
end

local function channel_idletimer(ch)
	ch.timer = nil
	if not ch.conn or not ch.keepaliveinterval or
		(not ch.keepalivewhileidle and ch.streamcount == 0) then
		return
	end
	local delay = ch.lastrecvtime + ch.keepaliveinterval - time.monotonic()
	if delay > 0 then
		ch.timer = time.after(delay, channel_idletimer, ch)
		return
	end
	local dat
	dat, ch.pingtoken = build_ping(0)
	channel_write(ch, dat)
	ch.timer = time.after(ch.keepalivetimeout, channel_keepalivetimeout, ch)
end

---@param ch silly.net.http.h2.channel
local function channel_starttimer(ch)
	if ch.conn and ch.keepaliveinterval and not ch.timer and
		(ch.keepalivewhileidle or ch.streamcount > 0) then
		local delay = ch.lastrecvtime + ch.keepaliveinterval - time.monotonic()
		ch.timer = time.after(delay, channel_idletimer, ch)
	end
end

---@param ch silly.net.http.h2.channel.client
---@param keep_alive_interval integer? -- Receive idle time in ms; nil or <= 0 disables probes
---@param keep_alive_timeout integer? -- ACK timeout in ms; nil or <= 0 uses 15000 when enabled
---@param keep_alive_while_idle boolean? -- Probe without protocol-active streams; defaults false
function C.keepalive(ch, keep_alive_interval, keep_alive_timeout, keep_alive_while_idle)
	channel_canceltimer(ch)
	if keep_alive_timeout and keep_alive_timeout <= 0 then
		keep_alive_timeout = nil
	end
	if keep_alive_interval and keep_alive_interval > 0 then
		keep_alive_timeout = keep_alive_timeout or 15000
	else
		keep_alive_interval = nil
	end
	ch.keepaliveinterval = keep_alive_interval
	ch.keepalivetimeout = keep_alive_timeout
	ch.keepalivewhileidle = keep_alive_while_idle == true
	ch.pingtoken = nil
	channel_starttimer(ch)
end

---@param ch silly.net.http.h2.channel.client
---@param method string
---@param path string
---@param header table
---@param endstream boolean?
---@return silly.net.http.h2.stream?, string?
local function channel_newrequest(ch, method, path, header, endstream)
	-- Admission, HPACK encoding, ID assignment and queueing must not yield.
	if endstream then
		local ok, length = check_content_length(header)
		if not ok or length and length ~= 0 then
			return nil, "Content-length conflicts with endstream"
		end
	end
	local hdat
	if method == "CONNECT" then
		hdat = hpack_pack(ch.sendhpack, header, ":authority", path, ":method", method)
	else
		hdat = hpack_pack(ch.sendhpack, header,
			":authority", ch.authority, ":method", method,
			":path", path, ":scheme", ch.scheme)
	end
	local id = ch.streamidx + 2
	local s = channel_newstream(ch, id, true, method, path, {})
	ch.streamidx = id
	ch.streamcount = ch.streamcount + 1
	ch.streams[id] = s
	channel_write(ch, build_header(id, ch.sendframemaxsize, hdat, endstream))
	s.localstate = endstream and STATE_END or STATE_HEADER
	channel_starttimer(ch)
	return s, nil
end

---@param ch silly.net.http.h2.channel
local function channel_wakeupopen(ch)
	local waitq = ch.openwaitq
	if not waitq or ch.goaway & GOAWAY_REMOTE ~= 0 then
		return
	end
	---@cast ch silly.net.http.h2.channel.client
	while ch.streamcount < ch.streammax do
		local waiter = waitq:pop()
		if not waiter then
			break
		end
		local co = waiter.co
		---@cast co thread
		waiter.co = nil
		-- Complete admission before waking the owner; conversion failures consume no slot.
		-- Return exceptions to the requester instead of the coroutine admitting it.
		local ok, stream, err = pcall(channel_newrequest, ch, waiter.method,
			waiter.path, waiter.header, waiter.endstream)
		if ok then
			waiter.err = err
			wakeup(co, stream)
		else
			waiter.exception = stream
			wakeup(co, nil)
		end
	end
end

---@param s silly.net.http.h2.stream
local function stream_checkclose(s)
	if s.closed or s.localstate < STATE_END or s.remotestate < STATE_END then
		return
	end
	local ch = s.channel
	channel_delstream(ch, s)
	if not channel_checkclose(ch) then
		channel_wakeupopen(ch)
	end
end

---@param ch silly.net.http.h2.channel
function C.isfull(ch)
	return ch.streamcount >= ch.streammax
end

---@param ch silly.net.http.h2.channel
function C.isalive(ch)
	local conn = ch.conn
	if not conn or ch.goaway ~= 0 or not conn:isalive() then
		return false
	end
	local openwaitq = ch.openwaitq
	local waiting = openwaitq and openwaitq:size() or 0
	return ch.streamidx + (waiting + 1) * 2 <= MAX_STREAM_ID
end

---@param ch silly.net.http.h2.channel
function C.isidle(ch)
	if ch.streamcount > 0 then
		return false
	end
	local waitq = ch.openwaitq
	return (not waitq or waitq:size() == 0)
end

---@param waiter silly.net.http.h2.waiter
local function request_timer(waiter)
	local co = waiter.co
	if co then
		waiter.co = nil
		waiter.waitq:remove(waiter)
		wakeup(co, TIMEOUT)
	end
end

---@param ch silly.net.http.h2.channel.client
---@param method string
---@param path string -- Request target; CONNECT uses host:port
---@param header table
---@param endstream boolean?
---@param timeout integer? -- Admission timeout in milliseconds
---@return silly.net.http.h2.stream?, string?
function C.request(ch, method, path, header, endstream, timeout)
	if not ch.conn or ch.goaway ~= 0 then
		return nil, ch.errstr
	end
	local openwaitq = ch.openwaitq
	local waiting = openwaitq and openwaitq:size() or 0
	-- Each pending request needs one of the remaining odd stream IDs.
	if ch.streamidx + (waiting + 1) * 2 > MAX_STREAM_ID then
		return nil, "Stream id exhausted"
	end
	if ch.streamcount >= ch.streammax then
		if not openwaitq then
			openwaitq = queue.new()
			ch.openwaitq = openwaitq
		end
		---@type silly.net.http.h2.waiter
		local waiter = {
			waitq = openwaitq,
			co = task.running(),
			method = method,
			path = path,
			header = header,
			endstream = endstream,
		}
		local timer
		if timeout then
			timer = time.after(timeout, request_timer, waiter)
		end
		openwaitq:push(waiter)
		local result = task.wait()
		local err = waiter.err
		if result == TIMEOUT then
			result = nil
			err = ETIMEDOUT
		elseif timer then
			time.cancel(timer)
		end
		if not result then
			-- The last failed admission may finish a local graceful close.
			channel_checkclose(ch)
			if waiter.exception then
				error(waiter.exception, 0)
			end
			return nil, err
		end
		---@cast result silly.net.http.h2.stream
		return result, nil
	end
	return channel_newrequest(ch, method, path, header, endstream)
end

---@param ch silly.net.http.h2.channel
function C.close(ch)
	if not ch.conn or ch.goaway & GOAWAY_LOCAL ~= 0 then
		return
	end
	if ch.goaway == 0 then
		ch.errstr = err_str[NO_ERROR]
	end
	local last = ch.laststreamid
	ch.goaway = ch.goaway | GOAWAY_LOCAL
	ch.goawaysentlast = last
	-- Existing admission waiters drain; request() rejects calls made after close().
	channel_write(ch, build_goaway(last, NO_ERROR))
	channel_flushwrite(ch)
	channel_checkclose(ch)
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

-- RFC 9113 Section 6.9: credit follows consumption, or an explicit pending read.
---@param s silly.net.http.h2.stream
---@param need integer -- Total receive capacity, including unread buffered bytes.
local function stream_readensure(s, need)
	local recvwindowsize = s.recvwindowsize
	local increment = need - recvwindowsize
	if increment > 0 then
		s.recvwindowsize = need
		channel_write(s.channel, build_winupdate(s.id, 0, increment))
	end
end

---@param s silly.net.http.h2.stream
---@param len integer
local function stream_readconsume(s, len)
	if len == 0 then
		return
	end
	-- Account before waking a reader: another buffered frame may follow immediately.
	s.recvwindowsize = s.recvwindowsize - len
	if s.remotestate < STATE_CLOSE then
		stream_readensure(s, stream_init_window_size)
	end
end

---@param s silly.net.http.h2.stream
---@param state silly.net.http.h2.state
---@param size integer
---@param timeout integer?
---@return string?, string? error
local function stream_readwait(s, state, size, timeout)
	local dat
	s.readtype = state
	s.readneed = size
	s.readco = task.running()
	if state == STATE_CLOSE then
		stream_readensure(s, stream_init_window_size + s.recvbuf:size())
	elseif state == STATE_DATA and size > stream_init_window_size then
		stream_readensure(s, size)
	end
	if timeout then
		local timer = time.after(timeout, read_timer, s)
		dat = task.wait()
		if dat == TIMEOUT then
			return nil, ETIMEDOUT
		end
		time.cancel(timer)
	else
		dat = task.wait()
	end
	if s.remotestate == STATE_RST then
		return nil, s.errstr
	end
	if dat then
		return dat, nil
	end
	-- Receive END may precede a write failure before this task resumes.
	return nil, EEOF
end

---@param ch silly.net.http.h2.channel
---@param s silly.net.http.h2.stream
local function channel_waitwrite(ch, s)
	if not s.sendwaiting then
		s.sendwaiting = true
		ch.sendwaitq:push(s)
	end
end

---@param s silly.net.http.h2.stream
---@param data string
---@param offset integer
---@param endstream boolean
---@return integer offset
local function stream_send(s, data, offset, endstream)
	local ch = s.channel
	local dlen = #data - offset
	local win = dlen
	-- Empty END_STREAM DATA does not consume either send window.
	if win > 0 then
		local swin = s.sendwindow
		local chwin = ch.sendwindow
		if win > swin then
			win = swin
		end
		if win > chwin then
			win = chwin
		end
		-- RFC 9113 Section 6.9.2: SETTINGS reductions can make stream windows negative.
		if win <= 0 then
			return offset
		end
		s.sendwindow = swin - win
		ch.sendwindow = chwin - win
	end
	endstream = endstream and win == dlen
	if win > 0 or endstream then
		channel_write(ch, build_body(s.id, ch.sendframemaxsize, data, endstream, offset, win))
		if endstream then
			s.localstate = STATE_END
		end
	end
	return offset + win
end

---@param s silly.net.http.h2.stream
---@param data string
---@param endstream boolean
---@return boolean, string?
local function stream_writewait(s, data, endstream)
	local offset = stream_send(s, data, 0, endstream)
	if offset == #data then
		stream_checkclose(s)
		return true, nil
	end
	s.writedat = data
	s.writeoffset = offset
	s.writeeof = endstream
	local ch = s.channel
	if ch.sendwindow <= 0 then
		channel_waitwrite(ch, s)
	end
	s.writeco = task.running()
	local err = task.wait()
	-- A queued success may be followed by a peer reset, local close, or connection failure.
	-- Report failure if the write side was reset before this task resumes, regardless of who reset it.
	if not err and s.localstate == STATE_RST then
		err = s.errstr
	end
	if err then
		s.errstr = err
		return false, err
	end
	return true, nil
end

---@param s silly.net.http.h2.stream
---@param err string?
local function stream_writewakeup(s, err)
	local co = s.writeco
	if co then
		if s.sendwaiting then
			s.sendwaiting = false
			local ch = s.channel
			ch.sendwaitq:remove(s)
		end
		s.writedat = nil
		s.writeoffset = 0
		s.writeeof = false
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
	s.errstr = err
	s.localstate = STATE_RST
	s.remotestate = STATE_RST
	stream_readwakeup(s, nil)
	stream_writewakeup(s, err)
	stream_checkclose(s)
end

---@param s silly.net.http.h2.stream
---@param state silly.net.http.h2.state
---@param err string
local function stream_remoteend(s, state, err)
	if state == STATE_END then
		-- RFC 7540 Section 8.1.2.6: Validate content-length matches actual received length
		if s.recvexpect and s.recvbytes ~= s.recvexpect then
			stream_reset(s.id, s.channel, PROTOCOL_ERROR)
			return
		end
		-- END means the complete receive direction passed validation.
		s.remotestate = STATE_END
		s.errstr = err
		local readtype = s.readtype
		if readtype == STATE_CLOSE then
			local dat = s.recvbuf:readall()
			stream_readconsume(s, #dat)
			stream_readwakeup(s, dat)
		elseif readtype then
			stream_readwakeup(s, nil)
		end
	else
		s.errstr = err
		s.localstate = STATE_RST
		s.remotestate = STATE_RST
		stream_readwakeup(s, nil)
		stream_writewakeup(s, err)
	end
	stream_checkclose(s)
end


---@param s silly.net.http.h2.stream
local function stream_trysend(s)
	local sendingdat = s.writedat
	if not sendingdat or s.sendwindow <= 0 then
		return
	end
	local sendingoff = stream_send(s, sendingdat, s.writeoffset, s.writeeof)
	s.writeoffset = sendingoff
	if sendingoff == #sendingdat then
		stream_writewakeup(s, nil)
		stream_checkclose(s)
	elseif s.channel.sendwindow <= 0 then
		channel_waitwrite(s.channel, s)
	end
end

---@param s silly.net.http.h2.stream
---@param status integer
---@param header table
---@param endstream boolean?
---@return boolean, string?
function S.respond(s, status, header, endstream)
	if s.localstate ~= STATE_NONE then
		return false, s.errstr or "Response headers already sent"
	end
	local ch = s.channel
	local hdat = hpack_pack(ch.sendhpack, header, ":status", status)
	channel_write(ch, build_header(s.id, ch.sendframemaxsize, hdat, endstream))
	s.status = status
	s.localstate = endstream and STATE_END or STATE_HEADER
	stream_checkclose(s)
	return true, nil
end

-- Compatibility with HTTP/1 streams; sending and receive credit are automatic.
---@param s silly.net.http.h2.stream
---@return boolean, string? error
function S.flush(s)
	return true, nil
end

---@param s silly.net.http.h2.stream
---@param data string
---@return boolean, string?
function S.write(s, data)
	if not data or #data == 0 then
		return true, nil
	end
	local localstate = s.localstate
	if localstate >= STATE_CLOSE then
		return false, "Local closed"
	end
	if s.writeco then
		error("[h2] write can't be called while write is pending", 2)
	end
	if localstate == STATE_NONE then
		return false, "Response headers not sent"
	end
	s.localstate = STATE_DATA
	return stream_writewait(s, data, false)
end

---@param s silly.net.http.h2.stream
---@param data string|nil
---@param trailer table?
---@return boolean, string? error
function S.closewrite(s, data, trailer)
	local localstate = s.localstate
	if localstate >= STATE_CLOSE then
		return false, "Local closed"
	end
	if s.writeco then
		error("[h2] closewrite can't be called while write is pending", 2)
	end
	local ch = s.channel
	local nopayload = not (data or trailer)
	if localstate == STATE_NONE then
		return false, "Response headers not sent"
	end
	-- Closing blocks further writes; END_STREAM is recorded only once queued.
	s.localstate = STATE_CLOSE
	if nopayload then
		data = ""
	end
	if data then
		local ok, err = stream_writewait(s, data, not trailer)
		if not ok then
			return false, err
		end
	end
	if trailer then
		local hdr = hpack_pack(ch.sendhpack, trailer)
		local dat = build_header(s.id, ch.sendframemaxsize, hdr, true)
		channel_write(ch, dat)
		s.localstate = STATE_END
		stream_checkclose(s)
	end
	return true, nil
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
	if s.remotestate == STATE_RST then
		return false, s.errstr
	end
	return true, nil
end

---@param s silly.net.http.h2.stream
function S.close(s)
	if s.closed then
		return
	end
	local ch = s.channel
	local id = s.id
	local localstate = s.localstate
	local remotestate = s.remotestate
	if localstate <= STATE_CLOSE or remotestate < STATE_CLOSE then
		if localstate ~= STATE_RST and remotestate ~= STATE_RST then
			-- RFC 9113 8.1: preserve a complete response when stopping a request body.
			local code = not s.active and localstate == STATE_END and NO_ERROR or CANCEL
			stream_reset(id, ch, code)
		end
	end
	stream_checkclose(s)
end

stream_mt.__close = S.close

---@param s silly.net.http.h2.stream
---@param size integer
---@param timeout integer? --ms
---@return string?, string? error
function S.read(s, size, timeout)
	local remotestate = s.remotestate
	if remotestate == STATE_RST then
		return nil, s.errstr
	end
	local recvbuf = s.recvbuf
	local dat = recvbuf:read(size)
	if dat then
		stream_readconsume(s, #dat)
		return dat, nil
	end
	if remotestate == STATE_END then
		return nil, EEOF
	end
	return stream_readwait(s, STATE_DATA, size, timeout)
end

---@param s silly.net.http.h2.stream
---@param timeout integer? --ms
---@return string?, string?
function S.readall(s, timeout)
	local remotestate = s.remotestate
	if remotestate == STATE_RST then
		return nil, s.errstr
	elseif remotestate == STATE_END then
		local dat = s.recvbuf:readall()
		stream_readconsume(s, #dat)
		return dat, nil
	end
	return stream_readwait(s, STATE_CLOSE, 0, timeout)
end

---@param s silly.net.http.h2.stream
function S.eof(s)
	return s.remotestate == STATE_END
end
-----------------------------frame functions-------------------------------
local function stream_istunnel(s)
	if s.method ~= "CONNECT" then
		return false
	end
	local status = s.status
	return status and status >= 200 and status < 300
end

-- Missing IDs up to the highest opened ID are closed, including skipped IDs.
-- RFC 9113 5.1 permits minimal processing for all closed streams, without history.
---@param ch silly.net.http.h2.channel
---@param id integer
---@return silly.net.http.h2.stream? stream
---@return boolean idle -- ID has not been opened; missing non-idle IDs are closed streams.
local function channel_recvstream(ch, id)
	local last = ch.isclient and ch.streamidx or ch.laststreamid
	if id % 2 == 0 or id > last then
		return nil, true
	end
	return ch.streams[id], false
end

---@param ch silly.net.http.h2.channel
---@param increment integer
local function channel_winupdate(ch, increment)
	-- Connection-level WINDOW_UPDATE: update connection send window
	local owindow = ch.sendwindow
	local nwindow = owindow + increment
	-- RFC 7540 Section 6.9.1: Window size MUST NOT exceed 2^31-1
	if nwindow > max_window_size then
		channel_abort(ch, FLOW_CONTROL_ERROR)
		return
	end
	ch.sendwindow = nwindow
	if increment <= 0 then
		return
	end
	local waitq = ch.sendwaitq
	while ch.sendwindow > 0 do
		local s = waitq:pop()
		if not s then
			break
		end
		s.sendwaiting = false
		stream_trysend(s)
	end
end

---@param s silly.net.http.h2.stream
---@param increment integer
---@return boolean
local function stream_winupdate(s, increment)
	-- Reset streams may still be held by the application until close().
	if s.localstate == STATE_RST then
		return true
	end
	local nwindow = s.sendwindow + increment
	if nwindow > max_window_size then
		return false
	end
	s.sendwindow = nwindow
	return true
end

---@param ch silly.net.http.h2.channel
---@param id integer
---@param flag integer
---@param dat string
local function frame_data(ch, id, flag, dat)
	local wirelen = #dat
	if flag & PADDED ~= 0 then
		local payload, code = strip_padding(dat)
		if not payload then
			---@cast code integer
			channel_abort(ch, code)
			return
		end
		dat = payload
	end
	local datlen = #dat
	if id == 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	if wirelen > ch.recvwindowsize - ch.recvwindebt then
		channel_abort(ch, FLOW_CONTROL_ERROR)
		return
	end
	-- Account for connection credit, including padding, even when discarding closed DATA.
	channel_windebt(ch, wirelen)
	local s, idle = channel_recvstream(ch, id)
	if not s then
		if idle then
			channel_abort(ch, PROTOCOL_ERROR)
		end
		return
	end
	if s.localstate == STATE_RST then
		return
	end
	if s.remotestate == STATE_NONE then
		stream_reset(id, ch, PROTOCOL_ERROR)
		return
	end
	if s.remotestate >= STATE_CLOSE then
		stream_reset(id, ch, STREAM_CLOSED)
		return
	end
	if wirelen > s.recvwindowsize - s.recvbuf:size() then
		stream_reset(id, ch, FLOW_CONTROL_ERROR)
		return
	end
	local padding = wirelen - datlen
	if padding > 0 then
		-- Padding is consumed immediately; its capacity debit and credit cancel.
		channel_write(ch, build_winupdate(id, 0, padding))
	end
	s.remotestate = STATE_DATA
	if datlen > 0 then
		local readtype = s.readtype
		local total = s.recvbuf:append(dat)
		s.recvbytes = s.recvbytes + datlen
		if s.recvexpect and s.recvbytes > s.recvexpect then
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		if readtype == STATE_DATA and total >= s.readneed then
			local payload = s.recvbuf:read(s.readneed)
			---@cast payload string -- The buffered total satisfies readneed.
			stream_readconsume(s, #payload)
			stream_readwakeup(s, payload)
		elseif readtype == STATE_CLOSE then
			stream_readensure(s, stream_init_window_size + total)
		end
	end
	if flag & END_STREAM == END_STREAM then
		stream_remoteend(s, STATE_END, EEOF)
	end
end

---@param ch silly.net.http.h2.channel
---@param stream_id integer
---@param flag integer
---@param dat string
local function frame_settings(ch, stream_id, flag, dat)
	-- RFC 7540 Section 6.5: SETTINGS frames MUST be sent on stream 0
	if stream_id ~= 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end

	-- RFC 7540 Section 6.5.3: ACK SETTINGS frames must have empty payload
	if flag & ACK == ACK then
		if #dat ~= 0 then
			channel_abort(ch, FRAME_SIZE_ERROR)
			return
		end
		return
	end

	-- RFC 7540 Section 6.5: SETTINGS frames are composed of zero or more parameters
	-- Each parameter is 6 octets (2 octets identifier + 4 octets value)
	if #dat % 6 ~= 0 then
		channel_abort(ch, FRAME_SIZE_ERROR)
		return
	end

	local openchanged = false
	local windowchanged = false
	for i = 1, #dat, 6 do
		local id, val = unpack(">I2I4", dat, i)
		-- RFC 7540 Section 6.5.2: Validate SETTINGS parameter values
		if id == SETTINGS_ENABLE_PUSH then
			-- SETTINGS_ENABLE_PUSH can only be 0 or 1
			if val ~= 0 and (val ~= 1 or ch.isclient) then
				channel_abort(ch, PROTOCOL_ERROR)
				return
			end
			ch.enablepush = (val == 1)
		elseif id == SETTINGS_INITIAL_WINDOW_SIZE  then
			-- SETTINGS_INITIAL_WINDOW_SIZE: max value is 2^31-1 (0x7FFFFFFF)
			if val > max_window_size then
				channel_abort(ch, FLOW_CONTROL_ERROR)
				return
			end
			-- RFC 7540 Section 6.9.2: Adjust all existing stream windows by the difference
			local delta = val - ch.initialwindowsize
			ch.initialwindowsize = val
			if delta ~= 0 then
				windowchanged = windowchanged or delta > 0
				for _, s in pairs(ch.streams) do
					if s.localstate <= STATE_CLOSE and not stream_winupdate(s, delta) then
						channel_abort(ch, FLOW_CONTROL_ERROR)
						return
					end
				end
			end
		elseif id == SETTINGS_MAX_FRAME_SIZE then
			-- SETTINGS_MAX_FRAME_SIZE: must be between 2^14 (16384) and 2^24-1 (16777215)
			if val < 16384 or val > 16777215 then
				channel_abort(ch, PROTOCOL_ERROR)
				return
			end
			ch.sendframemaxsize = val
		elseif id == SETTINGS_HEADER_TABLE_SIZE then
			hpack_hardlimit(ch.sendhpack, val < default_header_table_size
				and val or default_header_table_size)
		elseif id == SETTINGS_MAX_CONCURRENT then
			ch.streammax = val
			openchanged = true
		elseif id == SETTINGS_MAX_HEADER_LIST_SIZE then
			-- SETTINGS_MAX_HEADER_LIST_SIZE is advisory only, no error checking needed
		else
			logger.warn("[h2] unknown settings id:", id)
		end
	end
	-- RFC 7540 Section 6.5.3: Must immediately emit a SETTINGS frame with ACK flag
	channel_write(ch, build_setting(ACK))
	if windowchanged then
		-- Final writes can release slots and insert newly admitted streams.
		-- Resume from a snapshot after all settings and existing windows are updated.
		local ready = {}
		for _, s in pairs(ch.streams) do
			if s.writedat then
				ready[#ready + 1] = s
			end
		end
		for i = 1, #ready do
			stream_trysend(ready[i])
		end
	end
	if openchanged then
		channel_wakeupopen(ch)
	end
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param dat string
local function frame_priority(ch, streamid, _, dat)
	-- RFC 7540 Section 6.3: PRIORITY frame always identifies a stream
	-- If received with stream identifier 0x0, this is a connection error
	if streamid == 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 5.3.1: A stream cannot depend on itself
	-- PRIORITY frame payload: 5 bytes (4 bytes dependency + 1 byte weight)
	if #dat ~= 5 then
		-- Invalid frame size
		channel_abort(ch, FRAME_SIZE_ERROR)
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
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 6.7: PING frames MUST contain exactly 8 bytes
	if #dat ~= 8 then
		channel_abort(ch, FRAME_SIZE_ERROR)
		return
	end
	-- RFC 7540 Section 6.7: If ACK flag is set, do not respond
	if flag & ACK == ACK then
		if ch.pingtoken == dat then
			ch.pingtoken = nil
			channel_canceltimer(ch)
			channel_starttimer(ch)
		end
		return
	end
	-- Batch ACK with ready frames; sendbuf never waits for flow-control credit.
	channel_write(ch, build_ping(ACK, dat))
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param dat string
local function frame_rst(ch, streamid, _, dat)
	local s, idle = channel_recvstream(ch, streamid)
	if streamid == 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540 Section 6.4: RST_STREAM frames MUST be 4 octets in length
	if #dat ~= 4 then
		channel_abort(ch, FRAME_SIZE_ERROR)
		return
	end
	if not s then
		if idle then
			channel_abort(ch, PROTOCOL_ERROR)
		end
		return
	end
	local localstate = s.localstate
	if localstate == STATE_RST then
		return
	end
	local code = unpack(">I4", dat)
	if s.active and code == NO_ERROR and s.remotestate == STATE_END then
		-- RFC 9113 Section 8.1: preserve a complete response while stopping the upload.
		if localstate ~= STATE_END then
			s.localstate = STATE_RST
			local err = "Request stopped by peer"
			s.errstr = err
			stream_writewakeup(s, err)
		end
		stream_checkclose(s)
		return
	end
	stream_remoteend(s, STATE_RST, err_str[code])
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
local function frame_goaway(ch, streamid, _, dat)
	if streamid ~= 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	if #dat < 8 then
		channel_abort(ch, FRAME_SIZE_ERROR)
		return
	end
	local last, code = unpack(">I4I4", dat)
	last = last & 0x7fffffff
	if ch.goawaylast and last > ch.goawaylast then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	ch.goawaylast = last
	ch.goaway = ch.goaway | GOAWAY_REMOTE
	if code ~= NO_ERROR then
		-- Preserve the peer's reason without sending it back as a local GOAWAY.
		channel_abort(ch, err_str[code])
		return
	end
	ch.errstr = err_str[code]
	channel_failopen(ch, ch.errstr)
	for id, s in pairs(ch.streams) do
		if s.active and id > last then
			stream_remoteend(s, STATE_RST, "Stream refused by GOAWAY")
		end
	end
	channel_checkclose(ch)
end

---@param ch silly.net.http.h2.channel
---@param id integer
---@param _ integer
---@param dat string
local function frame_winupdate(ch, id, _, dat)
	-- RFC 7540 Section 6.9: WINDOW_UPDATE frames MUST be 4 octets in length
	if #dat ~= 4 then
		channel_abort(ch, FRAME_SIZE_ERROR)
		return
	end
	local increment = unpack(">I4", dat)
	-- RFC 7540 Section 6.9: Ignore reserved bit, use 31-bit window size increment
	increment = increment & 0x7FFFFFFF
	-- RFC 7540 Section 6.9.1: Flow control window increment of 0 MUST be treated as error
	if id == 0 then
		if increment == 0 then
			-- Connection-level WINDOW_UPDATE with increment=0 is a connection error
			channel_abort(ch, PROTOCOL_ERROR)
			return
		end
		channel_winupdate(ch, increment)
	else
		-- Stream-level WINDOW_UPDATE: update stream send window
		local s, idle = channel_recvstream(ch, id)
		if not s then
			-- RFC 7540 Section 6.9: WINDOW_UPDATE for a closed stream should be ignored
			-- Only WINDOW_UPDATE for an idle stream (never existed) is a connection error
			if idle then
				-- Stream ID is greater than any we've seen, this is an idle stream
				channel_abort(ch, PROTOCOL_ERROR)
			end
			-- Ignore WINDOW_UPDATE for closed streams
			return
		end
		if increment == 0 then
			-- Stream-level WINDOW_UPDATE with increment=0 is a stream error
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		if not stream_winupdate(s, increment) then
			stream_reset(id, ch, FLOW_CONTROL_ERROR)
		else
			stream_trysend(s)
		end
	end
end

---@param ch silly.net.http.h2.channel
local function frame_continuation(ch)
	-- RFC 7540 Section 6.10: CONTINUATION frames are only valid following
	-- HEADERS/PUSH_PROMISE without END_HEADERS. Legal CONTINUATION frames
	-- are consumed internally by try_read_header().
	-- If we see one here, it's orphaned (appears after END_HEADERS).
	channel_abort(ch, PROTOCOL_ERROR)
end

------------------------------------client/server handshake------------------------------------
local M = {}

---@param args {ch: silly.net.http.h2.channel, frame_process: table}
local function common_dispatch(args)
	local ch = args.ch
	local frame_process = args.frame_process
	local conn = ch.conn
	if not conn then
		return
	end
	while true do
		local t,f,d,id = read_frame(conn, ch)
		if not t then
			channel_abort(ch, f)
			return
		end
		local func = frame_process[t]
		if func then
			func(ch, id, f, d)
		end
	end
end

---@param ch silly.net.http.h2.channel
---@param streamid integer
---@param flag integer
---@param dat string
local function frame_header_client(ch, streamid, flag, dat)
	if streamid == 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	local hlist, err = read_header(ch, streamid, flag, dat)
	if not hlist then
		---@cast err integer|string
		channel_abort(ch, err)
		return
	end
	local s, idle = channel_recvstream(ch, streamid)
	if not s then
		if idle then
			channel_abort(ch, PROTOCOL_ERROR)
		end
		return
	end
	if s.localstate == STATE_RST then
		return
	end
	if s.remotestate >= STATE_CLOSE then
		stream_reset(streamid, ch, STREAM_CLOSED)
		return
	end
	local initial = s.remotestate == STATE_NONE
	local status, normal
	for i = 1, #hlist, 2 do
		local k, v = hlist[i], hlist[i + 1]
		if not valid_header(k, v) or forbidden_headers[k] or k == "te" then
			stream_reset(streamid, ch, PROTOCOL_ERROR)
			return
		end
		if k:byte(1) == 58 then
			if not initial or k ~= ":status" or status or normal then
				stream_reset(streamid, ch, PROTOCOL_ERROR)
			return
			end
			status = v
		else
			normal = true
		end
	end
	if initial then
		local nstatus = status and status:match("^%d%d%d$") and tonumber(status)
		if not nstatus or nstatus < 100 or nstatus == 101 then
			stream_reset(streamid, ch, PROTOCOL_ERROR)
			return
		end
		if nstatus < 200 then
			if flag & END_STREAM ~= 0 then
				stream_reset(streamid, ch, PROTOCOL_ERROR)
			end
			return -- waitresponse waits for the final response.
		end
		local header = s.header
		map_header(hlist, header)
		header[":status"] = nil
		local ok, clen = check_content_length(header)
		if not ok then
			stream_reset(streamid, ch, PROTOCOL_ERROR)
			return
		end
		s.status = nstatus
		s.headeronly = flag & END_STREAM ~= 0
		s.remotestate = STATE_HEADER
		local method = s.method
		if not stream_istunnel(s) then
			s.recvexpect = (method == "HEAD" or nstatus == 204 or nstatus == 304) and 0 or clen
		end
		if s.readtype == STATE_HEADER then
			stream_readwakeup(s, "")
		end
	else
		if flag & END_STREAM == 0 or stream_istunnel(s) then
			stream_reset(streamid, ch, PROTOCOL_ERROR)
			return
		end
		s.remotestate = STATE_TRAILER
		map_header(hlist, s.trailer)
	end
	if flag & END_STREAM ~= 0 then
		stream_remoteend(s, STATE_END, EEOF)
	end
end

local frame_client = {
	[FRAME_PUSHPROMISE] = function(ch)
		channel_abort(ch, PROTOCOL_ERROR)
	end,
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
---@return boolean, integer|string|nil
local function handshake_as_client(ch)
	local conn = ch.conn
	---@cast conn silly.net.tcp.conn|silly.net.tls.conn -- The constructor supplied the connection.
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
	local t, f, dat, id = read_frame(conn, ch)
	if not t then
		return false, f
	end
	---@cast f integer
	---@cast dat string
	---@cast id integer
	if t ~= FRAME_SETTINGS or f & ACK ~= 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return false, "Expect initial settings"
	end
	frame_settings(ch, id, f, dat)
	if not ch.conn then
		return false, "Invalid initial settings"
	end
	while true do
		local t,f,dat,id = read_frame(conn, ch)
		if not t then
			return false, f
		end
		---@cast f integer
		---@cast dat string
		---@cast id integer
		local cb = frame_client[t]
		if cb then
			cb(ch, id, f, dat)
		end
		if not ch.conn or ch.goaway ~= 0 then
			return false, "Handshake closed"
		end
		if t == FRAME_SETTINGS and f & ACK == ACK then
			break
		end
	end
	ch.recvwindowsize = ch.recvwindowsize + channel_init_window_size
	channel_write(ch, build_winupdate(0, 0, channel_init_window_size))
	ch.dispatchco = task.fork(common_dispatch, {ch = ch, frame_process = frame_client})
	return true, nil
end

---@param s silly.net.http.h2.stream
local function server_handler(s)
	if s.closed then
		return
	end
	local ch = s.channel
	---@cast ch silly.net.http.h2.channel.server
	local ok, err = pcall(ch.handler, s)
	if not ok then
		logger.error("[h2] handler failed:", err)
		if not s.closed and s.localstate <= STATE_CLOSE and s.remotestate ~= STATE_RST then
			stream_reset(s.id, ch, INTERNAL_ERROR)
		end
	elseif not s.writeco then
		s:closewrite()
	else
		logger.error("[h2] handler returned while write is pending")
	end
	s:close()
end

---@param ch silly.net.http.h2.channel.server
---@param id integer
---@param flag integer
---@param dat string
local function frame_header_server(ch, id, flag, dat)
	if id == 0 or id % 2 == 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return
	end
	local hlist, err = read_header(ch, id, flag, dat)
	if not hlist then
		---@cast err integer|string
		channel_abort(ch, err)
		return
	end
	local s = ch.streams[id]
	if s then
		if s.localstate == STATE_RST then
			return
		end
		if s.remotestate >= STATE_CLOSE then
			stream_reset(id, ch, STREAM_CLOSED)
			return
		end
	end
	local first = not s
	if first then
		if id <= ch.laststreamid then
			-- Closed HEADERS have already updated the shared HPACK state above.
			return
		end
		-- A rejected stream ID is consumed too; it cannot be reopened later.
		ch.laststreamid = id
		if ch.goaway & GOAWAY_LOCAL ~= 0 or ch.streamcount >= max_stream_per_channel then
			stream_reset(id, ch, REFUSED_STREAM)
			return
		end
	end
	local err = check_req_header(hlist, first)
	if err then
		stream_reset(id, ch, err)
		return
	end
	if first then
		local header = {}
		map_header(hlist, header)
		local ok, clen = check_content_length(header)
		if not ok or flag & END_STREAM ~= 0 and clen and clen ~= 0 then
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		local path, query = parsetarget(header[':path'] or "")
		local stream = channel_newstream(ch, id, false, header[':method'], path, header)
		stream.recvexpect = clen
		stream.query = query
		stream.remotestate = flag & END_STREAM ~= 0 and STATE_END or STATE_HEADER
		ch.streams[id] = stream
		ch.streamcount = ch.streamcount + 1
		task.fork(server_handler, stream)
	else
		if flag & END_STREAM == 0 or stream_istunnel(s) and s.localstate >= STATE_HEADER then
			stream_reset(id, ch, PROTOCOL_ERROR)
			return
		end
		map_header(hlist, s.trailer)
		stream_remoteend(s, STATE_END, EEOF)
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
	[FRAME_PUSHPROMISE] = function(ch)
		-- RFC 7540 Section 8.2: A client cannot push.
		-- Servers MUST treat the receipt of a PUSH_PROMISE frame as a connection error.
		channel_abort(ch, PROTOCOL_ERROR)
	end,
}

---@param ch silly.net.http.h2.channel.server
---@return boolean, integer|string|nil
local function handshake_as_server(ch)
	local conn = ch.conn
	---@cast conn silly.net.tcp.conn|silly.net.tls.conn -- The constructor supplied the connection.
	-- According to RFC 7540, server must validate connection preface BEFORE sending SETTINGS
	-- If preface is invalid, server should send GOAWAY with PROTOCOL_ERROR
	local dat, err = conn:read(client_preface_size)
	if not dat then
		return false, err
	end
	if dat ~= client_preface then
		-- Send GOAWAY with PROTOCOL_ERROR before closing
		logger.errorf("[h2] accept %s handshake fail:%s",
			conn.remoteaddr, base64.encode(dat))
		channel_abort(ch, PROTOCOL_ERROR)
		return false
	end

	-- Only after valid preface, send SETTINGS frame
	dat = build_setting(0x0,
		SETTINGS_MAX_CONCURRENT, max_stream_per_channel,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	conn:write(dat)
	local t,f,dat,id = read_frame(conn, ch)
	if not t then
		return false, f
	end
	---@cast f integer
	---@cast dat string
	---@cast id integer
	if t ~= FRAME_SETTINGS or f & ACK ~= 0 then
		channel_abort(ch, PROTOCOL_ERROR)
		return false
	end
	frame_settings(ch, id, f, dat)
	if not ch.conn then
		return false, "Invalid initial settings"
	end
	while true do
		local t,f,dat,id = read_frame(conn, ch)
		if not t then
			return false, f
		end
		---@cast f integer
		---@cast dat string
		---@cast id integer
		local cb = frame_server[t]
		if cb then
			cb(ch, id, f, dat)
		end
		if not ch.conn then
			return false, "Handshake closed"
		end
		if ch.goaway & GOAWAY_LOCAL ~= 0 then
			-- Requests accepted before the SETTINGS ACK still drain after local GOAWAY.
			return ch.streamcount > 0
		end
		if t == FRAME_SETTINGS and f & ACK == ACK then
			break
		end
	end
	ch.recvwindowsize = ch.recvwindowsize + channel_init_window_size
	channel_write(ch, build_winupdate(0, 0, channel_init_window_size))
	return true, nil
end

---@param scheme string
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param authority string
---@return silly.net.http.h2.channel.client?, string? error
function M.newchannel(scheme, conn, authority)
	local ch = newchannel(scheme, conn, authority, true)
	--- @cast ch silly.net.http.h2.channel.client
	local ok, err = handshake_as_client(ch)
	if ok then
		return ch, nil
	end
	channel_abort(ch, ch.errstr or err or "Handshake failed")
	return nil, ch.errstr
end

---@param handler fun(s:silly.net.http.h2.stream)
---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param scheme string
function M.httpd(handler, conn, scheme)
	local ch = newchannel(scheme, conn, "", false)
	--- @cast ch silly.net.http.h2.channel.server
	ch.handler = handler
	local ok, err = handshake_as_server(ch)
	if ok then
		common_dispatch({ch = ch, frame_process = frame_server})
	else
		channel_abort(ch, ch.errstr or err or "Handshake failed")
	end
end

return M
