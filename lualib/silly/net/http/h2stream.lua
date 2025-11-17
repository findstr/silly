local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"
local helper = require "silly.net.http.helper"
local hpack = require "silly.http2.hpack"
local builder = require "silly.http2.framebuilder"

local assert = assert
local pairs = pairs
local tonumber = tonumber
local wakeup = task.wakeup
local move = table.move
local remove = table.remove
local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local setmetatable = setmetatable
local parsetarget = helper.parsetarget

---@class silly.net.http.h2stream.channel_mt
local C = {}

---@class silly.net.http.h2stream.hpack
---@type fun(table_size:integer): silly.net.http.h2stream.hpack
local hpack_new = hpack.new
---@type fun(hpack:silly.net.http.h2stream.hpack, ...:any): string
local hpack_pack = hpack.pack
---@type fun(hpack:silly.net.http.h2stream.hpack, dat:string|string[], header_list:string[]): boolean
local hpack_unpack = hpack.unpack
---@type fun(hpack:silly.net.http.h2stream.hpack, integer): nil
local hpack_hardlimit = hpack.hardlimit

local build_header = builder.header
local build_body = builder.body
local build_rst = builder.rst
local build_setting = builder.setting
local build_winupdate = builder.winupdate
local build_goaway = builder.goaway


---@class silly.net.http.h2stream_mt
local S = {}

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
local FRAME_SIZE_ERROR			=0x06	--Frame size incorrect	[RFC9113, Section 7]
local REFUSED_STREAM<const> 		=0x07	--Stream not processed	[RFC9113, Section 7]
local CANCEL<const> 			=0x08	--Stream cancelled	[RFC9113, Section 7]
local COMPRESSION_ERROR<const>		=0x09	--Compression state not updated	[RFC9113, Section 7]
local CONNECT_ERROR<const> 		=0x0a	--TCP connection error for CONNECT method	[RFC9113, Section 7]
local ENHANCE_YOUR_CALM<const>		=0x0b	--Processing capacity exceeded	[RFC9113, Section 7]
local INADEQUATE_SECURITY<const>	=0x0c	--Negotiated TLS parameters not acceptable	[RFC9113, Section 7]
local HTTP_1_1_REQUIRED<const>		=0x0d	--Use HTTP/1.1 for the request	[RFC9113, Section 7]

local err_str = {
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
}

function C.close(ch)
	local fd = ch.fd
	if fd then
		ch.fd = nil
		ch.transport.close(fd)
	end
end

local channel_mt = {
	__index = C,
	__gc = C.close,
}

local stream_mt = {
	__index = S,
	__close = function(t) t:close() end,
}

local server_stream_q = {}

---@param fd integer
---@param read fun(fd:integer, size:integer):string|nil
---@return integer?, integer?, string?, integer?
local function read_frame(fd, read)
	local x9, err = read(fd, 9)
	if err then
		return nil, nil, nil, nil
	end
	local n, t, f, id = unpack(">I3I1I1I4", x9)
	-- RFC 7540 Section 4.1: Ignore the reserved bit (bit 32) in stream identifier
	id = id & 0x7FFFFFFF
	local dat = n > 0 and read(fd, n) or ""
	return t, f, dat, id
end

---@param ch silly.net.http.h2stream.channel
local function try_wakeup_connect(ch)
	local wait = ch.wait_for_conn
	if not wait then -- server side has no wait queue
		return
	end
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
	if m < n then
		m = m + 1
		move(wait, m, n, 1)
		for i = n-m+2, n do
			wait[i] = nil
		end
	end
end

local function try_read_header(ch, stream_id, flag, dat)
	local offset = 1
	local strip = 0
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
		dat = dat:sub(offset, -(strip + 1))
	end
	local header_list = {}
	if flag & END_HEADERS == END_HEADERS then --all headers
		local ok = hpack_unpack(ch.recv_hpack, dat, header_list)
		if not ok then
			return nil, COMPRESSION_ERROR
		end
	else
		local fd = ch.fd
		local read = ch.transport.read
		local tbl = {dat}
		repeat
			local t, f, d, id = read_frame(fd, read)
			if not t or t ~= FRAME_CONTINUATION or id ~= stream_id then
				-- Interleaved frame of wrong type or on wrong stream is a PROTOCOL_ERROR
				return nil, PROTOCOL_ERROR
			end
			tbl[#tbl + 1] = d
		until f & END_HEADERS == END_HEADERS
		local ok = hpack_unpack(ch.recv_hpack, tbl, header_list)
		if not ok then
			return nil, COMPRESSION_ERROR
		end
	end
	return header_list, nil
end

local function delay_close(s)
	local ch = s.channel
	if not ch then -- connection is closed
		return
	end
	s.channel = nil
	ch.streams[s.id] = nil
end

local function check_close(s)
	-- passive stream don't have localclose
	local remotestate = s.remotestate
	if remotestate < STATE_CLOSE then
		return
	end
	if s.localclose and not s.closing then
		s.closing = true
		local ch = s.channel
		time.after(1000, delay_close, s)
		ch.stream_count = ch.stream_count - 1
		if s.active then
			try_wakeup_connect(ch)
		end
	end
	local co = s.readco
	if co then
		s.readco = nil
		wakeup(co, remotestate == STATE_END and "ok" or s.remoteerror)
	end
	co = s.writeco
	if co then
		s.writeco = nil
		wakeup(co, remotestate == STATE_END and "ok" or s.remoteerror)
	end
end

local function stream_reset(ch, id, errorcode)
	local s = ch.streams[id]
	ch.transport.write(ch.fd, build_rst(id, errorcode))
	if not s then
		return
	end
	s.localclose = true
	s.remotestate = STATE_RST
	s.remoteerror = "stream reset"
	check_close(s)
end

local function channel_goaway(ch, errorcode)
	ch.goaway = true
	ch.transport.write(ch.fd, build_goaway(ch.stream_idx, errorcode))
end


local function to_header_map(header_list)
	local header = {}
	for i = 1, #header_list, 2 do
		local k = header_list[i]
		local v = header_list[i + 1]
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
	return header
end

local function frame_header_client(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	if not s then
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540: Check stream state
	if s.remotestate >= STATE_CLOSE then
		-- RFC 7540 Section 5.1:
		-- - After RST_STREAM: stream error (RST_STREAM)
		-- - After END_STREAM: connection error (GOAWAY) if both sides closed
		if s.remotestate == STATE_RST or not s.localclose then
			stream_reset(ch, id, STREAM_CLOSED)
		else
			-- Stream closed by END_STREAM from both sides
			channel_goaway(ch, STREAM_CLOSED)
		end
		return
	end

	local state = s.remotestate
	if state == STATE_NONE then
		s.remotestate = STATE_HEADER
	else
		s.remotestate = STATE_TRAILER
	end
	local header_list, err = try_read_header(ch, id, flag, dat)
	if not header_list then
		channel_goaway(ch, err)
		return
	end
	local header = to_header_map(header_list)
	local headers = s.headers
	headers[#headers + 1] = header
	if flag & END_STREAM == END_STREAM then
		s.remotestate = STATE_END
		s.remoteerror = "end of stream"
		check_close(s)
	end
	local co = s.readco
	if co then
		s.readco = nil
		wakeup(co, "ok")
	end
end

---@class silly.net.http.h2stream.channel_server:silly.net.http.h2stream.channel
---@field handler fun()

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

local function check_req_header(header_list, first_header)
	local header_mask = 0
	local normal_header_appeared = false
	-- RFC 7540 Section 8.1.2: Header field names MUST be lowercase
	-- RFC 7540 Section 8.1.2.1: Validate pseudo-header fields
	-- RFC 7540 Section 8.1.2.2: Connection-specific header fields
	for i = 1, #header_list, 2 do
		local k = header_list[i]
		local v = header_list[i + 1]
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

---@param ch silly.net.http.h2stream.channel_server
local function frame_header_server(ch, id, flag, dat)
	local header_list, errcode = try_read_header(ch, id, flag, dat)
	if not header_list then
		-- RFC 7540 Section 4.3: COMPRESSION_ERROR is a connection error
		channel_goaway(ch, errcode)
		return
	end
	local streams = ch.streams
	local s = streams[id]
	local first_header = not s
	if ch.goaway and first_header then
		stream_reset(ch, id, PROTOCOL_ERROR)
		return
	end
	if not first_header and s.remotestate >= STATE_CLOSE then
		if s.remotestate == STATE_RST or not s.localclose then
			-- Stream closed by RST, or only remote closed (half-closed remote)
			stream_reset(ch, id, STREAM_CLOSED)
		else
			-- Stream closed by END_STREAM from both sides: connection error
			channel_goaway(ch, STREAM_CLOSED)
		end
		return
	end
	local err = check_req_header(header_list, first_header)
	if err then
		-- RFC 7540 Section 8.1.2: Invalid request headers are stream errors
		stream_reset(ch, id, PROTOCOL_ERROR)
		return
	end
	local header = to_header_map(header_list)
	if first_header then
		-- RFC 7540 Section 5.1.1: Validate stream identifier
		-- 1. Client-initiated streams MUST use odd-numbered identifiers
		if id % 2 == 0 then
			channel_goaway(ch, PROTOCOL_ERROR)
			return
		end
		-- 2. Stream identifier MUST be numerically greater than all previous streams
		if id <= ch.stream_idx then
			if id < ch.stream_idx then
				-- Stream ID went backwards - connection error (PROTOCOL_ERROR)
				channel_goaway(ch, PROTOCOL_ERROR)
			else
				-- id == stream_idx, stream was already used and closed - stream error
				ch.transport.write(ch.fd, build_rst(id, STREAM_CLOSED))
			end
			return
		end
		-- RFC 7540 Section 5.1.2: Check concurrent stream limit
		-- Streams in "open" or "half-closed" states count toward the limit
		if ch.stream_count >= ch.stream_max then
			-- Exceeded advertised concurrent stream limit
			ch.transport.write(ch.fd, build_rst(id, REFUSED_STREAM))
			return
		end
		ch.stream_idx = id
		ch.stream_count = ch.stream_count + 1
		local path, query = parsetarget(header[':path'])
		-- RFC 7540 Section 8.1.2.6: Validate content-length if present
		local content_length = header['content-length']
		if content_length then
			content_length = tonumber(content_length)
			if not content_length or content_length < 0 then
				ch.transport.write(ch.fd, build_rst(id, PROTOCOL_ERROR))
				return
			end
		end
		local s = setmetatable({
			version = "HTTP/2",
			headers = {header},
			method = header[':method'],
			path = path,
			query = query,
			remoteaddr = ch.remoteaddr,
			--private members
			id = id,
			co = false,
			active = false,
			channel = ch,
			localclose = false,
			closing = false,
			remotestate = nil,
			remoteerror = nil,
			send_window = ch.initial_window_size,  -- Stream-level send window
			content_length = content_length,  -- Expected content length from header
			received_length = 0,  -- Actual received DATA payload length
			[1] = nil,	--for stash data
		}, stream_mt)
		if flag & END_STREAM == END_STREAM then
			s.remotestate = STATE_END
			s.remoteerror = "end of stream"
			-- RFC 7540 Section 8.1.2.6: Validate content-length for requests without body
			if content_length and content_length ~= 0 then
				ch.transport.write(ch.fd, build_rst(id, PROTOCOL_ERROR))
				return
			end
		else
			s.remotestate = STATE_HEADER
		end
		ch.streams[id] = s
		server_stream_q[#server_stream_q + 1] = s
		task.fork(ch.handler)
	else
		-- RFC 7540 Section 8.1: Trailing header blocks MUST have END_STREAM flag
		if flag & END_STREAM ~= END_STREAM then
			ch.transport.write(ch.fd, build_rst(id, PROTOCOL_ERROR))
			return
		end
		s.header = header
		s.remotestate = STATE_END
		s.remoteerror = "end of stream"
		check_close(s)
	end
end

local function frame_data(ch, id, flag, dat)
	local streams = ch.streams
	local s = streams[id]
	if not s then
		-- Stream is idle. Receiving DATA is a connection error.
		channel_goaway(ch, PROTOCOL_ERROR)
		return
	end
	-- RFC 7540: Check stream state
	if s.remotestate >= STATE_CLOSE then
		-- RFC 7540 Section 5.1:
		-- - After RST_STREAM: stream error (RST_STREAM)
		-- - After END_STREAM: connection error (GOAWAY) if both sides closed
		if s.remotestate == STATE_RST or not s.localclose then
			-- Stream closed by RST, or only remote closed (half-closed remote)
			stream_reset(ch, id, STREAM_CLOSED)
		else
			-- Stream closed by END_STREAM from both sides
			channel_goaway(ch, STREAM_CLOSED)
		end
		return
	end
	local fd = ch.fd
	local write = ch.transport.write
	s.remotestate = STATE_DATA
	-- RFC 7540 Section 8.1.2.6: Track received data length for content-length validation
	s.received_length = s.received_length + #dat

	if flag & END_STREAM == END_STREAM then
		s.remotestate = STATE_END
		s.remoteerror = "end of stream"
		-- RFC 7540 Section 8.1.2.6: Validate content-length matches actual received length
		if s.content_length and s.received_length ~= s.content_length then
			stream_reset(ch, id, PROTOCOL_ERROR)
			return
		end
		write(fd, build_winupdate(0, 0, #dat))
		check_close(s)
	else
		write(fd, build_winupdate(id, 0, #dat))
	end
	s[#s + 1] = dat
	local co = s.readco
	if co then
		s.readco = nil
		wakeup(co, "ok")
	end
end

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
		-- ACK received, nothing more to do
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
			ch.enable_push = (val == 1)
		elseif id == SETTINGS_INITIAL_WINDOW_SIZE  then
			-- SETTINGS_INITIAL_WINDOW_SIZE: max value is 2^31-1 (0x7FFFFFFF)
			if val > 0x7FFFFFFF then
				channel_goaway(ch, FLOW_CONTROL_ERROR)
				return
			end
			-- RFC 7540 Section 6.9.2: Adjust all existing stream windows by the difference
			local delta = val - ch.initial_window_size
			ch.initial_window_size = val
			if delta ~= 0 then
				for _, s in pairs(ch.streams) do
					s.send_window = s.send_window + delta
					-- Check for overflow after adjustment
					if s.send_window > 0x7FFFFFFF then
						channel_goaway(ch, FLOW_CONTROL_ERROR)
						return
					end
					-- Note: Negative windows are allowed and must be tracked
					-- If window became positive, wake up the stream
					if s.send_window > 0 and delta > 0 then
						local co = s.writeco
						if co then
							s.writeco = nil
							wakeup(co, "ok")
						end
					end
				end
			end
		elseif id == SETTINGS_MAX_FRAME_SIZE then
			-- SETTINGS_MAX_FRAME_SIZE: must be between 2^14 (16384) and 2^24-1 (16777215)
			if val < 16384 or val > 16777215 then
				channel_goaway(ch, PROTOCOL_ERROR)
				return
			end
			ch.frame_max_size = val
		elseif id == SETTINGS_HEADER_TABLE_SIZE then
			hpack_hardlimit(ch.recv_hpack, val)
		elseif id == SETTINGS_MAX_CONCURRENT then
			ch.stream_max = val
			try_wakeup_connect(ch)
		elseif id == SETTINGS_MAX_HEADER_LIST_SIZE then
			-- SETTINGS_MAX_HEADER_LIST_SIZE is advisory only, no error checking needed
			ch.max_header_list_size = val
		else
			logger.warn("[h2stream] unknown settings id:", id)
		end
	end
	-- RFC 7540 Section 6.5.3: Must immediately emit a SETTINGS frame with ACK flag
	ch.transport.write(ch.fd, build_setting(ACK))
end

local function frame_priority(ch, id, _, dat)
	-- RFC 7540 Section 6.3: PRIORITY frame always identifies a stream
	-- If received with stream identifier 0x0, this is a connection error
	if id == 0 then
		ch.transport.write(ch.fd, build_goaway(0, PROTOCOL_ERROR))
		ch:close()
		return
	end
	-- RFC 7540 Section 5.3.1: A stream cannot depend on itself
	-- PRIORITY frame payload: 5 bytes (4 bytes dependency + 1 byte weight)
	if #dat ~= 5 then
		-- Invalid frame size
		ch.transport.write(ch.fd, build_goaway(id, FRAME_SIZE_ERROR))
		ch:close()
		return
	end
	local dependency = unpack(">I4", dat)
	dependency = dependency & 0x7FFFFFFF  -- Clear E bit
	if dependency == id then
		-- Stream depends on itself
		stream_reset(ch, id, PROTOCOL_ERROR)
		return
	end
	-- We don't implement priority, so just ignore it
end

local function frame_ping(ch, stream_id, flag, dat)
	-- RFC 7540 Section 6.7: PING frames are not associated with any individual stream
	-- If a PING frame is received with a stream identifier field value other than 0x0,
	-- the recipient MUST respond with a connection error of type PROTOCOL_ERROR
	if stream_id ~= 0 then
		ch.transport.write(ch.fd, build_goaway(0, PROTOCOL_ERROR))
		ch:close()
		return
	end
	-- RFC 7540 Section 6.7: PING frames MUST contain exactly 8 bytes
	if #dat ~= 8 then
		ch.transport.write(ch.fd, build_goaway(0, FRAME_SIZE_ERROR))
		ch:close()
		return
	end
	-- RFC 7540 Section 6.7: If ACK flag is set, do not respond
	if flag & ACK == ACK then
		-- This is a PING response, do nothing
		return
	end
	-- Send PING response with ACK flag
	local fd = ch.fd
	local write = ch.transport.write
	write(fd, pack(">I3I1I1I4", #dat, FRAME_PING, ACK, 0) .. dat)
end

local function frame_rst(ch, id, _, dat)
	-- RFC 7540 Section 6.4: RST_STREAM frames MUST be 4 octets in length
	if #dat ~= 4 then
		ch.transport.write(ch.fd, build_goaway(id, FRAME_SIZE_ERROR))
		ch:close()
		return
	end

	local s = ch.streams[id]
	if s then
		s.remotestate = STATE_RST
		local err = err_str[unpack(">I4", dat)] or "unknown error"
		s.remoteerror = err
		local co = s.readco
		if co then
			s.readco = nil
			wakeup(co, err)
		end
		co = s.writeco
		if co then
			s.writeco = nil
			wakeup(co, err)
		end
	else
		-- RST_STREAM on an idle stream is a connection error.
		ch.transport.write(ch.fd, build_goaway(id, PROTOCOL_ERROR))
		ch:close()
	end
end

local function frame_goaway(ch, stream_id, flag, dat)
	-- RFC 7540 Section 6.8: GOAWAY frames MUST be sent on stream 0
	if stream_id ~= 0 then
		ch.transport.write(ch.fd, build_goaway(0, PROTOCOL_ERROR))
		ch:close()
		return
	end

	local wait = ch.wait_for_conn
	if not wait then
		-- Server-side doesn't have wait_for_conn
		return
	end
	local err = "goaway:" .. dat
	for i = 1, #wait do
		wakeup(wait[i], err)
	end
end

local function try_wakeup_writer(ch)
	if ch.send_window <= 0 then
		return
	end
	-- Wake up waiting streams
	local q = ch.wait_for_write
	while #q > 0 do
		local s = remove(q, 1)
		if not s then
			break
		end
		local co = s.writeco
		if co then
			s.writeco = nil
			wakeup(co, "ok")
			break
		end
	end
end

---@param ch silly.net.http.h2stream.channel
---@param id integer
---@param flag integer
---@param dat string
local function frame_winupdate(ch, id, flag, dat)
	-- RFC 7540 Section 6.9: WINDOW_UPDATE frames MUST be 4 octets in length
	if #dat ~= 4 then
		ch.transport.write(ch.fd, build_goaway(id, FRAME_SIZE_ERROR))
		ch:close()
		return
	end
	local increment = unpack(">I4", dat)
	-- RFC 7540 Section 6.9.1: Flow control window increment of 0 MUST be treated as error
	if increment == 0 then
		if id == 0 then
			-- Connection-level WINDOW_UPDATE with increment=0 is a connection error
			ch.transport.write(ch.fd, build_goaway(0, PROTOCOL_ERROR))
			ch:close()
		else
			-- Stream-level WINDOW_UPDATE with increment=0 is a stream error
			ch.transport.write(ch.fd, build_rst(id, PROTOCOL_ERROR))
		end
		return
	end
	if id == 0 then
		-- Connection-level WINDOW_UPDATE: update connection send window
		ch.send_window = ch.send_window + increment
		-- RFC 7540 Section 6.9.1: Window size MUST NOT exceed 2^31-1
		if ch.send_window > 0x7FFFFFFF then
			ch.transport.write(ch.fd, build_goaway(0, FLOW_CONTROL_ERROR))
			ch:close()
			return
		end
		try_wakeup_writer(ch)
	else
		-- Stream-level WINDOW_UPDATE: update stream send window
		local s = ch.streams[id]
		if not s then
			-- WINDOW_UPDATE on an idle stream is a connection error.
			ch.transport.write(ch.fd, build_goaway(id, PROTOCOL_ERROR))
			ch:close()
			return
		end
		s.send_window = s.send_window + increment
		-- RFC 7540 Section 6.9.1: Window size MUST NOT exceed 2^31-1
		if s.send_window > 0x7FFFFFFF then
			ch.transport.write(ch.fd, build_rst(id, FLOW_CONTROL_ERROR))
			return
		end
		if s.send_window > 0 then
			-- Wake up this stream if it's waiting
			local co = s.writeco
			if co then
				s.writeco = nil
				wakeup(co, "ok")
			end
		end
	end
end

local function frame_continuation(ch, id, f, d)
	-- RFC 7540 Section 6.10: CONTINUATION frames are only valid following
	-- HEADERS/PUSH_PROMISE without END_HEADERS. Legal CONTINUATION frames
	-- are consumed internally by try_read_header().
	-- If we see one here, it's orphaned (appears after END_HEADERS).
	ch.transport.write(ch.fd, build_goaway(id, PROTOCOL_ERROR))
	ch:close()
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
		ch.transport.write(ch.fd, build_goaway(id, PROTOCOL_ERROR))
		ch:close()
	end,
}

local function common_dispatch(ch, frame_process)
	local read = ch.transport.read
	local write = ch.transport.write
	local fd = ch.fd
	while true do
		local t,f,d,id = read_frame(fd, read)
		if not t then
			ch.transport.close(fd)
			ch.fd = nil
			break
		end
		-- Validate frame size according to SETTINGS_MAX_FRAME_SIZE
		local frame_len = #d
		if frame_len > ch.frame_max_size then
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
	local t = ch.streams
	for _, v in pairs(t) do
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
		v.localclose = true
		v.remotestate = STATE_CLOSE
		v.remoteerror = "channel closed"
	end
end

local function client_dispatch(ch)
	return function()
		common_dispatch(ch, frame_client)
		local wait = ch.wait_for_conn
		for i = 1, #wait do
			wakeup(wait[i], "channel closed")
		end
	end
end

---@param ch silly.net.http.h2stream.channel
local function handshake_as_client(ch, transport)
	local fd = ch.fd
	local write = transport.write
	local ok, err = write(fd, client_preface)
	if not ok then
		return false, err
	end
	local dat = build_setting(0x0,
		SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, max_stream_per_channel,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	write(fd, dat)
	local read = transport.read
	local t, f, dat, id = read_frame(fd, read)
	if not t or t ~= FRAME_SETTINGS then
		return false, "expect settings"
	end
	frame_settings(ch, id, f, dat)
	write(fd, build_setting(0x01))
	while true do
		local t,f,dat,id = read_frame(fd, read)
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
	ch.dispatchco = task.fork(client_dispatch(ch))
	return true, "ok"
end

local function handshake_as_server(ch, transport)
	local fd = ch.fd
	local write = transport.write
	local read = transport.read

	-- According to RFC 7540, server must validate connection preface BEFORE sending SETTINGS
	-- If preface is invalid, server should send GOAWAY with PROTOCOL_ERROR
	local dat = read(fd, client_preface_size)
	if dat ~= client_preface then
		-- Send GOAWAY with PROTOCOL_ERROR before closing
		write(fd, build_goaway(0, PROTOCOL_ERROR))
		return false
	end

	-- Only after valid preface, send SETTINGS frame
	dat = build_setting(0x0,
		SETTINGS_ENABLE_PUSH, 0, SETTINGS_MAX_CONCURRENT, max_stream_per_channel,
		SETTINGS_HEADER_TABLE_SIZE, default_header_table_size
	)
	local ok = write(fd, dat)
	if not ok then
		return false
	end

	local t,f,dat,id = read_frame(fd, read)
	if not t or t ~= FRAME_SETTINGS then
		return false
	end
	frame_settings(ch, id, f, dat)
	local ok = write(fd, build_setting(0x01))
	if not ok then
		return false
	end
	while true do
		local t,f,dat,id = read_frame(fd, read)
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

function M.httpd(handler, fd, transport, addr)
	local ch = setmetatable({
		--client and server common
		fd = fd,
		remoteaddr = addr,
		transport = transport,
		streams = {},
		stream_count = 0,
		wait_for_write = {},
		send_hpack = hpack_new(default_header_table_size),
		recv_hpack = hpack_new(default_header_table_size),
		stream_max = max_stream_per_channel,
		max_header_list_size = 0,
		window_size = default_window_size,  -- Connection-level receive window
		send_window = default_window_size,  -- Connection-level send window
		initial_window_size = default_window_size,  -- Stream initial window size (from SETTINGS)
		frame_max_size = default_frame_size,
		stream_idx = 0,
		--server more
		goaway = false,
		handler = function()
			handler(remove(server_stream_q, 1))
		end
	}, channel_mt)
	local ok = handshake_as_server(ch, transport)
	if ok then
		common_dispatch(ch, frame_server)
	end
end

---@param ch silly.net.http.h2stream.channel
---@return silly.net.http.h2stream|nil, string|nil
function C.open_stream(ch)
	if ch.stream_count >= ch.stream_max then
		local t = ch.wait_for_conn
		t[#t + 1] = task.running()
		local reason = task.wait()
		if reason ~= "ok" then
			return nil, reason
		end
		assert(ch.stream_count <= ch.stream_max)
	end
	local id = ch.stream_idx + 2
	-- RFC 7540: Stream identifiers cannot be reused
	-- If we've exhausted the stream ID space, the connection must be closed
	if id > 0x7fffffff then
		return nil, "stream id exhausted"
	end
	ch.stream_idx = id
	---@class silly.net.http.h2stream : silly.net.http.h2stream_mt
	local stream = setmetatable({
		id = id,
		readco = nil,
		writeco = nil,
		active = true,
		channel = ch,
		localclose = false,
		closing = false,
		remotestate = STATE_NONE,
		remoteerror = nil,
		headers = {},
		sendheader = nil,
		status = nil,
		version = "HTTP/2",
		remoteaddr = ch.remoteaddr,
		received_length = 0,
		send_window = ch.initial_window_size,  -- Stream-level send window
		[1] = nil,	--for stash data
	}, stream_mt)
	ch.streams[id] = stream
	ch.stream_count = ch.stream_count + 1
	return stream, "ok"
end

---@param scheme string
---@param fd integer
---@param transport silly.net.tcp | silly.net.tls
---@param addr string?
---@return silly.net.http.h2stream.channel?, string? error
function M.newchannel(scheme, fd, transport, addr)
	---@class silly.net.http.h2stream.channel:silly.net.http.h2stream.channel_mt
	local ch = setmetatable({
		--client and server common
		fd = fd,
		remoteaddr = addr,
		transport = transport,
		headers = {},
		streams = {},
		send_hpack = hpack_new(default_header_table_size),
		recv_hpack = hpack_new(default_header_table_size),
		stream_max = max_stream_per_channel,
		window_size = default_window_size,  -- Connection-level receive window
		send_window = default_window_size,  -- Connection-level send window
		initial_window_size = default_window_size,  -- Stream initial window size (from SETTINGS)
		frame_max_size = default_frame_size,
		wait_for_write = {},
		enable_push = false,
		goaway = false,
		--client more
		dispatchco = nil,
		wait_for_conn = {},
		stream_idx = -1,
		stream_count = 0,
		scheme = scheme,
	}, channel_mt)
	local ok, reason = handshake_as_client(ch, transport)
	if ok then
		return ch, nil
	end
	transport.close(fd)
	return nil, reason
end

function S.request(s, method, path, header, close)
	local ch = s.channel
	if not ch then
		return false, "channel closed"
	end
	if s.localclose then
		return false, "local closed"
	end
	local host = header["host"]
	header["host"] = nil
	local hdr = hpack_pack(ch.send_hpack, header,
		":authority", host,
		":method", method,
		":path", path,
		":scheme", ch.scheme)
	if close then
		s.localclose = true
		check_close(s)
	end
	local dat = build_header(s.id, ch.frame_max_size, hdr, close)
	return ch.transport.write(ch.fd, dat)
end

local function read_timer(s)
	s.localclose = true
	s.remotestate = STATE_RST
	s.remoteerror = "timeout"
	check_close(s)
	stream_reset(s.channel, s.id, CANCEL)
end

local function wait(s, expire)
	local reason
	if expire then
		local timer = time.after(expire, read_timer, s)
		reason = task.wait()
		if reason ~= "timeout" then
			time.cancel(timer)
		end
	else
		reason = task.wait()
	end
	return reason
end

---@param s silly.net.http.h2stream
---@param expire number?
---@return table<string, string>|nil, string?
local function read_header(s, expire)
	local headers = s.headers
	local header = remove(headers, 1)
	if not header then
		if s.remotestate >= STATE_CLOSE then
			return nil, s.remoteerror
		end
		s.readco = task.running()
		local reason = wait(s, expire)
		if reason ~= "ok" then
			return nil, reason
		end
		header = remove(headers ,1)
	end
	if header[':authority'] then
		header['host'] = header[':authority']
	end
	return header, "ok"
end

---@param s silly.net.http.h2stream
---@param expire number?
function S.readheader(s, expire)
	local header, reason = read_header(s, expire)
	if not header then
		return nil, reason
	end
	return tonumber(header[':status']) or 200, header
end

S.readtrailer = read_header

---@param s silly.net.http.h2stream
---@param status integer
---@param header table<string, string|string[]|number>
---@param close boolean?
---@return boolean, string|?
function S.respond(s, status, header, close)
	local ch = s.channel
	if not ch then
		return false, "channel closed"
	end
	if s.localclose then
		return false, "local closed"
	end
	if close then
		s.localclose = true
		check_close(s)
		local hdr = hpack_pack(ch.send_hpack, header, ":status", status)
		local dat = build_header(s.id, ch.frame_max_size, hdr, close)
		return ch.transport.write(ch.fd, dat), "ok"
	else
		s.status = status
		s.sendheader = header
	end
	return true, "ok"
end

local function write_func(close)
	---@param s silly.net.http.h2stream
	---@param dat string|nil
	---@return boolean, string?
	return function(s, dat)
		local ch = s.channel
		if not ch then
			return false, "channel closed"
		end
		if s.localclose then
			return false, "local closed"
		end
		local fd = ch.fd
		if not fd then
			return false, "socket not connected"
		end
		local write = ch.transport.write
		local header = s.sendheader
		if header then
			s.sendheader = nil
			local hdr
			local status = s.status
			if status then
				s.status = nil
				hdr = hpack_pack(ch.send_hpack, header, ":status", status)
			else
				hdr = hpack_pack(ch.send_hpack, header)
			end
			if close and not dat then
				local data = build_header(s.id, ch.frame_max_size, hdr, close)
				return write(fd, data)
			else
				local data = build_header(s.id, ch.frame_max_size, hdr, false)
				write(fd, data)
			end
		end
		dat = dat or ""
		local body_offset = 0  -- C offset starts at 0
		local body_remaining = #dat
		local ok = true
		local err
		while body_remaining > 0 do
			-- RFC 7540 Section 6.9: Flow control operates at two levels
			-- Both stream window and connection window must have space
			local conn_win = ch.send_window
			local stream_win = s.send_window
			if conn_win <= 0 or stream_win <= 0 then
				assert(not s.writeco, "[silly.net.http.h2stream] write can't be called in race")
				local co = task.running()
				s.writeco = co
				if conn_win <= 0 then
					local wait = ch.wait_for_write
					wait[#wait + 1] = s
				end
				local reason = task.wait()
				if reason ~= "ok" then
					ok = false
					err = reason
					break
				end
				-- Continue to next iteration to recheck windows
			else
				-- Calculate how much we can send
				local max_write = stream_win < conn_win and stream_win or conn_win
				if max_write > body_remaining then
					max_write = body_remaining
				end

				-- Only set END_STREAM on the last chunk
				local is_last_chunk = (max_write == body_remaining)
				-- Use the new build_body signature with offset and length
				local chunk = build_body(s.id, ch.frame_max_size, dat, body_offset, max_write, close and is_last_chunk)
				local ok, reason = write(fd, chunk)
				if not ok then
					ok = false
					err = reason
					break
				end
				-- Decrement both stream and connection windows
				s.send_window = s.send_window - max_write
				ch.send_window = ch.send_window - max_write
				-- Update offset and remaining
				body_offset = body_offset + max_write
				body_remaining = body_remaining - max_write
			end
		end
		try_wakeup_writer(ch)
		return ok, err
	end
end

local write = write_func(false)
local write_end = write_func(true)
S.write = write

---@param s silly.net.http.h2stream
---@param data string|nil
---@param trailer table<string, string|string[]|number>|nil
function S.close(s, data, trailer)
	if s.localclose then
		return
	end
	if not trailer then
		write_end(s, data)
	else
		write(s, data)
		s.sendheader = trailer
		write_end(s, nil)
	end
	s.localclose = true
	check_close(s)
end


local function read(s, expire)
	local dat = remove(s, 1)
	if dat then
		return dat, nil
	end
	if s.remotestate >= STATE_TRAILER then
		return "", s.remoteerror or "end of stream"
	end
	s.readco = task.running()
	local reason = wait(s, expire)
	if reason ~= "ok" then
		return nil, reason
	end
	dat = remove(s, 1)
	if dat then
		return dat, nil
	end
	return "", s.remoteerror or "end of stream"
end

S.read = read
function S.readall(s, expire)
	local buf = {}
	while s.remotestate < STATE_CLOSE or #s > 0 do
		local dat, reason = read(s, expire)
		if not dat then
			return nil, reason
		end
		if dat == "" then
			break
		end
		buf[#buf + 1] = dat
	end
	return concat(buf), nil
end

return M
