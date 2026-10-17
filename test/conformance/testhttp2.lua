local silly = require "silly"
local pcall = silly.pcall
local tls = require "silly.net.tls"
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"
local env = require "silly.env"
local http = require "silly.net.http"
local h2 = require "silly.net.http.h2"
local hpack = require "silly.http2.hpack"
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"
local testaux = require "test.testaux"
local conformance = require "test.conformance"

local _, wait_readers = testaux.trackconnections(tls)
local c = conformance.connect("127.0.0.1", tonumber(env.get("conf_port")) or 19090)
local httpc = http.newclient({
	alpnprotos = {"h2"},
})
local handler
local server = assert(http.listen {
	addr = "127.0.0.1:18084",
	tls = true,
	alpnprotos = {"h2"},
	certs = {{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}},
	handler = function(s)
		testaux.asserteq(s.version, "HTTP/2", "Go request negotiated HTTP/2")
		assert(handler)(s)
	end,
})

local function goserver(name, params, fn)
	params = params or {}
	params.http2 = true
	params.cert = testaux.CERT_DEFAULT
	params.key = testaux.KEY_DEFAULT
	local info, err = c:start_server(name, params)
	assert(info, err)
	local ok, cause = pcall(fn, "https://" .. info.addr)
	c:stop_server(info.server_id)
	if not ok then
		error(cause, 0)
	end
end

-- Standalone HPACK comparisons (Test 202, 205-209, 214-219) are in testhpack.lua.
testaux.case("Test 201: Go HTTP2 client decodes fragmented Lua response headers", function()
	local value = string.rep("0123456789abcdef", 2500)
	handler = function(s)
		s:respond(200, {["x-large"] = value})
		s:closewrite("ok")
	end
	local response, err = c:http_request("GET", "https://127.0.0.1:18084/", {http2 = true})
	assert(response, err)
	testaux.asserteq(response.protocol, "HTTP/2.0", "Go confirms protocol version")
	testaux.asserteq(response.headers["x-large"], value, "Go reassembles CONTINUATION frames")
	testaux.asserteq(response.body, "ok", "fragmented response body")
end)


testaux.case("Test 203: Go HTTP2 enforces response limit on indexed amplification", function()
	local values = {}
	for i = 1, 1200 do
		values[i] = "gzip, deflate"
	end
	local headers = {["accept-encoding"] = values}
	local wire = hpack.pack(hpack.new(4096), headers, ":status", "200")
	testaux.asserteq(wire, "\x88" .. string.rep("\x90", 1200), "Go receives the 1201-byte block")
	handler = function(s)
		assert(s:respond(200, headers))
		assert(s:closewrite())
	end
	local response, err = c:http_request("GET", "https://127.0.0.1:18084/", {http2 = true})
	assert(response, err)
	testaux.asserteq(response.protocol, "HTTP/2.0", "default acceptance is confirmed over HTTP/2")
	testaux.asserteq(response.status, 200, "Go default allows a valid list above 64 KiB")
	testaux.asserteq(response.headers["accept-encoding"], table.concat(values, ", "),
		"default acceptance preserves every repeated value")
	response, err = c:http_request("GET", "https://127.0.0.1:18084/", {
		http2 = true, max_response_header_bytes = 65535,
	})
	testaux.asserteq(response, nil, "Go rejects the same block under an explicit response limit")
	testaux.assertcontains(err, "response header list larger", "Go reports a list size error")
end)

testaux.case("Test 204: Lua HTTP2 client obeys Go small HPACK table across reused requests", function()
	goserver("header_echo", {header_table_size = 64}, function(url)
		local value = string.rep("cached-value", 10)
		for i = 1, 4 do
			local response, err = httpc:get(url, {["x-reused"] = value})
			assert(response, err)
			testaux.asserteq(response.status, 200, "Go accepts repeated small-table requests")
			local echoed = assert(json.decode(response.body))
			testaux.asserteq(echoed.headers["X-Reused"][1], value, "Go decodes correct header value")
		end
	end)
end)


testaux.case("Test 210: Lua client handles Go HTTP2 information response and trailers", function()
	goserver("multi_1xx", {body = "final"}, function(url)
		local response, err = httpc:get(url)
		assert(response, err)
		testaux.asserteq(response.status, 200, "final Go status")
	end)
	goserver("trailers", {body = "trailer body"}, function(url)
		local s<close> = assert(httpc:request("GET", url, {}))
		assert(s:closewrite())
		assert(s:waitresponse(2000))
		testaux.asserteq(s.version, "HTTP/2", "Lua confirms protocol version")
		assert(s:readall(2000))
		testaux.assertneq(next(s.trailer), nil, "Go trailers received")
		testaux.asserteq(s.headeronly, false, "Go trailing HEADERS do not make the initial headers terminal")
	end)
end)

testaux.case("Test 211: Go and Lua agree on receive window growth and padding credit", function()
	local _, wait_peers = testaux.trackconnections(tcp)
	local release = channel.new()
	local function flow_handler(s)
		if s.path == "/release" then
			release:push(true)
			s:respond(204, {})
			return
		end
		testaux.await(release, "Go releases the exhausted request reader")
		local body = assert(s:readall(5000))
		s:respond(200, {})
		s:closewrite(tostring(#body))
	end
	local listener = assert(tcp.listen {
		addr = "127.0.0.1:18085",
		accept = function(conn)
			h2.httpd(flow_handler, conn, "http")
		end,
	})
	local ok, result, err = pcall(c.h2flow, c, "127.0.0.1:18085")
	listener:close()
	release:close()
	wait_peers()
	assert(ok, result)
	assert(result, err)
	testaux.asserteq(result.connection_window, 4 * 1024 * 1024, "Go observes the connection WINDOW_UPDATE expansion")
	testaux.asserteq(result.stream_window, 65535, "connection expansion leaves stream capacity unchanged")
	testaux.asserteq(result.padding_credit, 4, "only padding is returned before the application reads")
	testaux.asserteq(result.read_credit > 0, true, "reading returns credit and permits the final byte")
	testaux.asserteq(result.body, "65536", "exhausted stream completes without counting padding as body")
end)

testaux.case("Test 212: Go HTTP2 client and Lua server exchange large flow-controlled body", function()
	local body = string.rep("0123456789", 30000)
	handler = function(s)
		local incoming = assert(s:readall(5000))
		testaux.asserteq(incoming, body, "Go sends beyond initial stream window")
		s:respond(200, {})
		s:closewrite(body)
	end
	local response, err = c:http_request("POST", "https://127.0.0.1:18084/", {http2 = true, body = body})
	assert(response, err)
	testaux.asserteq(response.protocol, "HTTP/2.0", "large transfer negotiated HTTP/2")
	testaux.asserteq(response.body, body, "Go receives beyond initial stream window")
end)


-- Migrated frame regressions keep their original native test numbers.
do
local task = require "silly.task"
local time = require "silly.time"
local builder = require "silly.http2.framebuilder"
local peer = require("test.conformance.http2").new(c, tonumber(env.get("conf_port")) or 19090)
local frame = peer.frame
local function get(ch)
	local s = assert(ch:openstream())
	assert(s:request("GET", "/", {}))
	assert(s:closewrite())
	return s
end

local function answer(conn, text)
	local request = peer.untilframe(conn, 1)
	assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 1, request.id, text)))
	return request
end

testaux.case("Test 39: PING ignores unknown flags and echoes payload", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		assert(conn:write(frame(6, 8, 0, "12345678")))
		local reply, request
		while not reply or not request do
			local incoming = assert(peer.read(conn))
			if incoming.type == 6 then
				reply = incoming
			end
			if incoming.type == 1 then
				request = incoming
			end
		end
		testaux.asserteq(reply.flags, 1, "PING ACK")
		testaux.asserteq(reply.data, "12345678", "opaque payload echoed")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 1, request.id, "ok")))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "ok", "request survives unknown PING flag")
	end)
end)

testaux.case("Test 40: Graceful client close sends GOAWAY before EOF", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local reply = peer.untilframe(conn, 7)
		local last, code = string.unpack(">I4I4", reply.data)
		testaux.asserteq(last, 0, "client processed no peer-initiated streams")
		testaux.asserteq(code, 0, "graceful GOAWAY")
	end, function(ch)
		assert(ch):close()
	end)
end)

testaux.case("Test 41: GOAWAY rejects openstream even when every stream slot is occupied", function()
	for _, localclose in ipairs({true, false}) do
		local release = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
			local request = peer.untilframe(conn, 1)
			if localclose then
				peer.untilframe(conn, 7)
			else
				assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 0))))
			end
			testaux.await(release, "closed channel rejected stream allocation")
		end, function(ch, err, observer)
			local s<close> = get(assert(ch, err))
			if localclose then
				ch:close()
			else
				observer:waituntil(function()
					return ch.goaway
				end, "peer GOAWAY processed")
			end
			local done = channel.new()
			task.fork(function()
				local stream, cause = ch:openstream()
				done:push({stream = stream, cause = cause})
			end)
			local result = testaux.await(done, "openstream rejects a closed full channel", 1000)
			testaux.asserteq(result.stream, nil, "closed full channel returns no stream")
			testaux.asserteq(result.cause, "Channel goaway", "closed full channel returns GOAWAY")
			release:push(true)
		end)
	end
end)

testaux.case("Test 42: Close rejects an initial HEADERS waiter notified before it resumes", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "notified opener does not delay transport closure")
	end, function(ch)
		local s = get(assert(ch))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			local stream<close> = assert(ch:openstream())
			assert(stream:request("GET", "/", {}))
			started:push(true)
			local ok, err = stream:closewrite()
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "initial HEADERS waiter registered")
		s:close()
		ch:close()
		local result = testaux.await(done, "woken waiter observes close")
		testaux.asserteq(result.ok, false, "woken waiter cannot send after close")
		testaux.asserteq(result.err, "Channel goaway", "woken waiter returns GOAWAY")
		testaux.asserteq(ch.streamcount, 0, "notification does not reserve a slot")
		testaux.asserteq(ch.conn, nil, "unsent stream does not retain the transport")
	end)
end)

testaux.case("Test 43: Requests receive IDs in send order and drain during graceful close", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local ids = {}
		while true do
			local f = assert(peer.read(conn))
			if f.type == 1 then
				ids[#ids + 1] = f.id
			elseif f.type == 7 then
				break
			end
		end
		testaux.asserteq(ids, {1, 3}, "requests consume IDs only in transmission order")
		local encoder = hpack.new(4096)
		for _, id in ipairs(ids) do
			assert(conn:write(peer.headers(encoder, id, "200")))
		end
	end, function(ch)
		local first<close> = assert(assert(ch):openstream())
		local second<close> = assert(ch:openstream())
		for _, stream in ipairs({second, first}) do
			assert(stream:request("GET", "/", {}))
			assert(stream:closewrite())
		end
		testaux.asserteq(second.id, 1, "second object is the first transmitted request")
		testaux.asserteq(first.id, 3, "first object is the second transmitted request")
		ch:close()
		for _, stream in ipairs({second, first}) do
			testaux.asserteq(stream:readall(2000), "", "sent request completes during graceful close")
		end
	end)
end)

testaux.case("Test 44: EOF wakes a queued initial HEADERS writer", function()
	local closepeer = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 1)
		testaux.await(closepeer, "client filled stream slot")
	end, function(ch)
		local s<close> = get(assert(ch))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			local stream<close> = assert(ch:openstream())
			assert(stream:request("GET", "/", {}))
			started:push(true)
			local ok, err = stream:closewrite()
			done:push({ok = ok, cause = err})
		end)
		testaux.await(started, "initial HEADERS waiter started")
		closepeer:push(true)
		local result = testaux.await(done, "initial HEADERS writer wakes on EOF")
		testaux.asserteq(result.ok, false, "EOF prevents sending the queued request")
		testaux.assertneq(result.cause, nil, "writer returns connection error")
		testaux.asserteq(ch.openwaitq:size(), 0, "EOF clears the opener queue")
	end)
end)

testaux.case("Test 45: GOAWAY stops reuse and refuses unprocessed streams", function()
	local release = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, 0))))
		testaux.await(release, "GOAWAY assertions completed")
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(1000)
		testaux.asserteq(ch:isalive(), false, "GOAWAY channel is not reusable")
		testaux.asserteq(ok, false, "unprocessed stream fails promptly")
		testaux.assertneq(err, nil, "GOAWAY cause returned")
		local nextstream, cause = ch:openstream()
		testaux.asserteq(nextstream, nil, "no streams after GOAWAY")
		testaux.assertneq(cause, nil, "openstream has error")
		release:push(true)
	end)
end)

testaux.case("Test 46: Malformed GOAWAY length is a connection error", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		assert(conn:write(frame(7, 0, 0, "short")))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 6, "FRAME_SIZE_ERROR")
	end, function(ch, err, observer)
		observer:waitclosed()
	end)
end)

testaux.case("Test 47: SETTINGS shrink changes encoder, not decoder", function()
	local resized = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local encoder = hpack.new(4096)
		local first = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, first.id, "200", {["x-cache"] = "retained"})))
		local second = peer.untilframe(conn, 1)
		-- A static-only block resets the decoder's eviction cursor.
		assert(conn:write(peer.headers(encoder, second.id, "204")))
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 1, 0))))
		peer.untilframe(conn, 4)
		resized:push(true)
		local third = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, third.id, "200", {["x-cache"] = "retained"})))
	end, function(ch)
		for i = 1, 3 do
			if i == 3 then
				testaux.await(resized, "peer shrink acknowledged before the third request")
			end
			local s<close> = get(assert(ch))
			testaux.asserteq(s:waitresponse(2000), true, "response after peer shrinks its decoder")
			if i ~= 2 then
				testaux.asserteq(s.header["x-cache"], "retained", "incoming dynamic table unchanged")
			end
		end
	end)
end)

testaux.case("Test 48: Informational response precedes final response", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(peer.headers(encoder, request.id, "103", {["link"] = "</style.css>"}, 4)))
		assert(conn:write(peer.headers(encoder, request.id, "200", {["x-final"] = "yes"}, 4) .. frame(0, 1, request.id, "ok")))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:waitresponse(2000), true, "final response received")
		testaux.asserteq(s.status, 200, "final status replaces information response")
		testaux.asserteq(s.header["x-final"], "yes", "final response headers")
		testaux.asserteq(s.header.link, nil, "information headers do not leak into final response")
		testaux.asserteq(s:readall(2000), "ok", "final body")
	end)
end)

testaux.case("Test 49: Initial SETTINGS ACK is rejected", function()
	peer.withclient(function(conn)
		assert(conn:read(#peer.preface, 2000) == peer.preface)
		peer.untilframe(conn, 4)
		assert(conn:write(frame(4, 1, 0) .. frame(4, 1, 0)))
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "invalid handshake closes connection")
	end, function(ch, err)
		testaux.asserteq(ch, nil, "ACK is not a valid preface")
		testaux.assertneq(err, nil, "invalid preface error")
	end)
end)

testaux.case("Test 50: SETTINGS reduction permits negative send windows", function()
	local lowered, started = channel.new(), channel.new()
	local completed = false
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 0)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
		peer.untilframe(conn, 4)
		lowered:push(true)
		testaux.await(started, "writer entered closewrite")
		testaux.asserteq(completed, false, "write blocks while stream window is negative")
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 2))))
		local body = peer.untilframe(conn, 0)
		testaux.asserteq(body.data, "b", "write resumes after window credit")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		assert(s:write("a"))
		testaux.await(lowered, "SETTINGS reduced window")
		testaux.asserteq(s.sendwindow, -1, "SETTINGS reduction makes send window negative")
		started:push(true)
		assert(s:closewrite("b"))
		completed = true
	end)
end)

testaux.case("Test 51: Padding is restored to both receive windows", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		assert(conn:write(frame(0, 8, request.id, "\x03a\0\0\0")))
		local connection, stream = 0, 0
		while connection < 5 or stream < 5 do
			local update = peer.untilframe(conn, 8)
			local n = string.unpack(">I4", update.data)
			if update.id == 0 then
				connection = connection + n
			else
				stream = stream + n
			end
		end
		assert(conn:write(frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:read(1, 2000), "a", "padding excluded from body")
		testaux.asserteq(s:readall(2000), "", "padded stream finishes")
	end)
end)

testaux.case("Test 53: Receive stream window overflow resets only offending stream", function()
	local reset_seen = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		assert(conn:write(string.rep(frame(0, 0, request.id, string.rep("x", 16384)), 3)
			.. frame(0, 0, request.id, string.rep("x", 16383)) .. frame(6, 0, 0, "capacity")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 3, "exact stream capacity must not trigger reset")
			if incoming.type == 6 then
				break
			end
		end
		assert(conn:write(frame(0, 0, request.id, "x")))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 3, "FLOW_CONTROL_ERROR")
		reset_seen:push(true)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		assert(s:waitresponse(2000))
		testaux.await(reset_seen, "peer received stream reset")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "other streams survive receive overflow")
	end)
end)

testaux.case("Test 54: Invalid content length does not consume server slots", function()
	peer.withserver(function(s)
		s:respond(200, {})
		s:closewrite("ok")
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		for id = 1, 199, 2 do
			local data = hpack.pack(encoder, {["content-length"] = "invalid"}, ":method", "GET", ":scheme", "http", ":path", "/")
			assert(conn:write(frame(1, 5, id, data)))
			peer.untilframe(conn, 3)
		end
		local data = hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/")
		assert(conn:write(frame(1, 5, 201, data)))
		local reply = peer.untilframe(conn, 1)
		testaux.asserteq(reply.id, 201, "valid request still admitted")
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "response after malformed requests")
	end)
end)

testaux.case("Test 55: Content length mismatch does not kill unrelated stream", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {["content-length"] = "1"})))
		peer.untilframe(conn, 3)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		local body, err = s:readall(2000)
		testaux.asserteq(body, nil, "malformed response rejected")
		testaux.assertneq(err, nil, "content length mismatch error")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "connection survives malformed response")
	end)
end)

testaux.case("Test 56: Server handler automatic response encoding failure releases its stream", function()
	local returned = channel.new()
	peer.withserver(function(s)
		if s.path == "/fail" then
			local badkey = setmetatable({}, {__tostring = function()
				error("intentional automatic response encoding failure")
			end})
			assert(s:respond(200, {[badkey] = "bad"}))
			returned:push({stream = s, channel = s.channel})
			return
		end
		assert(s:respond(200, {}))
		assert(s:closewrite("ok"))
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {},
			":method", "GET", ":scheme", "http", ":path", "/fail"))))
		local failed = testaux.await(returned, "handler returned before response encoding")
		-- The signal does not yield: encoding and cleanup finish before this reader resumes.
		testaux.asserteq(failed.stream.closed, true, "automatic encoding error closes the stream")
		testaux.asserteq(failed.channel.streamcount, 0, "encoding error releases the slot")
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 2, "encoding failure is INTERNAL_ERROR")
		assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {},
			":method", "GET", ":scheme", "http", ":path", "/"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "next stream survives encoding failure")
	end)
end)

testaux.case("Test 57: Server handler return completes its response and releases its stream", function()
	local returned = channel.new()
	peer.withserver(function(s)
		assert(s:respond(201, {["x-handler"] = "returned"}))
		returned:push({stream = s, channel = s.channel})
		return "ignored"
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
			":method", "GET", ":scheme", "http", ":path", "/"))))
		local reply = peer.untilframe(conn, 1)
		testaux.asserteq(reply.flags & 1, 1, "normal return automatically queues END_STREAM")
		local fields = {}
		assert(hpack.unpack(hpack.new(4096), reply.data, fields))
		testaux.asserteq(fields, {":status", "201", "x-handler", "returned"},
			"automatic completion preserves the chosen response")
		local completed = testaux.await(returned, "handler returned before automatic completion")
		testaux.asserteq(completed.stream.closed, true, "normal return closes its stream")
		testaux.asserteq(completed.channel.streamcount, 0, "normal return releases its slot")
	end)
end)

testaux.case("Test 58: Server handler explicit close cancels its unfinished response", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		s:close()
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
			":method", "GET", ":scheme", "http", ":path", "/"))))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 8,
			"explicit close remains CANCEL instead of flushing a success response")
	end)
end)

testaux.case("Test 59: Server handler nil error resets its stream and releases its slot", function()
	local failed = channel.new()
	peer.withserver(function(s)
		failed:push({stream = s, channel = s.channel})
		error(nil)
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
			":method", "GET", ":scheme", "http", ":path", "/"))))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 2,
			"nil error object is still handler failure, not normal completion")
		local result = testaux.await(failed, "handler raised a nil error")
		testaux.asserteq(result.stream.closed, true, "nil error closes its stream")
		testaux.asserteq(result.channel.streamcount, 0, "nil error releases its slot")
	end)
end)

testaux.case("Test 60: Server handler failure resets its stream and releases slots", function()
	peer.withserver(function(s)
		if s.path == "/fail" then
			error("intentional handler failure")
		end
		s:respond(200, {})
		s:closewrite("ok")
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/fail"))))
		peer.untilframe(conn, 3)
		assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "next request survives handler error")
	end)
end)


testaux.case("Test 64: Server httpd ACKs idle PING requests", function()
	peer.withserver(function() end, function(conn)
		peer.clienthandshake(conn)
		for _, flags in ipairs({0, 8}) do
			assert(conn:write(frame(6, flags, 0, "idleping")))
			local reply = peer.untilframe(conn, 6)
			testaux.asserteq(reply.flags, 1, "server responds with ACK without an active stream")
			testaux.asserteq(reply.data, "idleping", "server echoes the PING payload")
		end
	end)
end)


testaux.case("Test 66: Local reset makes subsequent readall fail immediately", function()
	local arrived, release = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		peer.untilframe(conn, 1)
		arrived:push(true)
		peer.untilframe(conn, 3)
		testaux.await(release, "local reset assertions completed")
	end, function(ch)
		local s = get(assert(ch))
		testaux.await(arrived, "peer received request")
		s:close()
		local started = time.monotonic()
		local body, err = s:readall(500)
		testaux.asserteq(body, nil, "closed stream has no body")
		testaux.asserteq(type(err), "string", "local reset returns a string error")
		testaux.asserteq(time.monotonic() - started < 100, true, "readall does not wait after reset")
		local data, readerr = s:read(1, 500)
		testaux.asserteq(data, nil, "local reset also makes read fail immediately")
		testaux.asserteq(readerr, err, "read preserves the local reset reason")
		release:push(true)
	end)
end)


-- Test 70 is covered by Test 101 below.

testaux.case("Test 71: Late WINDOW_UPDATE for closed client stream is ignored", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		local nextrequest = peer.untilframe(conn, 1)
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 1))))
		assert(conn:write(peer.headers(hpack.new(4096), nextrequest.id, "200")))
	end, function(ch)
		local s = get(assert(ch))
		assert(s:waitresponse(2000))
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:waitresponse(2000), true, "late update does not close channel")
	end)
end)

testaux.case("Test 72: Response trailers require END_STREAM and forbid pseudo-headers", function()
	for _, trailer in ipairs({{flags = 4, fields = {"x-trailer", "value"}}, {flags = 5, fields = {":status", "200"}}}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local encoder = hpack.new(4096)
			assert(conn:write(peer.headers(encoder, request.id, "200", {}, 4)))
			assert(conn:write(frame(1, trailer.flags, request.id, hpack.pack(encoder, {}, table.unpack(trailer.fields)))))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "malformed trailer is a stream error")
		end, function(ch)
			local s<close> = get(assert(ch))
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "invalid trailer fails reader")
			testaux.assertneq(err, nil, "trailer error propagated")
		end)
	end
end)

testaux.case("Test 73: Completed response survives RST_STREAM NO_ERROR", function()
	local reset_processed = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200") .. frame(3, 0, request.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "rst-done")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq(ack.data, "rst-done", "PING barrier follows processed reset")
		reset_processed:push(true)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		testaux.await(reset_processed, "NO_ERROR reset processed")
		testaux.asserteq(s:waitresponse(2000), true, "complete response status survives reset")
		testaux.asserteq(s:readall(2000), "", "complete empty body survives reset")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "connection remains usable")
	end)
end)

testaux.case("Test 74: Completed early response NO_ERROR stops a request without another reset", function()
	local processed, closed = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 0)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200") .. frame(3, 0, request.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "rst-done")))
		peer.untilframe(conn, 6)
		processed:push(true)
		testaux.await(closed, "application released stopped request")
		assert(conn:write(frame(6, 0, 0, "no-reset")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 3, "peer reset must not trigger another reset")
			if incoming.type == 6 then
				break
			end
		end
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		assert(s:write("partial"))
		testaux.await(processed, "early complete response and reset processed")
		testaux.asserteq(s:waitresponse(2000), true, "valid early response survives NO_ERROR")
		testaux.asserteq(s:readall(2000), "", "valid early empty body retained")
		s:close()
		closed:push(true)
	end)
end)

testaux.case("Test 75: Closing a request with a complete response wakes its blocked writer", function()
	local started, responded, finished = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		testaux.await(started, "request writer entered closewrite")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")
			.. frame(6, 0, 0, "response")))
		peer.untilframe(conn, 6)
		responded:push(true)
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(reset.id, request.id, "close cancels the incomplete request")
		testaux.asserteq(string.unpack(">I4", reset.data), 8, "close sends CANCEL")
		answer(conn, "ok")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		task.fork(function()
			started:push(true)
			local ok, err = s:closewrite("blocked")
			finished:push({ok = ok, err = err})
		end)
		testaux.await(responded, "complete response processed before closing request")
		testaux.asserteq(s:readall(2000), "", "early response remains readable")
		s:close()
		local result = testaux.await(finished, "close woke flow-control writer", 2000)
		testaux.asserteq(result.ok, false, "closed request stops blocked writer")
		testaux.asserteq(result.err, "Stream cancelled", "writer gets cancellation reason")
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "connection remains usable")
	end)
end)

testaux.case("Test 76: Server NO_ERROR reset cancels an incomplete response writer", function()
	local finished = channel.new()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		local ok, err = s:closewrite("unfinished")
		finished:push({ok = ok, err = err})
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
		peer.untilframe(conn, 4)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local headers = peer.untilframe(conn, 1)
		testaux.asserteq(headers.flags & 1, 0, "response writer waits for flow-control credit")
		assert(conn:write(frame(3, 0, 1, string.pack(">I4", 0))))
		local result = testaux.await(finished, "reset woke incomplete response writer")
		testaux.asserteq(result.ok, false, "client reset stops response writer")
		testaux.asserteq(result.err, "Graceful shutdown", "server receives reset reason rather than preserving a request as a response")
		assert(conn:write(frame(6, 0, 0, "no-reset")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 3, "server must not reset an already reset stream")
			testaux.assertneq(incoming.type, 0, "server must not continue the canceled response body")
			if incoming.type == 6 then
				break
			end
		end
	end)
end)

testaux.case("Test 77: Disabled server push is rejected after SETTINGS acknowledgement", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(5, 4, request.id, string.pack(">I4", 2) .. hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 1, "disabled push is PROTOCOL_ERROR")
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "disabled push closes connection")
		testaux.assertneq(err, nil, "push error wakes response waiter")
	end)
end)

testaux.case("Test 78: Truncated padding field is rejected", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4) .. frame(0, 8, request.id)))
		local reply = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 6, "missing pad-length byte is FRAME_SIZE_ERROR")
	end, function(ch)
		local s<close> = get(assert(ch))
		local body = s:readall(2000)
		testaux.asserteq(body, nil, "truncated DATA rejected")
	end)
end)

testaux.case("Test 79: Invalid server ENABLE_PUSH setting is rejected", function()
	peer.withclient(function(conn)
		assert(conn:read(#peer.preface, 2000) == peer.preface)
		peer.untilframe(conn, 4)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 2, 1)) .. frame(4, 1, 0)))
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "invalid handshake closes connection")
	end, function(ch, err)
		testaux.asserteq(ch, nil, "server cannot enable push via SETTINGS")
		testaux.assertneq(err, nil, "invalid setting fails handshake")
	end)
end)

testaux.case("Test 80: HTTP2 server uses the scheme supplied by its caller", function()
	for _, scheme in ipairs({"http", "https"}) do
		peer.withserver(function(s)
			s:respond(200, {["x-scheme"] = s.scheme})
			s:closewrite()
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
				":method", "GET", ":scheme", scheme, ":path", "/"))))
			local reply = peer.untilframe(conn, 1)
			local headers = {}
			assert(hpack.unpack(hpack.new(4096), reply.data, headers))
			local received
			for i = 1, #headers, 2 do
				if headers[i] == "x-scheme" then
					received = headers[i + 1]
				end
			end
			testaux.asserteq(received, scheme, "server honors the caller's explicit scheme")
		end, scheme)
	end
end)

for index, finish in ipairs({"HEADERS", "DATA", "trailers", "flow-controlled DATA"}) do
	testaux.case("Test 82." .. index .. ": Completed " .. finish .. " response survives handler cleanup failure", function()
		local release = channel.new()
		peer.withserver(function(s)
			assert(s:respond(200, {}))
			local data = finish ~= "HEADERS" and "valid" or nil
			local trailer = finish == "trailers" and {["x-trailer"] = "done"} or nil
			assert(s:closewrite(data, trailer))
			testaux.await(release, "response received before cleanup fails")
			error("intentional cleanup failure")
		end, function(conn)
			peer.clienthandshake(conn)
			if finish == "flow-controlled DATA" then
				assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
				peer.untilframe(conn, 4)
			end
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
			local complete = false
			while not complete do
				local incoming = assert(peer.read(conn))
				assert(incoming.type ~= 3, "response reset before completion")
				if finish == "flow-controlled DATA" and incoming.type == 1 then
					assert(conn:write(frame(8, 0, 1, string.pack(">I4", 5))))
				end
				complete = (incoming.type == 1 or incoming.type == 0) and incoming.flags & 1 ~= 0
			end
			release:push(true)
			assert(conn:write(frame(6, 0, 0, "cleanup1")))
			while true do
				local incoming = assert(peer.read(conn))
				assert(incoming.type ~= 3, "completed response received RST_STREAM after cleanup failure")
				if incoming.type == 6 then
					break
				end
			end
		end)
	end)
end

testaux.case("Test 83: NO_ERROR preserves local response validation failure", function()
	local processed = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local req = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), req.id, "200", {["content-length"] = "1"}) .. frame(3, 0, req.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "reset-ok")))
		peer.untilframe(conn, 6)
		processed:push(true)
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.await(processed, "all response frames processed")
		local ok, err = s:waitresponse(2000)
		local body, bodyerr = s:readall(2000)
		assert(not ok, "malformed response accepted after RST_STREAM(NO_ERROR)")
		assert(body == nil, "malformed response body exposed as success")
		testaux.asserteq(err, "Protocol error detected", "NO_ERROR preserves original validation error")
		testaux.asserteq(bodyerr, err, "body retains the same validation error")
	end)
end)

for index, informational in ipairs({false, true}) do
	testaux.case("Test 84." .. index .. ": "
		.. (informational and "DATA after 103 resets only its stream"
			or "DATA before final response headers resets only its stream"), function()
		local processed = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local first = peer.untilframe(conn, 1)
			local second = peer.untilframe(conn, 1)
			local enc = hpack.new(4096)
			local dat = informational and peer.headers(enc, first.id, "103", {}, 4) or ""
			assert(conn:write(dat .. frame(0, 0, first.id, "invalid")))
			local reply
			repeat
				reply = assert(peer.read(conn))
			until reply.type == 3 or reply.type == 7
			if reply.type == 3 then
				assert(conn:write(peer.headers(enc, second.id, "200", {}, 4) .. frame(0, 1, second.id, "valid") .. frame(6, 0, 0, "data-end")))
				peer.untilframe(conn, 6)
			end
			processed:push(reply)
		end, function(ch)
			local first<close> = get(assert(ch))
			local second<close> = get(ch)
			local reply = testaux.await(processed, "error scope observed")
			testaux.asserteq(reply.type, 3, "malformed response resets only its stream")
			testaux.asserteq(string.unpack(">I4", reply.data), 1, "expected stream PROTOCOL_ERROR")
			assert(ch:isalive(), "unrelated stream lost its connection")
			assert(second:waitresponse(2000))
			assert(second:readall(2000) == "valid", "unrelated response should remain usable")
		end)
	end)
end

testaux.case("Test 85: DATA on an idle client stream remains a connection error", function()
	local opened = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local id = testaux.await(opened, "local idle stream allocated")
		assert(conn:write(frame(0, 0, id, "invalid")))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1, "idle DATA is connection PROTOCOL_ERROR")
	end, function(ch, err, observer)
		local s<close> = assert(assert(ch):openstream())
		opened:push(1)
		observer:waitclosed()
		testaux.asserteq(ch:isalive(), false, "idle stream DATA closes connection")
	end)
end)

testaux.case("Test 86: Trailer encoding failure resets an incomplete response", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		local badkey = setmetatable({}, {__tostring = function()
			error("intentional trailer encoding failure")
		end})
		local ok, err = pcall(s.closewrite, s, "partial", {[badkey] = "bad"})
		assert(not ok, "trailer encoding must fail")
		error(err)
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local complete = false
		while true do
			local f = assert(peer.read(conn))
			if f.type == 1 or f.type == 0 then
				complete = complete or f.flags & 1 ~= 0
			end
			if f.type == 3 then
				assert(not complete, "response must not have END_STREAM")
				assert(string.unpack(">I4", f.data) == 2, "encoding failure still needs INTERNAL_ERROR")
				break
			end
		end
	end)
end)

testaux.case("Test 87: Completed early response survives handler cleanup failure", function()
	local release = channel.new()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		assert(s:closewrite("valid"))
		testaux.await(release, "early response received")
		error("intentional cleanup failure with request still open")
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 4, 1, hpack.pack(hpack.new(4096), {}, ":method", "POST", ":scheme", "http", ":path", "/"))))
		while true do
			local f = assert(peer.read(conn))
			if (f.type == 0 or f.type == 1) and f.flags & 1 ~= 0 then
				break
			end
		end
		release:push(true)
		assert(conn:write(frame(6, 0, 0, "cleanup2")))
		local codes = {}
		while true do
			local f = assert(peer.read(conn))
			if f.type == 3 then
				codes[#codes + 1] = string.unpack(">I4", f.data)
			end
			if f.type == 6 then
				break
			end
		end
		testaux.asserteq(#codes, 1, "stop unfinished request with exactly one reset")
		testaux.asserteq(codes[1], 0, "NO_ERROR preserves completed early response")
	end)
end)

testaux.case("Test 88: CONNECT rejects missing authority and forbidden scheme or path", function()
	for _, fields in ipairs({{":method", "CONNECT"}, {":method", "CONNECT", ":authority", "example.test:80", ":path", "/"}, {":method", "CONNECT", ":authority", "example.test:80", ":scheme", "http"}}) do
		peer.withserver(function()
			error("invalid CONNECT reached handler")
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, table.unpack(fields)))))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "invalid CONNECT is stream PROTOCOL_ERROR")
		end)
	end
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		assert(s:closewrite())
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "CONNECT", ":authority", "example.test:80"))))
		local response = peer.untilframe(conn, 1)
		local fields = {}
		assert(hpack.unpack(hpack.new(4096), response.data, fields))
		testaux.asserteq(fields, {":status", "200"}, "authority-only CONNECT remains valid")
	end)
end)

testaux.case("Test 89: Invalid and conflicting content lengths reset only the response stream", function()
	for _, value in ipairs({{"1", "2"}, {"1", "invalid"}, {"2", "2.5"}, "", "invalid", "-1", "1.5",
		"9223372036854775808", "18446744073709551616", "1e400"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {["content-length"] = value})))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "invalid content-length is stream PROTOCOL_ERROR")
			answer(conn, "ok")
		end, function(ch)
			local first = get(assert(ch))
			local ok, err = first:waitresponse(2000)
			testaux.asserteq(ok, false, "invalid content-length rejected")
			testaux.asserteq(err, "Protocol error detected", "content-length failure reason")
			first:close()
			local second<close> = get(ch)
			testaux.asserteq(second:readall(2000), "ok", "other response survives validation failure")
		end)
	end
end)

testaux.case("Test 90: Scalar and repeated content lengths accept equivalent numeric formats", function()
	for _, value in ipairs({"02", "+2", "2.0", "2e0", "0x2",
		{"2", "02"}, {"02", "2"}, {"+2", "2.0", "2e0", "0x2"}}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200",
				{["content-length"] = value}, 4) .. frame(0, 1, request.id, "ok")))
			while peer.read(conn) do
			end
		end, function(ch)
			local s = get(ch)
			testaux.asserteq(s:readall(2000), "ok", "equivalent numeric values accept the same body")
			testaux.asserteq(s.recvexpect, 2, "the shared parser derives one expected length")
			s:close()
			ch:close()
		end)
	end
end)


testaux.case("Test 94: Error GOAWAY wakes flow-control writers and stream slot waiters", function()
	local started, waiting, done = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4I2I4", 4, 0, 3, 1))
		local request = peer.untilframe(conn, 1)
		testaux.await(waiting, "both writers are registered")
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 2))))
		testaux.asserteq(peer.read(conn), nil, "error GOAWAY closes transport")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		assert(s:flush())
		task.fork(function()
			local stream<close> = assert(ch:openstream())
			assert(stream:request("GET", "/", {}))
			started:push(true)
			local ok, err = stream:closewrite()
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "slot waiter entered")
		waiting:push(true)
		local ok, err = s:closewrite("blocked")
		testaux.asserteq(ok, false, "error GOAWAY wakes blocked writer")
		testaux.asserteq(err, "Implementation fault", "writer gets peer GOAWAY reason")
		local result = testaux.await(done, "slot waiter aborted")
		testaux.asserteq(result.ok, false, "no initial HEADERS sent after fatal GOAWAY")
		testaux.asserteq(result.err, err, "slot waiter gets same GOAWAY reason")
		testaux.asserteq(s.writedat, nil, "aborted writer releases buffered data")
	end)
end)

testaux.case("Test 95: Graceful GOAWAY wakes slot waiters and completes accepted requests", function()
	local started, waiting, done = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		local request = peer.untilframe(conn, 1)
		testaux.await(waiting, "stream slot waiter registered")
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 0)) .. peer.headers(hpack.new(4096), request.id, "200")))
		testaux.asserteq(peer.read(conn), nil, "accepted stream closure finishes graceful shutdown")
	end, function(ch)
		local s<close> = get(assert(ch))
		task.fork(function()
			local stream<close> = assert(ch:openstream())
			assert(stream:request("GET", "/", {}))
			started:push(true)
			local ok, err = stream:closewrite()
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "slot waiter entered")
		waiting:push(true)
		local result = testaux.await(done, "graceful GOAWAY wakes slot waiter")
		testaux.asserteq(result.ok, false, "graceful GOAWAY rejects queued HEADERS")
		testaux.asserteq(result.err, "Channel goaway", "graceful shutdown reason")
		testaux.asserteq(s:waitresponse(2000), true, "accepted response remains readable")
		testaux.asserteq(s:readall(2000), "", "accepted response completes normally")
	end)
end)

for index, typ in ipairs({0, 3, 1}) do
	local name = ({[0] = "DATA", [3] = "RST_STREAM", [1] = "HEADERS"})[typ]
	testaux.case("Test 96." .. index .. ": " .. name .. " on an unknown idle stream is a connection error", function()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local data = typ == 3 and string.pack(">I4", 0) or typ == 1 and hpack.pack(hpack.new(4096), {}, ":status", "200") or "invalid"
			assert(conn:write(frame(typ, typ == 1 and 5 or 0, request.id + 2, data)))
			local goaway = peer.untilframe(conn, 7)
			testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1, "unknown idle stream is connection PROTOCOL_ERROR")
		end, function(ch)
			local s<close> = get(assert(ch))
			testaux.asserteq(s:waitresponse(2000), false, "idle frame fails connection")
			testaux.asserteq(ch:isalive(), false, "idle frame aborts channel")
		end)
	end)
end

for index, typ in ipairs({0, 3}) do
	local name = typ == 0 and "DATA" or "RST_STREAM"
	testaux.case("Test 97." .. index .. ": Late " .. name .. " on a removed stream leaves other responses usable", function()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local first = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), first.id, "200")))
			local second = peer.untilframe(conn, 1)
			assert(conn:write(frame(typ, 0, first.id, typ == 0 and "late" or string.pack(">I4", 0))))
			if typ == 0 then
				local reset = peer.untilframe(conn, 3)
				testaux.asserteq(reset.id, first.id, "only removed DATA stream is reset")
				testaux.asserteq(string.unpack(">I4", reset.data), 5, "late DATA is STREAM_CLOSED")
			else
				assert(conn:write(frame(6, 0, 0, "late-rst")))
				local ack = peer.untilframe(conn, 6)
				testaux.asserteq(ack.data, "late-rst", "late reset ignored before PING barrier")
			end
			assert(conn:write(peer.headers(hpack.new(4096), second.id, "200")))
		end, function(ch)
			local first = get(assert(ch))
			assert(first:waitresponse(2000))
			first:close()
			local second<close> = get(ch)
			testaux.asserteq(second:waitresponse(2000), true, "another response survives late frame")
		end)
	end)
end

testaux.case("Test 98: Malformed response status and headers reset only their stream", function()
	for _, fields in ipairs({
		{":status", "200", "", "value"},
		{":status", "200", "Connection", "close"},
		{":status", "200", "connection", "close"},
		{":status", "200", "te", "gzip"},
		{"x-only", "missing"},
		{":status", "101"},
		{":status", "20"},
		{":status", "200" .. string.rep("0", 4093)},
		{":status", "099"},
		{":status", "200", ":method", "GET"},
		{":status", "200", ":status", "200"},
		{":status", "200", "x-normal", "value", ":status", "200"},
	}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(frame(1, 5, request.id, hpack.pack(hpack.new(4096), {}, table.unpack(fields)))))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "malformed response is stream PROTOCOL_ERROR")
			answer(conn, "ok")
		end, function(ch)
			local first = get(assert(ch))
			testaux.asserteq(first:waitresponse(2000), false, "malformed response rejected")
			first:close()
			local second<close> = get(ch)
			testaux.asserteq(second:readall(2000), "ok", "malformed response does not abort connection")
		end)
	end
end)

testaux.case("Test 99: Server request trailers require END_STREAM", function()
	local rejected = channel.new()
	peer.withserver(function(s)
		if s.path == "/bad" then
			local body, err = s:readall(2000)
			rejected:push({body = body, err = err})
		else
			assert(s:respond(200, {}))
			assert(s:closewrite("ok"))
		end
	end, function(conn)
		peer.clienthandshake(conn)
		local enc = hpack.new(4096)
		assert(conn:write(frame(1, 4, 1, hpack.pack(enc, {}, ":method", "POST", ":scheme", "http", ":path", "/bad")) .. frame(1, 4, 1, hpack.pack(enc, {["x-trailer"] = "value"}))))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 1, "unterminated request trailer is stream PROTOCOL_ERROR")
		local result = testaux.await(rejected, "handler sees rejected trailer")
		testaux.asserteq(result.body, nil, "malformed request body rejected")
		testaux.asserteq(result.err, "Protocol error detected", "trailer error reaches handler")
		assert(conn:write(frame(1, 5, 3, hpack.pack(enc, {}, ":method", "GET", ":scheme", "http", ":path", "/good"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "next server request survives malformed trailer")
	end)
end)

testaux.case("Test 100: Server initial SETTINGS cannot be an ACK", function()
	peer.withserver(function()
		error("invalid preface reached handler")
	end, function(conn)
		assert(conn:write(peer.preface .. frame(4, 1, 0)))
		peer.untilframe(conn, 4)
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1, "initial SETTINGS ACK is connection PROTOCOL_ERROR")
		testaux.asserteq(peer.read(conn), nil, "invalid handshake releases server transport")
	end)
end)
testaux.case("Test 101: Peer send stream limit does not restrict incoming server streams", function()
	peer.withserver(function(s)
		testaux.asserteq(s.channel.streammax, 0, "peer forbids server-initiated streams")
		s:respond(200, {})
		s:closewrite("ok")
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 0))))
		local ack
		repeat
			ack = peer.untilframe(conn, 4)
			if ack.flags & 1 == 0 then
				assert(conn:write(frame(4, 1, 0)))
			end
		until ack.flags & 1 ~= 0
		local request = hpack.pack(hpack.new(4096), nil,
			":method", "GET", ":scheme", "http", ":path", "/", ":authority", "example.test")
		assert(conn:write(frame(1, 5, 1, request)))
		peer.untilframe(conn, 1)
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "incoming request remains accepted")
	end)
end)


testaux.case("Test 103: Indexed response fields cannot bypass decoded header list overhead", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		-- Only 1201 wire octets, but 42 + 1200 * 60 decoded field-list octets.
		assert(conn:write(frame(1, 5, request.id, "\x88" .. string.rep("\x90", 1200))))
		local goaway = peer.untilframe(conn, 7)
		local _, code = string.unpack(">I4I4", goaway.data)
		testaux.asserteq(code, 0x0b, "decoded resource limit is not a frame/compression error")
	end, function(ch)
		local s<close> = get(assert(ch))
		local body, err = s:readall(2000)
		testaux.asserteq(body, nil, "indexed amplification is rejected")
		testaux.assertneq(err, nil, "rejected response wakes its reader with an error")
	end)
end)

testaux.case("Test 104: Indexed response fields obey exact decoded header list boundary", function()
	for _, value in ipairs({"", "v"}) do
		-- 42 + 1091 * 60 + (1 + #value + 32) = 65535 + #value.
		local wire = "\x88" .. string.rep("\x90", 1091) .. "\x00\x01x"
			.. string.char(#value) .. value
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(frame(1, 5, request.id, wire)))
			if value ~= "" then
				local goaway = peer.untilframe(conn, 7)
				local _, code = string.unpack(">I4I4", goaway.data)
				testaux.asserteq(code, 0x0b, "one excess decoded byte triggers the resource limit")
			else
				while peer.read(conn) do
				end
			end
		end, function(ch)
			local s<close> = get(assert(ch))
			local body, err = s:readall(2000)
			if value == "" then
				testaux.asserteq(body, "", "an exact 65535-byte decoded list is accepted")
				testaux.asserteq(err, nil, "exact capacity succeeds")
				testaux.asserteq(s.header.x, "", "last boundary field is preserved")
			else
				testaux.asserteq(body, nil, "a 65536-byte decoded list is rejected")
				testaux.assertneq(err, nil, "over-limit response wakes its reader")
			end
		end)
	end
end)

testaux.case("Test 105: Accepted streams keep read deadlines after graceful GOAWAY", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 0))))
		while peer.read(conn) do
		end
	end, function(ch)
		local s<close> = get(assert(ch))
		local response, cause = s:waitresponse(80)
		testaux.asserteq(response, false, "accepted response reader still reaches its deadline")
		testaux.assertneq(cause, nil, "deadline wakes the accepted stream")
		testaux.asserteq(ch.goaway, true, "peer GOAWAY was processed before read timeout")
		testaux.asserteq(ch.conn ~= nil, true, "accepted stream keeps the connection until cleanup")
	end)
end)

testaux.case("Test 106: Completing one stream preserves another stream's read deadline", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 2))
		local first = peer.untilframe(conn, 1)
		peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200", {}, 4)
			.. frame(0, 1, first.id, "ok")))
		while peer.read(conn) do
		end
	end, function(ch)
		local first<close> = get(assert(ch))
		local second<close> = get(ch)
		local donefirst, donesecond = channel.new(), channel.new()
		task.fork(function()
			local ok, body, cause = pcall(first.readall, first, 2000)
			donefirst:push({ok = ok, body = body, cause = cause})
		end)
		task.fork(function()
			local ok, body, cause = pcall(second.readall, second, 80)
			donesecond:push({ok = ok, body = body, cause = cause})
		end)
		local result = testaux.await(donefirst, "first response completed")
		testaux.asserteq(result.ok, true, "first reader completed normally")
		testaux.asserteq(result.body, "ok", "first body arrives before its deadline")
		result = testaux.await(donesecond, "second response reached its own deadline")
		testaux.asserteq(result.ok, true, "second reader returns its timeout normally")
		testaux.asserteq(result.body, nil, "second reader times out without a response")
		testaux.assertneq(result.cause, nil, "second deadline is not cancelled by the first response")
		testaux.asserteq(ch:isalive(), true, "individual read deadlines leave the connection usable")
		testaux.asserteq(first.readco, nil, "completed reader is detached")
		testaux.asserteq(second.readco, nil, "timed-out reader is detached")
		ch:close()
	end)
end)


testaux.case("Test 107: Timed stream reads keep independent timers and cancel them after responses", function()
	local count = 32
	local ready, release, done = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local requests = {}
		for i = 1, count do
			requests[i] = peer.untilframe(conn, 1)
		end
		ready:push(true)
		testaux.await(release, "all read deadlines registered")
		local encoder, responses = hpack.new(4096), {}
		for i, request in ipairs(requests) do
			responses[i] = peer.headers(encoder, request.id, "200")
		end
		assert(conn:write(responses))
		while peer.read(conn) do
		end
	end, function(ch)
		local streams = {}
		local function timers()
			local n = 0
			for _, value in pairs(time._dump().timer_user_data) do
				if streams[value] then
					n = n + 1
				end
			end
			return n
		end
		for _ = 1, count do
			local s = get(ch)
			streams[s] = true
			task.fork(function()
				local stream<close> = s
				local ok, body, cause = pcall(stream.readall, stream, 2000)
				done:push({ok = ok, body = body, cause = cause})
			end)
		end
		testaux.await(ready, "peer received every pending request")
		testaux.asserteq(timers(), count, "each timed reader owns an independent timer")
		release:push(true)
		for _ = 1, count do
			local result = testaux.await(done, "reader completed")
			testaux.asserteq(result.ok, true, "reader returns normally")
			testaux.asserteq(result.body, "", "all responses complete before their deadlines")
		end
		ch:close()
		testaux.asserteq(timers(), 0, "completed readers cancel all their timers")
	end)
end)


testaux.case("Test 108: Public headeronly records whether the final response headers end the stream", function()
	for _, finish in ipairs({"HEADERS", "fragmented HEADERS", "DATA", "empty DATA", "trailers"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local encoder = hpack.new(4096)
			local info = peer.headers(encoder, request.id, "103", {}, 4)
			local response
			if finish == "fragmented HEADERS" then
				local wire = hpack.pack(encoder, {["x-fragment"] = "value"}, ":status", "200")
				response = frame(1, 1, request.id, wire:sub(1, 1))
					.. frame(9, 4, request.id, wire:sub(2))
			else
				response = peer.headers(encoder, request.id, "200", {}, finish == "HEADERS" and 5 or 4)
			end
			if finish == "DATA" then
				response = response .. frame(0, 1, request.id, "ok")
			elseif finish == "empty DATA" then
				response = response .. frame(0, 1, request.id)
			elseif finish == "trailers" then
				response = response .. frame(1, 5, request.id,
					hpack.pack(encoder, {["x-tail"] = "end"}))
			end
			assert(conn:write(info .. response))
			while peer.read(conn) do
			end
		end, function(ch)
			local s = get(ch)
			testaux.asserteq(s.headeronly, nil, "response shape is unknown before final headers")
			assert(s:waitresponse(2000))
			local headeronly = finish == "HEADERS" or finish == "fragmented HEADERS"
			testaux.asserteq(s.headeronly, headeronly, "1xx and CONTINUATION do not determine response shape")
			testaux.asserteq(s:readall(2000), finish == "DATA" and "ok" or "", "response completes normally")
			testaux.asserteq(s.headeronly, headeronly, "EOF preserves the initial header flag")
			s:close()
			ch:close()
		end)
	end
end)


testaux.case("Test 111: PING ACK shares the next flush without splitting buffered header blocks", function()
	local fork = task.fork
	local settled, ready = channel.new(), channel.new()
	local ok, err = pcall(function()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			assert(conn:write(frame(6, 0, 0, "settled!")))
			peer.untilframe(conn, 6)
			settled:push(true)
			testaux.await(ready, "request buffered")
			assert(conn:write(frame(6, 0, 0, "batchack")))
			local request = assert(peer.read(conn))
			testaux.asserteq(request.type, 1, "buffered request HEADERS remain first")
			while request.flags & 4 == 0 do
				request = assert(peer.read(conn))
				testaux.asserteq(request.type, 9, "CONTINUATION remains contiguous")
			end
			local data = assert(peer.read(conn))
			testaux.asserteq({data.type, data.data}, {0, "ok"}, "DATA remains after the request headers")
			local trailer = assert(peer.read(conn))
			testaux.asserteq({trailer.type, trailer.flags}, {1, 5}, "trailers remain after DATA")
			local ack = assert(peer.read(conn))
			testaux.asserteq({ack.type, ack.flags, ack.data}, {6, 1, "batchack"},
				"ACK follows the ready-to-send request in the same flush")
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		end, function(ch, _, observer)
			ch = assert(ch)
			testaux.await(settled, "handshake writes drained")
			local queued
			task.fork = function(fn, arg, ...)
				if arg == ch then
					queued = {fn, arg}
					return task.running()
				end
				return fork(fn, arg, ...)
			end
			local s<close> = assert(ch:openstream())
			assert(s:request("POST", "/", {["x-large"] = string.rep("abcdef0123456789", 2500)}))
			assert(s:write("ok"))
			assert(s:closewrite(nil, {["x-trailer"] = "done"}))
			ready:push(true)
			observer:waituntil(function()
				return #ch.sendbuf == 4
			end, "PING ACK appended to the buffered request")
			testaux.asserteq(ch.sendbuf[4]:sub(4, 5), "\x06\x01", "ACK uses the ordinary queue tail")
			task.fork = fork
			fork(queued[1], queued[2])
			testaux.asserteq(s:waitresponse(2000), true, "request remains valid when ACK shares the batch")
		end)
	end)
	task.fork = fork
	if not ok then
		error(err, 0)
	end
end)


testaux.case("Test 112: Window overflow uses the correct stream or connection error", function()
	for _, source in ipairs({"settings", "stream", "connection"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local id = source == "connection" and 0 or request.id
			assert(conn:write(frame(8, 0, id, string.pack(">I4", 0x7fffffff - 65535))
				.. frame(6, 0, 0, "max-wind")))
			peer.untilframe(conn, 6)
			local overflow = source == "settings"
				and frame(4, 0, 0, string.pack(">I2I4", 4, 65536))
				or frame(8, 0, id, string.pack(">I4", 1))
			assert(conn:write(overflow))
			local failure = assert(peer.read(conn))
			testaux.asserteq(failure.type, source == "stream" and 3 or 7,
				source .. " overflow uses the correct error scope")
			local code = string.unpack(">I4", failure.data, source == "stream" and 1 or 5)
			testaux.asserteq(code, 3, "FLOW_CONTROL_ERROR")
			if source == "stream" then
				answer(conn, "ok")
			else
				testaux.asserteq(peer.read(conn), nil, "connection overflow closes the transport")
			end
		end, function(ch)
			local s<close> = assert(assert(ch):openstream())
			assert(s:request("POST", "/", {}))
			s:flush()
			local ok, err = s:waitresponse(2000)
			testaux.asserteq(ok, false, "flow error wakes the response waiter")
			testaux.assertneq(err, nil, "overflow supplies an error")
			if source == "stream" then
				s:close()
				local nextstream<close> = get(ch)
				testaux.asserteq(nextstream:readall(2000), "ok", "stream overflow preserves the connection")
			end
		end)
	end
end)

testaux.case("Test 113: Stream credit cannot duplicate a connection-blocked writer", function()
	local updated, resume, finished = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local total = 0
		while total < 65535 do
			total = total + #peer.untilframe(conn, 0).data
		end
		testaux.asserteq(total, 65535, "sender stops exactly at the connection window")
		local updates = {}
		for _ = 1, 32 do
			updates[#updates + 1] = frame(8, 0, request.id, string.pack(">I4", 1))
		end
		updates[#updates + 1] = frame(4, 0, 0, string.pack(">I2I4", 4, 0))
		updates[#updates + 1] = frame(4, 0, 0, string.pack(">I2I4", 4, 65535))
		updates[#updates + 1] = frame(6, 0, 0, "queue-ok")
		assert(conn:write(updates))
		peer.untilframe(conn, 6)
		updated:push(true)
		testaux.await(resume, "inspect writer queue before restoring connection credit")
		assert(conn:write(frame(8, 0, 0, string.pack(">I4", 1))))
		local last = peer.untilframe(conn, 0)
		testaux.asserteq(last.data, "x", "one connection byte resumes exactly one body byte")
		local trailer = peer.untilframe(conn, 1)
		testaux.asserteq({trailer.id, trailer.flags}, {request.id, 5},
			"trailers bypass exhausted DATA credit")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		ch = assert(ch)
		local s<close> = assert(ch:openstream())
		assert(s:request("POST", "/", {}))
		task.fork(function()
			local ok, err = s:write(string.rep("x", 65536))
			finished:push({ok = ok, err = err})
		end)
		testaux.await(updated, "stream updates and SETTINGS were applied")
		testaux.asserteq(ch.sendwindow, 0, "stream credit cannot replenish the connection")
		testaux.asserteq(s.sendwindow, 32, "SETTINGS changes preserve accumulated stream credit")
		testaux.asserteq(ch.writewaitq:size(), 1, "one blocked writer occupies one queue entry")
		resume:push(true)
		local result = testaux.await(finished, "connection credit resumes the writer")
		testaux.asserteq(result.ok, true, result.err or "body write completes")
		testaux.asserteq(ch.sendwindow, 0, "last body byte consumes the granted connection credit")
		testaux.asserteq(s.sendwindow, 31, "last body byte consumes stream credit once")
		assert(s:closewrite(nil, {["x-finished"] = "yes"}))
		testaux.asserteq(s:waitresponse(2000), true, "stream completes after queue recovery")
	end)
end)

testaux.case("Test 114: Peer reset terminates both directions of a blocked writer", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(3, 0, request.id, string.pack(">I4", 8))))
		answer(conn, "ok")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		local ok, err = s:write("blocked")
		testaux.asserteq(ok, false, "peer reset wakes the blocked body writer")
		testaux.asserteq(err, "Stream cancelled", "writer receives the peer reset reason")
		local ended = s:closewrite(nil, {["x-forbidden"] = "after-reset"})
		testaux.asserteq(ended, false, "reset stream cannot emit trailers after the writer wakes")
		testaux.asserteq(s:write("again"), false, "reset stream cannot start another DATA write")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "reset does not close other streams")
	end)
end)

testaux.case("Test 115: Reset writers leave no stale connection waiters", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local total = 0
		while total < 65535 do
			total = total + #peer.untilframe(conn, 0).data
		end
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200")))
		for _ = 1, 8 do
			local request = peer.untilframe(conn, 1)
			assert(conn:write(frame(3, 0, request.id, string.pack(">I4", 8))))
		end
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		local first<close> = assert(ch:openstream())
		assert(first:request("POST", "/", {}))
		assert(first:closewrite(string.rep("x", 65535)))
		assert(first:waitresponse(2000))
		first:close()
		testaux.asserteq(ch.sendwindow, 0, "connection credit stays exhausted throughout cancellation")
		for _ = 1, 8 do
			local s<close> = assert(ch:openstream())
			assert(s:request("POST", "/", {}))
			local ok, err = s:write("blocked")
			testaux.asserteq(ok, false, "reset wakes each connection-blocked writer")
			testaux.asserteq(err, "Stream cancelled", "reset reason is preserved")
		end
		testaux.asserteq(ch.writewaitq:size(), 0, "cancelled writers are removed without connection credit")
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "headers still bypass the exhausted window")
	end)
end)

testaux.case("Test 116: Reset response writers cannot flush new or buffered headers", function()
	for _, mode in ipairs({"blocked", "buffered"}) do
		local ready, release, finished = channel.new(), channel.new(), channel.new()
		peer.withserver(function(s)
			assert(s:respond(200, {}))
			local ok, err
			if mode == "blocked" then
				ok, err = s:write("blocked")
			else
				ready:push(true)
				testaux.await(release, "reset processed before flushing buffered headers")
			end
			local response = s:respond(200, {["x-forbidden"] = "after-reset"})
			s:flush()
			finished:push({ok = ok, err = err, response = response})
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
			peer.untilframe(conn, 4)
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
				":method", "GET", ":scheme", "http", ":path", "/", ":authority", "example.test"))))
			if mode == "blocked" then
				peer.untilframe(conn, 1)
			else
				testaux.await(ready, "response headers remain buffered")
			end
			assert(conn:write(frame(3, 0, 1, string.pack(">I4", 8))
				.. frame(6, 0, 0, "rst-seen")))
			peer.untilframe(conn, 6)
			if mode == "buffered" then
				release:push(true)
			end
			local result = testaux.await(finished, "reset response writer returned")
			if mode == "blocked" then
				testaux.asserteq(result.ok, false, "reset cancels server DATA write")
				testaux.asserteq(result.err, "Stream cancelled", "server writer gets the reset reason")
			end
			testaux.asserteq(result.response, false, "reset rejects subsequent response headers")
			assert(conn:write(frame(6, 0, 0, "rst-flsh")))
			local nextframe = assert(peer.read(conn))
			testaux.asserteq({nextframe.type, nextframe.flags, nextframe.data}, {6, 1, "rst-flsh"},
				"flush emits no frames on a reset response stream")
		end)
	end
end)


testaux.case("Test 117: Cancelling a middle waiter preserves shared connection credit", function()
	local resume, done = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local total = 0
		while total < 65535 do
			total = total + #peer.untilframe(conn, 0).data
		end
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200")))
		local ids = {}
		for i = 1, 3 do
			ids[i] = peer.untilframe(conn, 1).id
		end
		assert(conn:write(frame(3, 0, ids[2], string.pack(">I4", 8))))
		testaux.await(resume, "middle waiter removed before granting connection credit")
		assert(conn:write(frame(8, 0, 0, string.pack(">I4", 9))))
		local left, right = peer.untilframe(conn, 0), peer.untilframe(conn, 0)
		testaux.asserteq({left.id, left.data, right.id, right.data},
			{ids[1], "left", ids[3], "right"}, "only live writers consume the shared credit in FIFO order")
		testaux.asserteq({left.flags & 1, right.flags & 1}, {1, 1}, "each resumed body ends once")
		local encoder = hpack.new(4096)
		assert(conn:write(peer.headers(encoder, ids[1], "200") .. peer.headers(encoder, ids[3], "200")))
	end, function(ch)
		ch = assert(ch)
		local first<close> = assert(ch:openstream())
		assert(first:request("POST", "/", {}))
		assert(first:closewrite(string.rep("x", 65535)))
		assert(first:waitresponse(2000))
		first:close()
		local streams = {}
		for i, body in ipairs({"left", "cancel", "right"}) do
			local s = assert(ch:openstream())
			streams[i] = s
			assert(s:request("POST", "/", {}))
			task.fork(function()
				local ok, err = s:closewrite(body)
				done:push({index = i, ok = ok, err = err})
			end)
		end
		local cancelled = testaux.await(done, "middle writer wakes on reset")
		testaux.asserteq({cancelled.index, cancelled.ok}, {2, false}, "only the reset writer fails")
		testaux.asserteq(ch.writewaitq:size(), 2, "both live waiters remain after middle removal")
		resume:push(true)
		for _ = 1, 2 do
			local result = testaux.await(done, "live writer consumes restored connection credit")
			testaux.asserteq(result.ok, true, result.err or "live body completes")
		end
		testaux.asserteq(ch.sendwindow, 0, "two streams consume exactly the nine granted bytes")
		testaux.asserteq(ch.writewaitq:size(), 0, "successful writers leave no waiters")
		for i, s in ipairs(streams) do
			if i ~= 2 then
				assert(s:waitresponse(2000))
			end
			s:close()
		end
	end)
end)

testaux.case("Test 118: Invalid field bytes are rejected before application delivery", function()
	local fields = {
		{"bad name", "ok"}, {"x:y", "ok"}, {"bad\0name", "ok"}, {"bad\127", "ok"},
		{"bad\255", "ok"}, {"x-bad", "a\0b"}, {"x-bad", "a\r\nb"},
		{"x-bad", " leading"}, {"x-bad", "trailing\t"},
		{"content-length", " 0"}, {"content-length", "0 "},
	}
	for _, field in ipairs(fields) do
		peer.withserver(function(s)
			assert(s:respond(200, {}))
			assert(s:closewrite("ok"))
		end, function(conn)
			peer.clienthandshake(conn)
			local encoder = hpack.new(4096)
			assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, nil,
				":method", "GET", ":scheme", "http", ":path", "/", field[1], field[2]))))
			local response
			repeat
				response = assert(peer.read(conn))
			until response.type ~= 4 and response.type ~= 8
			testaux.asserteq(response.type, 3, "malformed request fields receive RST_STREAM")
			testaux.asserteq(string.unpack(">I4", response.data), 1, "stream PROTOCOL_ERROR")
			assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, nil,
				":method", "GET", ":scheme", "http", ":path", "/", "x-valid", "a\tb\255"))))
			testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "HPACK stays synchronized after rejection")
		end)
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {[field[1]] = field[2]})))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "invalid response field is rejected")
			answer(conn, "ok")
		end, function(ch)
			local s<close> = get(assert(ch))
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "malformed response cannot reach the client")
			testaux.assertneq(err, nil, "malformed response supplies an error")
			s:close()
			local nextstream<close> = get(ch)
			testaux.asserteq(nextstream:readall(2000), "ok", "connection survives invalid response fields")
		end)
	end
end)

testaux.case("Test 119: Malformed RST_STREAM length is checked after stream removal", function()
	local closed = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = answer(conn, "ok")
		testaux.await(closed, "completed stream removed")
		assert(conn:write(frame(3, 0, request.id, "") .. frame(6, 0, 0, "bad-size")))
		local reply
		repeat
			reply = assert(peer.read(conn))
		until reply.type ~= 4 and reply.type ~= 8
		testaux.asserteq(reply.type, 7, "invalid RST size terminates the connection")
		testaux.asserteq(string.unpack(">I4", reply.data, 5), 6, "connection FRAME_SIZE_ERROR")
	end, function(ch, _, observer)
		local s = get(assert(ch))
		testaux.asserteq(s:readall(2000), "ok", "initial response completed")
		s:close()
		closed:push(true)
		observer:waitclosed()
	end)
end)

testaux.case("Test 120: Closed stream windows cannot invalidate later SETTINGS", function()
	local raised, cancelled = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 0x7fffffff - 65535))
			.. frame(6, 0, 0, "max-dead")))
		peer.untilframe(conn, 6)
		raised:push(true)
		peer.untilframe(conn, 3)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 65536))
			.. frame(8, 0, request.id, string.pack(">I4", 1)) .. frame(6, 0, 0, "dead-win")))
		local reply = assert(peer.read(conn))
		testaux.asserteq(reply.type, 4, "valid SETTINGS is acknowledged despite retained closed records")
		peer.untilframe(conn, 6)
		cancelled:push(true)
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		local s = assert(ch:openstream())
		assert(s:request("POST", "/", {}))
		s:flush()
		testaux.await(raised, "live window was raised to its maximum")
		s:close()
		testaux.await(cancelled, "SETTINGS and late WINDOW_UPDATE processed")
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "closed window does not abort another stream")
	end)
end)

testaux.case("Test 121: Reset after a DATA wakeup prevents trailing HEADERS", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 1))
			.. frame(3, 0, request.id, string.pack(">I4", 8)) .. frame(6, 0, 0, "rst-last")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.asserteq(incoming.type == 1 and incoming.id == request.id, false,
				"reset stream emits no trailing HEADERS")
			if incoming.type == 6 then
				break
			end
		end
		answer(conn, "ok")
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		local ok, err = s:closewrite("x", {["x-trailer"] = "forbidden"})
		testaux.asserteq(ok, false, "a reset received before resumption cancels closewrite")
		testaux.asserteq(err, "Stream cancelled", "the reset reason is preserved")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "reset remains isolated to its stream")
	end)
end)

testaux.case("Test 122: Openers recheck concurrency after waking", function()
	local started, changed, release, done = channel.new(), channel.new(), channel.new(), channel.new()
	local returned = false
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(started, "opener is waiting for a stream slot")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4I2I4", 3, 1, 3, 0))
			.. frame(6, 0, 0, "max-zero")))
		peer.untilframe(conn, 6)
		changed:push(true)
		testaux.await(release, "lowered limit keeps opener blocked")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		task.fork(function()
			local s = assert(ch:openstream())
			assert(s:request("GET", "/", {}))
			started:push(true)
			local ok, err = s:closewrite()
			assert(ok, err)
			returned = true
			done:push({stream = s, err = err})
		end)
		testaux.await(changed, "both values in SETTINGS are applied")
		testaux.asserteq(returned, false, "a stale notification cannot bypass maximum zero")
		release:push(true)
		local result = testaux.await(done, "opener resumes under the restored limit")
		local s<close> = assert(result.stream, result.err)
		testaux.asserteq(s:readall(2000), "ok", "opener eventually uses exactly one valid slot")
	end)
end)

testaux.case("Test 123: Allocated unsent streams reject peer frames", function()
	for _, typ in ipairs({1, 3, 8}) do
		local allocated = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local id = testaux.await(allocated, "stream allocated without request headers")
			local data = typ == 1 and "\x88" or string.pack(">I4", 1)
			assert(conn:write(frame(typ, 5, id, data) .. frame(6, 0, 0, "idle-obj")))
			local reply
			repeat
				reply = assert(peer.read(conn))
			until reply.type ~= 4 and reply.type ~= 8
			testaux.asserteq(reply.type, 7, "wire-idle stream causes connection error")
			testaux.asserteq(string.unpack(">I4", reply.data, 5), 1, "connection PROTOCOL_ERROR")
		end, function(ch, _, observer)
			local s<close> = assert(assert(ch):openstream())
			allocated:push(1)
			observer:waitclosed()
		end)
	end
end)

testaux.case("Test 124: Unused even stream IDs remain idle after higher odd streams", function()
	for _, typ in ipairs({0, 1, 3, 8}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local first = answer(conn, "one")
			local second = answer(conn, "two")
			testaux.asserteq({first.id, second.id}, {1, 3}, "two client streams were opened")
			local data = typ == 1 and "\x88" or typ == 0 and "" or string.pack(">I4", 1)
			assert(conn:write(frame(typ, 5, 2, data) .. frame(6, 0, 0, "even-two")))
			local reply
			repeat
				reply = assert(peer.read(conn))
			until reply.type ~= 4 and reply.type ~= 8
			testaux.asserteq(reply.type, 7, "unused even stream remains idle")
			testaux.asserteq(string.unpack(">I4", reply.data, 5), 1, "connection PROTOCOL_ERROR")
		end, function(ch, _, observer)
			ch = assert(ch)
			local first = get(ch)
			testaux.asserteq(first:readall(2000), "one", "first response")
			first:close()
			local second<close> = get(ch)
			testaux.asserteq(second:readall(2000), "two", "second response")
			observer:waitclosed()
		end)
	end
end)

testaux.case("Test 125: Responses without content reject nonempty DATA", function()
	for _, response in ipairs({{"HEAD", "200"}, {"GET", "204"}, {"GET", "304"}}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local headers = response[2] == "204" and {} or {["content-length"] = "100"}
			assert(conn:write(peer.headers(hpack.new(4096), request.id, response[2], headers, 4)
				.. frame(0, 1, request.id, "bad")))
			peer.untilframe(conn, 3)
			answer(conn, "ok")
		end, function(ch)
			local s<close> = assert(assert(ch):openstream())
			assert(s:request(response[1], "/", {}))
			assert(s:closewrite())
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "nonempty DATA is invalid for " .. response[1] .. " " .. response[2])
			testaux.assertneq(err, nil, "invalid body has an error")
			s:close()
			local nextstream<close> = get(ch)
			testaux.asserteq(nextstream:readall(2000), "ok", "invalid body does not poison the channel")
		end)
	end
end)

testaux.case("Test 126: Peer GOAWAY refuses a stream allocated but not opened", function()
	local allocated = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		testaux.await(allocated, "stream remains idle on the wire")
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0x7fffffff, 0))))
		while true do
			local incoming = peer.read(conn)
			if not incoming then
				break
			end
			testaux.asserteq(incoming.type == 1 or incoming.type == 0, false,
				"unused objects send no request after GOAWAY")
		end
	end, function(ch, _, observer)
		local s<close> = assert(assert(ch):openstream())
		allocated:push(true)
		observer:waitclosed()
		assert(s:request("GET", "/", {}))
		local ok, err = s:closewrite()
		testaux.asserteq(ok, false, "unsent stream cannot open after peer GOAWAY")
		testaux.asserteq(err, "Channel goaway", "first send reports the channel shutdown")
	end)
end)

testaux.case("Test 127: Reduced limits make allocated unsent streams wait", function()
	local allocated, updated = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		testaux.await(allocated, "request is allocated but unsent")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 0))
			.. frame(6, 0, 0, "no-open!")))
		peer.untilframe(conn, 6)
		updated:push(true)
		while true do
			local incoming = peer.read(conn)
			if not incoming then
				break
			end
			testaux.asserteq(incoming.type == 1, false, "request does not open beyond the lowered limit")
		end
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		allocated:push(true)
		testaux.await(updated, "new maximum is applied")
		assert(s:request("GET", "/", {}))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = s:closewrite()
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "first send waits under the lowered maximum")
		testaux.asserteq(ch.openwaitq:size(), 1, "idle request waits instead of exceeding the limit")
		s:close()
		local result = testaux.await(done, "close removes the idle request")
		testaux.asserteq(result.ok, false, "cancelled request cannot open")
		testaux.asserteq(result.err, "Local closed", "cancelled request reports close")
		ch:close()
	end)
end)

testaux.case("Test 128: Split Cookie fields use semicolon joining", function()
	peer.withserver(function(s)
		testaux.asserteq(s.header.cookie, "a=b; c=d", "Cookie fragments are joined in wire order")
		testaux.asserteq(s.header["set-cookie"], {"left", "right"}, "other repeated fields stay separate")
		assert(s:respond(200, {}))
		assert(s:closewrite("ok"))
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), nil,
			":method", "GET", ":scheme", "http", ":path", "/",
			"cookie", "a=b", "cookie", "c=d", "set-cookie", "left", "set-cookie", "right"))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "split Cookie request remains valid")
	end)
end)

testaux.case("Test 129: Mandatory request pseudo-header values cannot be empty", function()
	for _, fields in ipairs({
		{":method", "", ":scheme", "http", ":path", "/"},
		{":method", "GET", ":scheme", "", ":path", "/"},
		{":method", "CONNECT", ":authority", ""},
		{":method", "GET POST", ":scheme", "http", ":path", "/"},
		{":method", "GET", ":scheme", "1http", ":path", "/"},
	}) do
		peer.withserver(function(s)
			assert(s:respond(200, {}))
			assert(s:closewrite("bad"))
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), nil, table.unpack(fields)))))
			local response
			repeat
				response = assert(peer.read(conn))
			until response.type ~= 4 and response.type ~= 8
			testaux.asserteq(response.type, 3, "empty mandatory pseudo-header is rejected")
			testaux.asserteq(string.unpack(">I4", response.data), 1, "stream PROTOCOL_ERROR")
		end)
	end
end)

testaux.case("Test 130: TE is forbidden in response headers", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {te = "trailers"})))
		peer.untilframe(conn, 3)
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "TE exception applies only to requests")
		testaux.assertneq(err, nil, "invalid response supplies an error")
	end)
end)

testaux.case("Test 131: A successful CONNECT tunnel rejects trailing HEADERS", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		s:flush()
		local body, err = s:readall(2000)
		testaux.asserteq(body, nil, "CONNECT tunnel cannot terminate with trailers")
		testaux.assertneq(err, nil, "invalid tunnel frame reports an error")
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 4, 1, hpack.pack(encoder, nil,
			":method", "CONNECT", ":authority", "target.example:443"))))
		peer.untilframe(conn, 1)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, nil, "x-trailer", "forbidden"))))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 1, "tunnel HEADERS cause PROTOCOL_ERROR")
	end)
end)

testaux.case("Test 132: NO_ERROR after DATA wakeup suppresses trailers", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 1))
			.. peer.headers(hpack.new(4096), request.id, "200")
			.. frame(3, 0, request.id, string.pack(">I4", 0)) .. frame(6, 0, 0, "stop-end")))
		while true do
			local incoming = assert(peer.read(conn))
			testaux.asserteq(incoming.type == 1 and incoming.id == request.id, false,
				"request stopped by NO_ERROR emits no trailers")
			if incoming.type == 6 then
				break
			end
		end
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("POST", "/", {}))
		local ok, err = s:closewrite("x", {["x-trailer"] = "forbidden"})
		testaux.asserteq(ok, false, "NO_ERROR can stop request after DATA waiter was detached")
		testaux.asserteq(err, "Request stopped by peer", "request stop has a distinct reason")
		testaux.asserteq(s:readall(2000), "", "the complete response is preserved")
	end)
end)

testaux.case("Test 133: A locally refused unsent stream remains idle on the wire", function()
	local allocated = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local id = testaux.await(allocated, "stream allocated before the reduced limit")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 0))
			.. frame(8, 0, id, string.pack(">I4", 1)) .. frame(6, 0, 0, "rst-idle")))
		local incoming
		repeat
			incoming = assert(peer.read(conn))
		until incoming.type ~= 4 and incoming.type ~= 8
		testaux.asserteq(incoming.type, 7, "local refusal does not open a protocol stream")
		testaux.asserteq(string.unpack(">I4", incoming.data, 5), 1, "connection PROTOCOL_ERROR")
	end, function(ch, _, observer)
		local s<close> = assert(assert(ch):openstream())
		allocated:push(1)
		observer:waitclosed()
	end)
end)

testaux.case("Test 134: CONNECT requests use authority form without scheme or path", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local fields = {}
		assert(hpack.unpack(hpack.new(4096), request.data, fields))
		testaux.asserteq(fields, {":authority", "target.example:443", ":method", "CONNECT"},
			"classic CONNECT has only its two required pseudo-headers")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. frame(0, 1, request.id, "tunnel")))
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("CONNECT", "target.example:443", {}))
		assert(s:closewrite())
		testaux.asserteq(s:readall(2000), "tunnel", "CONNECT response carries tunnel bytes")
	end)
end)

testaux.case("Test 135: CONNECT 204 remains a successful DATA tunnel", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "204", {}, 4)
			.. frame(0, 1, request.id, "tunnel")))
	end, function(ch)
		local s<close> = assert(assert(ch):openstream())
		assert(s:request("CONNECT", "target.example:443", {}))
		assert(s:closewrite())
		testaux.asserteq(s:readall(2000), "tunnel", "all 2xx CONNECT responses establish a tunnel")
	end)
end)

testaux.case("Test 136: Early GOAWAY drains requests before SETTINGS ACK", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		s:flush()
		local body, err = s:readall(2000)
		testaux.asserteq(body, "body", err or "accepted request receives its remaining DATA")
		assert(s:closewrite(body))
	end, function(conn)
		local request = hpack.pack(hpack.new(4096), nil,
			":method", "POST", ":scheme", "http", ":path", "/")
		assert(conn:write(peer.preface .. frame(4, 0, 0, "") .. frame(1, 4, 1, request)))
		peer.untilframe(conn, 1)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, 0))
			.. frame(4, 1, 0, "") .. frame(0, 1, 1, "body")))
		testaux.asserteq(peer.untilframe(conn, 0).data, "body", "response drains after early GOAWAY")
	end)
end)

testaux.case("Test 220: Go decodes Lua HPACK recovery after an unsent partial block", function()
	for _, mode in ipairs({"fresh", "populated", "shrink"}) do
		local encoder = hpack.new(4096)
		local blocks = {}
		if mode == "populated" then
			blocks[1] = base64.encode(hpack.pack(encoder, nil, "x-before", "old"))
		elseif mode == "shrink" then
			hpack.hardlimit(encoder, 0)
			hpack.hardlimit(encoder, 64)
		end
		local bad = setmetatable({}, {__tostring = function()
			error("intentional late HPACK conversion failure")
		end})
		local ok = pcall(hpack.pack, encoder, {["x-poison"] = {"good", bad}})
		testaux.asserteq(ok, false, "one literal was encoded before conversion failed")
		blocks[#blocks + 1] = base64.encode(hpack.pack(encoder, nil, "x-poison", "good"))
		local decoded, err = c:hpackdecode(blocks, 4096)
		assert(decoded, err)
		testaux.asserteq(decoded[#decoded], {{Name = "x-poison", Value = "good", Sensitive = false}},
			"independent Go decoder recovers the exact header: " .. mode)
	end
end)

testaux.case("Test 137: Closed streams preserve connection credit and HPACK state", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(3, 0, first.id, string.pack(">I4", 8))
			.. peer.headers(encoder, first.id, "200", {["x-reset"] = "retained"})
			.. frame(0, 1, first.id, "discard")))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, request.id, "200", {["x-reset"] = "retained"}, 4)
			.. frame(0, 1, request.id, "ok")))
		local credit = 0
		while credit < 9 do
			local update = peer.untilframe(conn, 8)
			if update.id == 0 then
				credit = credit + string.unpack(">I4", update.data)
			end
		end
		testaux.asserteq(credit, 9, "discarded and delivered DATA both consume connection credit")
	end, function(ch)
		ch = assert(ch)
		local first<close> = get(ch)
		local body, err = first:readall(2000)
		testaux.asserteq(body, nil, "reset stream does not deliver later DATA")
		testaux.asserteq(err, "Stream cancelled", "the original reset reason is preserved")
		local second<close> = get(ch)
		testaux.asserteq(second:readall(2000), "ok", "another stream remains usable")
		testaux.asserteq(second.header["x-reset"], "retained", "closed HEADERS update shared HPACK state")
	end)
end)


testaux.case("Test 138: Only transmitted requests consume the remaining stream IDs", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local encoder = hpack.new(4096)
		for _, id in ipairs({0x7ffffffd, 0x7fffffff}) do
			local request = peer.untilframe(conn, 1)
			testaux.asserteq(request.id, id, "only sent requests consume the remaining IDs")
			assert(conn:write(peer.headers(encoder, id, "200")))
		end
	end, function(ch)
		ch = assert(ch)
		ch.streamidx = 0x7ffffffb
		local first<close> = assert(ch:openstream())
		local second<close> = assert(ch:openstream())
		local extra<close> = assert(ch:openstream())
		testaux.asserteq(ch.streamcount, 0, "unsent objects reserve neither slots nor IDs")
		first:close()
		local replacement<close> = assert(ch:openstream())
		for _, stream in ipairs({second, replacement}) do
			assert(stream:request("GET", "/", {}))
			assert(stream:closewrite())
			testaux.asserteq(stream:readall(2000), "", "sent request uses a valid final ID")
		end
		assert(extra:request("GET", "/", {}))
		local ok, err = extra:closewrite()
		testaux.asserteq(ok, false, "an existing unsent object cannot exceed the final ID")
		testaux.asserteq(err, "Stream id exhausted", "first send reports ID exhaustion")
		local nextstream, cause = ch:openstream()
		testaux.asserteq(nextstream, nil, "no new object after ID exhaustion")
		testaux.asserteq(cause, err, "allocation reports the same exhausted channel")
		testaux.asserteq(ch:isalive(), false, "ID-exhausted channel cannot accept another request")
	end)
end)

testaux.case("Test 139: Unsent streams use the latest initial send window", function()
	local allocated, changed = channel.new(), channel.new()
	local body = string.rep("w", 65536)
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		testaux.await(allocated, "stream object exists before SETTINGS changes")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 65536))
			.. frame(8, 0, 0, string.pack(">I4", 1)) .. frame(6, 0, 0, "new-wind")))
		peer.untilframe(conn, 6)
		changed:push(true)
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.id, 1, "first actual request gets the first ID")
		local parts, total, last = {}, 0, nil
		while total < #body do
			last = peer.untilframe(conn, 0)
			testaux.asserteq(last.id, request.id, "DATA uses the assigned stream ID")
			parts[#parts + 1] = last.data
			total = total + #last.data
		end
		testaux.asserteq(table.concat(parts), body, "new initial window is fully available")
		testaux.asserteq(last.flags & 1, 1, "final DATA ends the request without another window grant")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		local stream<close> = assert(assert(ch):openstream())
		allocated:push(true)
		testaux.await(changed, "SETTINGS was acknowledged before request transmission")
		assert(stream:request("POST", "/", {}))
		assert(stream:closewrite(body))
		testaux.asserteq(stream:readall(2000), "", "response succeeds after deferred window initialization")
	end)
end)


testaux.case("Test 140: ID exhaustion releases every queued opener", function()
	local started, admitted, done, drained = channel.new(), channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(admitted, "all initial HEADERS writers are queued")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.id, 0x7fffffff, "last request uses the final valid ID")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		testaux.await(drained, "all openers observed ID exhaustion")
	end, function(ch)
		ch = assert(ch)
		ch.streamidx = 0x7ffffffd
		for _ = 1, 4 do
			task.fork(function()
				local stream = assert(ch:openstream())
				assert(stream:request("GET", "/", {}))
				started:push(true)
				local ok, err = stream:closewrite()
				done:push({stream = stream, ok = ok, err = err})
			end)
		end
		for _ = 1, 4 do
			testaux.await(started, "initial HEADERS writer registered")
		end
		testaux.asserteq(ch.openwaitq:size(), 4, "all writers wait without consuming IDs")
		admitted:push(true)
		local sent = 0
		for _ = 1, 4 do
			local result = testaux.await(done, "final ID or exhaustion returned", 2000)
			local stream<close> = result.stream
			if result.ok then
				sent = sent + 1
				testaux.asserteq(stream:readall(2000), "", "final request completes")
			else
				testaux.asserteq(result.err, "Stream id exhausted", "remaining openers fail promptly")
			end
		end
		testaux.asserteq(sent, 1, "exactly one request consumes the final ID")
		testaux.asserteq(ch.streamcount, 0, "only the sent request occupied a slot")
		testaux.asserteq(ch.openwaitq:size(), 0, "no opener remains blocked without future streams")
		drained:push(true)
	end)
end)

testaux.case("Test 141: A queued write error survives a later connection abort", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(3, 0, request.id, string.pack(">I4", 8))
			.. frame(7, 0, 0, string.pack(">I4I4", request.id, 2))))
		testaux.asserteq(peer.read(conn), nil, "error GOAWAY closes the connection")
	end, function(ch)
		local stream<close> = assert(assert(ch):openstream())
		assert(stream:request("POST", "/", {}))
		local ok, err = stream:closewrite("blocked")
		testaux.asserteq(ok, false, "reset fails the blocked writer")
		testaux.asserteq(err, "Stream cancelled", "the queued stream error is preserved")
		testaux.asserteq(ch.errstr, "Implementation fault", "connection retains its own later error")
		testaux.asserteq(ch.conn, nil, "the later abort still releases the transport")
	end)
end)

testaux.case("Test 142: Unsent stream objects do not consume concurrency slots", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		local request = answer(conn, "ok")
		testaux.asserteq(request.id, 1, "first transmitted headers receive the first ID")
	end, function(ch)
		ch = assert(ch)
		local streams = {}
		for i = 1, 3 do
			streams[i] = assert(ch:openstream())
			testaux.asserteq(ch.streamcount, 0, "creating an object does not reserve a stream slot")
		end
		local s = streams[3]
		assert(s:request("GET", "/", {}))
		assert(s:closewrite())
		testaux.asserteq(ch.streamcount, 1, "sending initial headers occupies the slot")
		streams[1]:close()
		streams[2]:close()
		testaux.asserteq(ch.streamcount, 1, "closing unused objects does not release a sent stream's slot")
		testaux.asserteq(s:readall(2000), "ok", "the sent stream completes")
		s:close()
		testaux.asserteq(ch.streamcount, 0, "closing the sent stream releases its slot")
	end)
end)

testaux.case("Test 143: Close cancels unsent readers and queued header writers", function()
	for _, method in ipairs({"write", "closewrite", "flush", "waitresponse", "read", "readall"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
			peer.untilframe(conn, 7)
			testaux.asserteq(peer.read(conn), nil, "cancelled opener sends no HEADERS or DATA")
		end, function(ch)
			ch = assert(ch)
			local s = assert(ch:openstream())
			assert(s:request("POST", "/", {}))
			local started, done = channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local ok, err
				if method == "write" or method == "closewrite" then
					ok, err = s[method](s, "not-sent")
				elseif method == "read" then
					ok, err = s:read(1)
				else
					ok, err = s[method](s)
				end
				done:push({ok = ok, err = err})
			end)
			testaux.await(started, "initial header writer is waiting")
			testaux.asserteq(ch.openwaitq:size(), 1, "one stream is queued")
			if method == "read" or method == "readall" or method == "waitresponse" then
				testaux.assertneq(s.readco, nil, "an unsent reader owns readco")
				testaux.asserteq(s.writeco, nil, "an unsent reader does not occupy writeco")
			else
				testaux.assertneq(s.writeco, nil, "write-side admission owns writeco")
			end
			s:close()
			local result = testaux.await(done, "close releases the initial header writer")
			if method == "read" or method == "readall" then
				testaux.asserteq(result.ok, nil, method .. " fails after close")
			else
				testaux.asserteq(result.ok, false, method .. " fails after close")
			end
			testaux.asserteq(result.err, "Local closed", "close reason is preserved")
			testaux.asserteq(s.writeco, nil, "close detaches the writer before waking it")
			testaux.asserteq(ch.openwaitq:size(), 0, "close removes the exact queued stream")
			testaux.asserteq(ch.streamcount, 0, "cancelled opener never consumed a slot")
			ch:close()
		end)
	end
end)

testaux.case("Test 144: Close after an opener is notified cannot send its headers", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 1)
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(goaway.type, 7, "channel closes without the cancelled request")
		testaux.asserteq(peer.read(conn), nil, "notified cancelled opener sends no frames")
	end, function(ch)
		ch = assert(ch)
		local first = get(ch)
		local s = assert(ch:openstream())
		assert(s:request("POST", "/", {}))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = s:closewrite("not-sent", {["x-tail"] = "not-sent"})
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "second stream is queued")
		first:close()
		s:close()
		ch:close()
		local result = testaux.await(done, "notified opener returns after close")
		testaux.asserteq(result.ok, false, "notified opener rechecks its stream state")
		testaux.asserteq(result.err, "Local closed", "late close wins before transmission")
		testaux.asserteq(ch.streamcount, 0, "notifications do not leave reserved slots")
		testaux.asserteq(ch.conn, nil, "notified opener does not pin the connection")
	end)
end)

testaux.case("Test 145: A deadline can close a stream whose reader waits before flush", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		peer.untilframe(conn, 7)
	end, function(ch)
		ch = assert(ch)
		local s = assert(ch:openstream())
		assert(s:request("GET", "/", {}))
		local timer = time.after(0, function()
			s:close()
		end)
		local ok, err = s:waitresponse(2000)
		time.cancel(timer)
		testaux.asserteq(ok, false, "deadline interrupts the initial HEADERS wait")
		testaux.asserteq(err, "Local closed", "read does not register a waiter after close")
		testaux.asserteq(s.readco, nil, "no read waiter is left behind")
		testaux.asserteq(ch.openwaitq:size(), 0, "deadline removes the queued opener")
		ch:close()
	end)
end)

testaux.case("Test 146: Closing an unsent stream releases both its reader and header writer", function()
	for _, mode in ipairs({"local", "channel", "notified"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
			peer.untilframe(conn, 1)
			while true do
				local incoming = peer.read(conn)
				if not incoming then
					break
				end
				testaux.asserteq(incoming.type == 1 or incoming.type == 0, false,
					"cancelled request sends neither HEADERS nor DATA")
			end
		end, function(ch)
			ch = assert(ch)
			local first = get(ch)
			local stream = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			local started, writes, reads = channel.new(), channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local ok, err = stream:closewrite("not-sent")
				writes:push({ok = ok, err = err})
			end)
			testaux.await(started, "header writer entered admission")
			task.fork(function()
				started:push(true)
				local ok, err = stream:waitresponse(2000)
				reads:push({ok = ok, err = err})
			end)
			testaux.await(started, "reader registered during admission")
			testaux.assertneq(stream.readco, nil, "reader is waiting alongside the header writer")
			if mode == "local" then
				stream:close()
			elseif mode == "notified" then
				first:close()
			end
			ch:close()
			first:close()
			local write = testaux.await(writes, "header writer returned after close")
			local read = testaux.await(reads, "reader returned after close")
			local expected = mode == "local" and "Local closed"
				or mode == "notified" and "Channel goaway" or "channel closed"
			testaux.asserteq(write.ok, false, "initial HEADERS fail after close")
			testaux.asserteq(write.err, expected, "header writer receives the close reason")
			testaux.asserteq(read.ok, false, "reader fails after close")
			testaux.asserteq(read.err, expected, "reader receives the same close reason")
			testaux.asserteq(stream.readco, nil, "close detaches the reader")
			testaux.asserteq(stream.writeco, nil, "close detaches the header writer")
			testaux.asserteq(ch.openwaitq:size(), 0, "close leaves no queued opener")
			testaux.asserteq(ch.streamcount, 0, "cancelled stream does not consume a slot")
			testaux.asserteq(ch.conn, nil, "both waiters release the closed channel")
			stream:close()
		end)
	end
end)

testaux.case("Test 147: Cancelling a middle opener preserves order and subsequent DATA waits", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4I2I4", 3, 1, 4, 0))
		peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		for _, index in ipairs({1, 3}) do
			local request = peer.untilframe(conn, 1)
			testaux.asserteq(request.id, index == 1 and 3 or 5, "queued requests retain their send order")
			assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 5))))
			testaux.asserteq(peer.untilframe(conn, 0).data, "body" .. index,
				"admitted writer resumes under stream flow control")
			local trailer = peer.untilframe(conn, 1)
			testaux.asserteq({trailer.id, trailer.flags}, {request.id, 5},
				"trailers follow the resumed body")
			assert(conn:write(peer.headers(encoder, request.id, "200")))
		end
	end, function(ch)
		ch = assert(ch)
		local first = get(ch)
		local streams = {}
		local started, done = channel.new(), channel.new()
		for index = 1, 3 do
			local stream = assert(ch:openstream())
			streams[index] = stream
			assert(stream:request("POST", "/", {}))
			task.fork(function()
				started:push(true)
				local ok, err = stream:closewrite("body" .. index, {["x-tail"] = "done"})
				done:push({stream = stream, ok = ok, err = err})
			end)
		end
		for _ = 1, 3 do
			testaux.await(started, "initial HEADERS writer queued")
		end
		testaux.asserteq(ch.openwaitq:size(), 3, "three pending streams are queued")
		streams[2]:close()
		testaux.asserteq(ch.openwaitq:size(), 2, "only the cancelled middle entry is removed")
		first:close()
		local completed = 0
		for _ = 1, 3 do
			local result = testaux.await(done, "cancelled or completed writer returned")
			if result.stream == streams[2] then
				testaux.asserteq(result.ok, false, "middle writer is cancelled")
				testaux.asserteq(result.err, "Local closed", "cancelled writer retains its reason")
			else
				testaux.asserteq(result.ok, true, result.err or "admitted writer completes")
				testaux.asserteq(result.stream:readall(2000), "", "admitted request completes")
				completed = completed + 1
				result.stream:close()
			end
		end
		testaux.asserteq(completed, 2, "both surviving requests complete")
		testaux.asserteq(ch.streamcount, 0, "all sent stream slots are released")
		testaux.asserteq(ch.openwaitq:size(), 0, "opener queue is empty")
		testaux.asserteq(ch.writewaitq:size(), 0, "DATA waits leave no stale queue entries")
	end)
end)

testaux.case("Test 148: A reader waiting for a response can coexist with a queued header writer", function()
	local grant = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(grant, "reader is waiting and header writer has entered admission")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local encoder = hpack.new(4096)
		local body = ""
		while true do
			local incoming = peer.read(conn)
			if not incoming then
				break
			end
			if incoming.type == 1 then
				assert(conn:write(peer.headers(encoder, incoming.id, "200")))
			elseif incoming.type == 0 then
				body = body .. incoming.data
			end
		end
		testaux.asserteq(body, "body", "one writer sends its request body")
	end, function(ch)
		ch = assert(ch)
		local stream = assert(ch:openstream())
		assert(stream:request("POST", "/", {}))
		local started, reads, writes = channel.new(), channel.new(), channel.new()
		local read_done, write_done = false, false
		task.fork(function()
			started:push(true)
			local ok, err = stream:waitresponse(2000)
			read_done = true
			reads:push({ok = ok, err = err})
		end)
		testaux.await(started, "reader waits for initial HEADERS")
		task.fork(function()
			started:push(true)
			local called, ok, err = pcall(stream.closewrite, stream, "body")
			write_done = true
			writes:push({called = called, ok = ok, err = err})
		end)
		testaux.await(started, "writer joins the unsent stream")
		testaux.asserteq(stream.id, 0, "the stream stays unsent until headers can be sent")
		testaux.asserteq(ch.streamcount, 0, "waiting callers do not open a stream")
		testaux.assertneq(stream.readco, nil, "read is waiting for a response")
		testaux.assertneq(stream.writeco, nil, "write is blocked in initial admission")
		testaux.asserteq(read_done, false, "read has not returned before admission")
		testaux.asserteq(write_done, false, "write has not returned before admission")
		grant:push(true)
		local write = testaux.await(writes, "writer completed")
		local read = testaux.await(reads, "reader completed")
		stream:close()
		ch:close()
		testaux.asserteq(write.called, true, tostring(write.ok))
		testaux.asserteq(write.ok, true, write.err or "writer waits for admission independently")
		testaux.asserteq(read.ok, true, read.err or "reader receives its response")
	end)
end)

testaux.case("Test 149: A writer opens a stream while its reader is waiting", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		local headerid, bodyid
		while true do
			local incoming, err = peer.read(conn)
			if not incoming then
				testaux.asserteq(err and err:find("PROTOCOL_ERROR", 1, true), nil,
					"Go Framer must not reject request DATA: " .. tostring(err))
				break
			end
			if incoming.type == 1 then
				headerid = incoming.id
				assert(conn:write(peer.headers(encoder, incoming.id, "200")))
			elseif incoming.type == 0 then
				bodyid = incoming.id
				testaux.asserteq(headerid, bodyid, "request HEADERS precede DATA on the same assigned stream")
			end
		end
		testaux.asserteq(headerid, 3, "second request consumes the next stream ID once")
		testaux.asserteq(bodyid, 3, "body uses the assigned stream ID")
	end, function(ch)
		ch = assert(ch)
		local first = get(ch)
		local stream = assert(ch:openstream())
		assert(stream:request("POST", "/", {}))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = stream:waitresponse(2000)
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "reader queued behind the first request")
		first:close()
		local called, ok, err = pcall(stream.closewrite, stream, "body")
		local read = testaux.await(done, "waiting reader resumes")
		stream:close()
		ch:close()
		testaux.asserteq(called, true, tostring(ok))
		testaux.asserteq(ok, true, err or "one writer can send while a reader is waiting")
		testaux.asserteq(read.ok, true, read.err or "reader observes the same admitted request")
		testaux.asserteq(ch.streamcount, 0, "the request occupies only one slot")
	end)
end)

testaux.case("Test 150: Invalid END_STREAM headers cannot wake a successful response waiter", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {["content-length"] = "1"})))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 1, "incomplete response uses PROTOCOL_ERROR")
		peer.untilframe(conn, 7)
	end, function(ch)
		ch = assert(ch)
		local stream = get(ch)
		local ok, err = stream:waitresponse(2000)
		stream:close()
		ch:close()
		testaux.asserteq(ok, false, "a response invalidated by the same HEADERS frame is not successful")
		testaux.asserteq(err, "Protocol error detected", "waiter receives the validation failure")
	end)
end)

testaux.case("Test 151: One reader and one flow-control writer are both cancelled exactly once", function()
	for _, cause in ipairs({"local", "reset", "goaway", "eof"}) do
		local release = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
			local request = peer.untilframe(conn, 1)
			testaux.await(release, "both directions are waiting before cancellation")
			if cause == "reset" then
				assert(conn:write(frame(3, 0, request.id, string.pack(">I4", 8))))
			elseif cause == "goaway" then
				assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 2))))
			elseif cause == "eof" then
				return
			end
			while peer.read(conn) do
			end
		end, function(ch)
			ch = assert(ch)
			local stream = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			local started, reads, writes = channel.new(), channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local ok, err = stream:closewrite("blocked", {["x-tail"] = "not-sent"})
				writes:push({ok = ok, err = err})
			end)
			testaux.await(started, "writer is waiting for stream credit")
			task.fork(function()
				started:push(true)
				local data, err = stream:readall(2000)
				reads:push({data = data, err = err})
			end)
			testaux.await(started, "reader is waiting for a response")
			testaux.assertneq(stream.readco, nil, "one reader is registered")
			testaux.assertneq(stream.writeco, nil, "one writer is registered")
			testaux.assertneq(stream.readco, stream.writeco, "reader and writer use distinct coroutine slots")
			release:push(true)
			if cause == "local" then
				stream:close()
			end
			local write = testaux.await(writes, "cancelled writer returns once")
			local read = testaux.await(reads, "cancelled reader returns once")
			testaux.asserteq(write.ok, false, "writer fails after cancellation")
			testaux.asserteq(read.data, nil, "reader fails after cancellation")
			testaux.assertneq(write.err, nil, "writer receives a cancellation reason")
			testaux.asserteq(read.err, write.err, "both directions receive the same reason")
			testaux.asserteq(stream.readco, nil, "reader ownership was detached")
			testaux.asserteq(stream.writeco, nil, "writer ownership was detached")
			stream:close()
			ch:close()
			testaux.asserteq(ch.streamcount, 0, "close releases exactly one stream slot")
			testaux.asserteq(ch.openwaitq:size(), 0, "no stale opener remains")
			testaux.asserteq(ch.writewaitq:size(), 0, "no stale DATA waiter remains")
		end)
	end
end)

testaux.case("Test 152: A read deadline before flush leaves request headers retryable", function()
	local grant = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(grant, "read deadline expired without closing the stream")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.id, 1, "timed-out reads consume no stream IDs")
		testaux.asserteq(peer.untilframe(conn, 0).data, "retry", "pending headers survive read timeout")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		ch = assert(ch)
		local stream<close> = assert(ch:openstream())
		assert(stream:request("POST", "/", {}))
		local ok, err = stream:waitresponse(10)
		testaux.asserteq(ok, false, "read deadline interrupts a response wait before flush")
		testaux.assertneq(err and err:find("timed out", 1, true), nil, "read reports timeout")
		testaux.asserteq(stream.readco, nil, "expired reader is detached")
		testaux.asserteq(stream.writeco, nil, "reader never owns writeco")
		testaux.asserteq(ch.openwaitq:size(), 0, "reader-only registration is removed after timeout")
		testaux.asserteq(stream.id, 0, "read timeout leaves an unsent stream")
		grant:push(true)
		assert(stream:closewrite("retry"))
		testaux.asserteq(stream:readall(2000), "", "writer can retry after the read timed out")
	end)
end)

testaux.case("Test 153: An unsent reader and header writer share one entry and close wakes both", function()
	for _, cause in ipairs({"local", "channel", "notified", "eof"}) do
		local release = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 3, cause == "notified" and 1 or 0))
			if cause == "notified" then
				peer.untilframe(conn, 1)
			elseif cause == "eof" then
				testaux.await(release, "reader is waiting and writer entered admission")
				return
			end
			while true do
				local incoming = peer.read(conn)
				if not incoming then
					break
				end
				testaux.asserteq(incoming.type == 0 or incoming.type == 1, false,
					"cancelled admission sends no request frames")
			end
		end, function(ch)
			ch = assert(ch)
			local first
			if cause == "notified" then
				first = get(ch)
			end
			local stream = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			local started, reads, writes = channel.new(), channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local ok, err = stream:waitresponse(2000)
				reads:push({ok = ok, err = err})
			end)
			testaux.await(started, "reader waits before flush")
			task.fork(function()
				started:push(true)
				local called, ok, err = pcall(stream.closewrite, stream, "not-sent")
				writes:push({called = called, ok = ok, err = err})
			end)
			testaux.await(started, "writer joins admission")
			testaux.asserteq(ch.openwaitq:size(), 1, "both directions share one queue entry")
			testaux.assertneq(stream.readco, nil, "reader owns readco")
			testaux.assertneq(stream.writeco, nil, "writer owns writeco")
			testaux.assertneq(stream.readco, stream.writeco, "waiter ownership is independent")
			if first then
				first:close()
			end
			if cause == "local" or cause == "notified" then
				stream:close()
			elseif cause == "channel" then
				ch:close()
			else
				release:push(true)
			end
			local write = testaux.await(writes, "writer observes close exactly once")
			local read = testaux.await(reads, "reader observes close exactly once")
			testaux.asserteq(write.called, true, tostring(write.ok))
			testaux.asserteq(write.ok, false, "closed writer fails")
			testaux.asserteq(read.ok, false, "closed reader fails")
			testaux.asserteq(read.err, write.err, "both directions receive the same close reason")
			stream:close()
			ch:close()
			testaux.asserteq(stream.readco, nil, "reader ownership is cleared")
			testaux.asserteq(stream.writeco, nil, "writer ownership is cleared")
			testaux.asserteq(ch.openwaitq:size(), 0, "no duplicate or stale queue entry remains")
			testaux.asserteq(ch.streamcount, 0, "no unsent stream consumes a slot")
			testaux.asserteq(ch.conn, nil, "closed waiters do not retain the transport")
		end)
	end
end)

testaux.case("Test 154: An admitted writer can close while its reader is waiting", function()
	local grant = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(grant, "reader is waiting and writer entered admission")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		peer.untilframe(conn, 1)
		peer.untilframe(conn, 3)
		peer.untilframe(conn, 7)
	end, function(ch)
		ch = assert(ch)
		local stream = assert(ch:openstream())
		assert(stream:request("GET", "/", {}))
		local started, reads, writes = channel.new(), channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = stream:waitresponse(2000)
			reads:push({ok = ok, err = err})
		end)
		testaux.await(started, "reader is waiting for a response")
		task.fork(function()
			started:push(true)
			local ok, err = stream:closewrite()
			stream:close()
			writes:push({ok = ok, err = err})
		end)
		testaux.await(started, "writer entered admission")
		grant:push(true)
		local write = testaux.await(writes, "writer sent HEADERS and closed")
		local read = testaux.await(reads, "waiting reader observes the intervening close")
		testaux.asserteq(write.ok, true, write.err or "initial request was sent")
		testaux.asserteq(read.ok, false, "reader cannot register again after close")
		testaux.asserteq(read.err, "Stream cancelled", "reader receives the sent stream's reset reason")
		testaux.asserteq(stream.readco, nil, "no reader remains after close")
		testaux.asserteq(ch.streamcount, 0, "reader does not leak or debit the admitted stream's slot")
		ch:close()
		testaux.asserteq(ch.conn, nil, "intervening close releases the transport")
	end)
end)

testaux.case("Test 155: An admitted stream cannot retain an entry in the opening queue", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		while peer.read(conn) do
		end
	end, function(ch)
		ch = assert(ch)
		local first = get(ch)
		local middle = assert(ch:openstream())
		assert(middle:request("GET", "/middle", {}))
		local started, writes, reads = channel.new(), channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = middle:closewrite()
			middle:close()
			writes:push({ok = ok, err = err})
		end)
		testaux.await(started, "middle writer queued first")
		local last = assert(ch:openstream())
		assert(last:request("POST", "/last", {}))
		task.fork(function()
			started:push(true)
			local ok, err = last:waitresponse(2000)
			reads:push({ok = ok, err = err})
		end)
		testaux.await(started, "last reader queued second")
		testaux.asserteq(ch.openwaitq:size(), 2, "one writer and one unsent reader are registered")
		first:close()
		-- The middle writer is ready, but has not consumed the free slot yet.
		local ok, err = last:closewrite("body")
		local queued = last.writequeued
		local id = last.id
		last:close()
		local write = testaux.await(writes, "middle writer returned")
		local read = testaux.await(reads, "last reader returned")
		ch:close()
		testaux.asserteq(ok, true, err or "last writer eventually sends")
		testaux.asserteq(queued, false, "a sent stream no longer belongs to the initial HEADERS queue")
		testaux.asserteq(write.ok, true, write.err or "previously notified writer gets its slot")
		testaux.asserteq(id, 3, "the notified writer has not reserved the free slot")
		testaux.asserteq(middle.id, 5, "the notified writer sends after another slot becomes free")
		testaux.asserteq(read.ok, false, "close reaches the admitted stream's reader")
		testaux.asserteq(ch.openwaitq:size(), 0, "no stale opening entry survives close")
		testaux.asserteq(ch.streamcount, 0, "all stream slots are released once")
		testaux.asserteq(ch.conn, nil, "stale opening entries do not pin the connection")
	end)
end)

testaux.case("Test 156: A read timeout before flush leaves its header writer queued and able to send", function()
	local grant = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(grant, "only the reader has timed out")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(peer.untilframe(conn, 0).data, "body", "writer survives the reader's timeout")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		ch = assert(ch)
		local stream<close> = assert(ch:openstream())
		assert(stream:request("POST", "/", {}))
		local started, reads, writes = channel.new(), channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = stream:waitresponse(10)
			reads:push({ok = ok, err = err})
		end)
		testaux.await(started, "reader is waiting for a response")
		task.fork(function()
			started:push(true)
			local called, ok, err = pcall(stream.closewrite, stream, "body")
			writes:push({called = called, ok = ok, err = err})
		end)
		testaux.await(started, "writer joined the admission queue")
		local read = testaux.await(reads, "read deadline expires independently of the writer")
		testaux.asserteq(read.ok, false, "reader reports timeout")
		testaux.assertneq(read.err and read.err:find("timed out", 1, true), nil, "reader has a timeout reason")
		testaux.asserteq(stream.readco, nil, "timed-out reader is detached")
		testaux.assertneq(stream.writeco, nil, "writer still owns writeco")
		testaux.asserteq(ch.openwaitq:size(), 1, "the shared queue entry remains for the writer")
		grant:push(true)
		local write = testaux.await(writes, "remaining writer resumes after the limit changes")
		testaux.asserteq(write.called, true, tostring(write.ok))
		testaux.asserteq(write.ok, true, write.err or "writer sends normally")
		testaux.asserteq(stream:readall(2000), "", "the reader can resume reading the sent stream")
		testaux.asserteq(ch.openwaitq:size(), 0, "completed admission removes the shared entry")
	end)
end)

testaux.case("Test 157: Reads wait without sending headers until an explicit flush", function()
	for _, method in ipairs({"waitresponse", "read", "readall"}) do
		local release = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
			testaux.await(release, "caller explicitly flushes the pending request")
			local request = peer.untilframe(conn, 1)
			testaux.asserteq(request.flags & 1, 0, "flush leaves the request write direction open")
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
				.. frame(0, 1, request.id, "done")))
			local last = peer.untilframe(conn, 0)
			testaux.asserteq({last.id, last.flags, last.data}, {request.id, 1, ""},
				"closewrite sends empty END_STREAM after the response has ended")
			peer.untilframe(conn, 7)
		end, function(ch)
			ch = assert(ch)
			local stream = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			local started, done = channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local value, err
				if method == "read" then
					value, err = stream:read(4, 2000)
				else
					value, err = stream[method](stream, 2000)
				end
				done:push({value = value, err = err})
			end)
			testaux.await(started, "reader registered before explicit flush")
			testaux.asserteq(stream.id, 0, "reading does not open the request")
			testaux.asserteq(ch.streamcount, 0, "reading does not reserve a stream slot")
			testaux.asserteq(stream.writeco, nil, "reader does not register an opening writer")
			testaux.assertneq(stream.readco, nil, "reader waits for a response")
			assert(stream:flush())
			release:push(true)
			local result = testaux.await(done, "peer response wakes the existing reader")
			testaux.asserteq(result.value, method == "waitresponse" and true or "done",
				"explicit flush enables the response read")
			if method == "waitresponse" then
				testaux.asserteq(stream:readall(2000), "done", "response body remains available")
			end
			testaux.asserteq(stream:eof(), true, "response ended before the request write direction")
			assert(stream:closewrite())
			stream:close()
			ch:close()
		end)
	end
end)

testaux.case("Test 158: Empty END_STREAM follows a completed response with exhausted send windows", function()
	for _, shrink in ipairs({false, true}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local total = 0
			while total < 65535 do
				local data = peer.untilframe(conn, 0)
				total = total + #data.data
				testaux.asserteq(data.flags & 1, 0, "request DATA leaves the write direction open")
			end
			local settings = shrink and frame(4, 0, 0, string.pack(">I2I4", 4, 0)) or ""
			assert(conn:write(settings .. peer.headers(hpack.new(4096), request.id, "200", {}, 4)
				.. frame(0, 1, request.id, "done")))
			local last = peer.untilframe(conn, 0)
			testaux.asserteq({last.id, last.flags, last.data}, {request.id, 1, ""},
				"empty END_STREAM does not wait for either send window")
			answer(conn, "ok")
		end, function(ch)
			ch = assert(ch)
			local stream<close> = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			assert(stream:write(string.rep("x", 65535)))
			testaux.asserteq(stream:readall(2000), "done", "response ends while the request remains open")
			testaux.asserteq(ch.sendwindow, 0, "connection send window is exhausted")
			testaux.asserteq(stream.sendwindow, shrink and -65535 or 0,
				"stream window is zero or negative after SETTINGS")
			assert(stream:closewrite())
			testaux.asserteq(stream:closewrite(), false, "write direction ends exactly once")
			stream:close()
			local nextstream<close> = get(ch)
			testaux.asserteq(nextstream:readall(2000), "ok", "another request survives the empty close")
		end)
	end
end)

testaux.case("Test 159: Reading a request body does not flush buffered response headers", function()
	local started, done = channel.new(), channel.new()
	peer.withserver(function(stream)
		assert(stream:respond(200, {["x-flush"] = "explicit"}))
		started:push(stream)
		local data, err = stream:read(1, 2000)
		done:push({data = data, err = err})
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 4, 1, hpack.pack(hpack.new(4096), {},
			":method", "POST", ":scheme", "http", ":path", "/"))))
		local stream = testaux.await(started, "handler reads after buffering its response")
		testaux.assertneq(stream.writeheader, nil, "read keeps response headers buffered")
		assert(stream:flush())
		local header = peer.untilframe(conn, 1)
		testaux.asserteq(header.flags & 1, 0, "explicit response flush leaves DATA open")
		assert(conn:write(frame(0, 1, 1, "x")))
		local result = testaux.await(done, "request body wakes the handler")
		testaux.asserteq(result.data, "x", "body read succeeds after explicit response flush")
		local last = peer.untilframe(conn, 0)
		testaux.asserteq({last.flags, last.data}, {1, ""}, "handler return closes with empty DATA")
	end)
end)

testaux.case("Test 160: Closing an unsent stream or channel wakes a read started before flush", function()
	for _, cause in ipairs({"local", "channel", "eof", "goaway"}) do
		local release = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			if cause == "eof" or cause == "goaway" then
				testaux.await(release, "reader is waiting without opening a stream")
				if cause == "eof" then
					return
				end
				assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, 0))))
			end
			while true do
				local incoming = peer.read(conn)
				if not incoming then
					break
				end
				testaux.asserteq(incoming.type == 1 or incoming.type == 0, false,
					"a read before flush sends no request frames")
			end
		end, function(ch)
			ch = assert(ch)
			local stream = assert(ch:openstream())
			assert(stream:request("POST", "/", {}))
			local started, done = channel.new(), channel.new()
			task.fork(function()
				started:push(true)
				local ok, err = stream:waitresponse(2000)
				done:push({ok = ok, err = err})
			end)
			testaux.await(started, "unsent response reader is registered")
			testaux.asserteq(stream.id, 0, "reader alone does not initiate HEADERS")
			if cause == "local" then
				stream:close()
			elseif cause == "channel" then
				ch:close()
			else
				release:push(true)
			end
			local result = testaux.await(done, "unsent reader observes close")
			testaux.asserteq(result.ok, false, "closed read fails")
			testaux.assertneq(result.err, nil, "close supplies a read error")
			testaux.asserteq(stream.readco, nil, "unsent read ownership is detached")
			testaux.asserteq(ch.openwaitq:size(), 0, "no unsent reader is retained after close")
			stream:close()
			ch:close()
		end)
	end
end)

end

httpc:close()
server:close()
c:close()
wait_readers()
