-- Pair Lua channels with the Go peer; framing, handshake and I/O deadlines live in Go.
local silly = require "silly"
local pcall = silly.pcall
local task = require "silly.task"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local h2 = require "silly.net.http.h2"
local hpack = require "silly.http2.hpack"
local base64 = require "silly.encoding.base64"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"
local conformance = require "test.conformance"
local M = {}

function M.new(control, port)
	local peer, remote = {}, {}
	local nextport = 20000
	peer.preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	local function open(op, addr)
		local info = assert(control:h2peer({op = op, addr = addr}))
		local ctrl = conformance.connect("127.0.0.1", port)
		return setmetatable({id = info.id, addr = info.addr, ctrl = ctrl}, {__index = remote})
	end
	function remote:call(op, params)
		params = params or {}
		params.op, params.id = op, self.id
		return self.ctrl:h2peer(params)
	end
	---@param data string|string[]
	function remote:write(data)
		if type(data) == "table" then
			data = table.concat(data)
		end
		return self:call("write", {data = base64.encode(data)})
	end
	function remote:read(size, timeout)
		local data, err = self:call("read", {size = size, timeout = timeout})
		return data and base64.decode(data), err
	end
	function remote:close()
		if self.closed then
			return
		end
		self.closed = true
		control:h2peer({op = "close", id = self.id})
	end
	function peer.frame(typ, flags, id, data)
		data = data or ""
		-- Keep explicit wire bytes for deliberately malformed frame fixtures.
		return string.pack(">I3I1I1I4", #data, typ, flags, id) .. data
	end
	local function readframe(conn, op, params)
		local frame, err = conn:call(op, params)
		if frame then
			frame.data = base64.decode(frame.data)
		end
		return frame, err
	end
	function peer.read(conn, timeout)
		return readframe(conn, "frame", {timeout = timeout})
	end
	function peer.untilframe(conn, typ)
		return assert(readframe(conn, "until", {type = typ}))
	end
	function peer.serverhandshake(conn, settings)
		assert(conn:call("serverhandshake", {data = base64.encode(settings or "")}))
	end
	function peer.clienthandshake(conn)
		assert(conn:call("clienthandshake"))
	end
	function peer.headers(encoder, id, status, fields, flags)
		return peer.frame(1, flags or 5, id, hpack.pack(encoder, fields or {}, ":status", status))
	end
	function peer.withclient(run, body, opts)
		local remote = open("listen")
		local conn = assert(tcp.connect(remote.addr))
		local done = channel.new()
		task.fork(function()
			local ok, err = pcall(run, remote)
			remote:close()
			done:push({ok = ok, err = err})
		end)
		local watchdog = time.after(5000, function()
			conn:close()
			remote:close()
		end)
		local observer = testaux.observereads(conn)
		local ch
		local ok, err = pcall(function()
			local cause
			ch, cause = h2.newchannel("http", conn, "example.test")
			if ch and opts then
				ch:keepalive(opts.send_ping_timeout, opts.ping_timeout)
			end
			body(ch, cause, observer)
		end)
		if not ok then
			conn:close()
			remote:close()
		end
		local result = testaux.await(done, "Go peer completed")
		conn:close()
		remote:close()
		remote.ctrl:close()
		time.cancel(watchdog)
		if ch then
			observer:waitclosed()
		end
		assert(ok, not result.ok and tostring(err) .. "\nGo peer: " .. tostring(result.err) or err)
		assert(result.ok, result.err)
	end
	function peer.withserver(handler, body, scheme)
		nextport = nextport + 1
		local addr = "127.0.0.1:" .. nextport
		local done = channel.new()
		local accepted
		local listener = assert(tcp.listen {
			addr = addr,
			accept = function(conn)
				accepted = conn
				local ok, err = pcall(h2.httpd, handler, conn, scheme or "http")
				conn:close()
				done:push({ok = ok, err = err})
			end,
		})
		local remote = open("dial", addr)
		local ok, err = pcall(body, remote)
		remote:close()
		remote.ctrl:close()
		if accepted then
			accepted:close()
		end
		local result = testaux.await(done, "Lua server completed with Go peer")
		listener:close()
		assert(ok, not result.ok and tostring(err) .. "\nGo peer: " .. tostring(result.err) or err)
		assert(result.ok, result.err)
	end
	return peer
end

return M
