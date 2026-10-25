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
local errno = require "silly.errno"
local EEOF<const> = errno.EOF
local ECLOSED<const> = errno.CLOSED

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
	return assert(ch:request("GET", "/", {}, true))
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
					return ch.goaway ~= 0
				end, "peer GOAWAY processed")
			end
			local done = channel.new()
			task.fork(function()
				local stream, cause = ch:request("GET", "/", {})
				done:push({stream = stream, cause = cause})
			end)
			local result = testaux.await(done, "openstream rejects a closed full channel", 1000)
			testaux.asserteq(result.stream, nil, "closed full channel returns no stream")
			testaux.asserteq(result.cause, "Graceful shutdown",
				"Test 41: local close and peer GOAWAY report distinct reasons")
			release:push(true)
		end)
	end
end)

testaux.case("Test 42: A request admitted before local close keeps its stream", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 1)
		local second = peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		assert(conn:write(peer.headers(hpack.new(4096), second.id, "200")))
		testaux.asserteq(peer.read(conn), nil, "Test 42.1: admitted request drains before EOF")
	end, function(ch)
		local first = get(assert(ch))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local stream, err = ch:request("GET", "/", {}, true)
			done:push({stream = stream, err = err})
		end)
		testaux.await(started, "Test 42: request registered for admission")
		first:close()
		testaux.asserteq(ch.streamcount, 1, "Test 42.2: wakeup has already admitted the waiting request")
		ch:close()
		local result = testaux.await(done, "Test 42: admitted request is delivered")
		local stream<close> = assert(result.stream, result.err)
		testaux.asserteq(stream:readall(2000), "", "Test 42.3: local close preserves the admitted response")
		stream:close()
		testaux.asserteq(ch.conn, nil, "Test 42.4: final stream close releases the transport")
	end)
end)

testaux.case("Test 43: Requests receive IDs in send order and drain during graceful close", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local ids = {peer.untilframe(conn, 1).id, peer.untilframe(conn, 1).id}
		testaux.asserteq(ids, {1, 3}, "requests consume IDs only in transmission order")
		local encoder = hpack.new(4096)
		for _, id in ipairs(ids) do
			assert(conn:write(peer.headers(encoder, id, "200")))
		end
		peer.untilframe(conn, 7)
	end, function(ch)
		local first<close> = assert(assert(ch):request("GET", "/", {}))
		local second<close> = assert(ch:request("GET", "/", {}))
		for _, stream in ipairs({second, first}) do
			assert(stream:closewrite())
		end
		testaux.asserteq(second.id, 3, "second request receives the second ID")
		testaux.asserteq(first.id, 1, "first request receives the first ID")
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
			started:push(true)
			local stream, err = ch:request("GET", "/", {}, true)
			local ok = stream ~= nil
			if stream then
				stream:close()
			end
			done:push({ok = ok, cause = err})
		end)
		testaux.await(started, "initial HEADERS waiter started")
		closepeer:push(true)
		local result = testaux.await(done, "initial HEADERS writer wakes on EOF")
		testaux.asserteq(result.ok, false, "EOF prevents sending the queued request")
		testaux.assertneq(result.cause, nil, "writer returns connection error")
		testaux.asserteq(ch:isidle(), true, "EOF clears active streams and pending admission")
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
		local nextstream, cause = ch:request("GET", "/", {})
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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

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
			local badkey = setmetatable({}, {__tostring = function() error("response encoding failed") end})
			returned:push({stream = s, channel = s.channel})
			assert(s:respond(200, {[badkey] = "bad"}))
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
		testaux.asserteq(reply.flags & 1, 0, "Test 57.1: respond commits nonterminal HEADERS")
		local last = peer.untilframe(conn, 0)
		testaux.asserteq({last.flags, last.data}, {1, ""}, "Test 57.2: normal return sends terminal DATA")
		local fields = assert(hpack.unpack(hpack.new(4096), reply.data))
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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

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
			local headers = assert(hpack.unpack(hpack.new(4096), reply.data))
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
		local fields = assert(hpack.unpack(hpack.new(4096), response.data))
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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

		assert(s:flush())
		task.fork(function()
			started:push(true)
			local stream, err = ch:request("GET", "/", {}, true)
			local ok = stream ~= nil
			if stream then
				stream:close()
			end
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
			started:push(true)
			local stream, err = ch:request("GET", "/", {}, true)
			local ok = stream ~= nil
			if stream then
				stream:close()
			end
			done:push({ok = ok, err = err})
		end)
		testaux.await(started, "slot waiter entered")
		waiting:push(true)
		local result = testaux.await(done, "graceful GOAWAY wakes slot waiter")
		testaux.asserteq(result.ok, false, "graceful GOAWAY rejects queued HEADERS")
		testaux.asserteq(result.err, "Graceful shutdown", "graceful shutdown reason")
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
			assert(conn:write(frame(6, 0, 0, "late-old")))
			while true do
				local reply = assert(peer.read(conn))
				testaux.asserteq(reply.type == 3 or reply.type == 7, false,
					"Test 97.1: late closed-stream frames need no reset or GOAWAY")
				if reply.type == 6 then
					testaux.asserteq({reply.flags, reply.data}, {1, "late-old"},
						"Test 97.2: late frame is processed before the PING barrier")
					break
				end
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
	local started, rejected = channel.new(), channel.new()
	peer.withserver(function(s)
		if s.path == "/bad" then
			started:push(true)
			local body, err = s:readall(2000)
			rejected:push({body = body, err = err})
		else
			assert(s:respond(200, {}))
			assert(s:closewrite("ok"))
		end
	end, function(conn)
		peer.clienthandshake(conn)
		local enc = hpack.new(4096)
		assert(conn:write(frame(1, 4, 1,
			hpack.pack(enc, {}, ":method", "POST", ":scheme", "http", ":path", "/bad"))))
		testaux.await(started, "handler is reading before the malformed trailer")
		assert(conn:write(frame(1, 4, 1, hpack.pack(enc, {["x-trailer"] = "value"}))))
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
		testaux.asserteq(ch.goaway, 2, "peer GOAWAY was processed before read timeout")
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
			local s<close> = assert(ch:request("POST", "/", {["x-large"] = string.rep("abcdef0123456789", 2500)}))

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
			local s<close> = assert(assert(ch):request("POST", "/", {}))

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
		local s<close> = assert(ch:request("POST", "/", {}))

		task.fork(function()
			local ok, err = s:write(string.rep("x", 65536))
			finished:push({ok = ok, err = err})
		end)
		testaux.await(updated, "stream updates and SETTINGS were applied")
		testaux.asserteq(ch.sendwindow, 0, "stream credit cannot replenish the connection")
		testaux.asserteq(s.sendwindow, 32, "SETTINGS changes preserve accumulated stream credit")
		testaux.asserteq(ch.sendwaitq:size(), 1, "one blocked writer occupies one queue entry")
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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

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
		local first<close> = assert(ch:request("POST", "/", {}))

		assert(first:closewrite(string.rep("x", 65535)))
		assert(first:waitresponse(2000))
		first:close()
		testaux.asserteq(ch.sendwindow, 0, "connection credit stays exhausted throughout cancellation")
		for _ = 1, 8 do
			local s<close> = assert(ch:request("POST", "/", {}))

			local ok, err = s:write("blocked")
			testaux.asserteq(ok, false, "reset wakes each connection-blocked writer")
			testaux.asserteq(err, "Stream cancelled", "reset reason is preserved")
		end
		testaux.asserteq(ch.sendwaitq:size(), 0, "cancelled writers are removed without connection credit")
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
		local first<close> = assert(ch:request("POST", "/", {}))

		assert(first:closewrite(string.rep("x", 65535)))
		assert(first:waitresponse(2000))
		first:close()
		local streams = {}
		for i, body in ipairs({"left", "cancel", "right"}) do
			local s = assert(ch:request("POST", "/", {}))
			streams[i] = s

			task.fork(function()
				local ok, err = s:closewrite(body)
				done:push({index = i, ok = ok, err = err})
			end)
		end
		local cancelled = testaux.await(done, "middle writer wakes on reset")
		testaux.asserteq({cancelled.index, cancelled.ok}, {2, false}, "only the reset writer fails")
		testaux.asserteq(ch.sendwaitq:size(), 2, "both live waiters remain after middle removal")
		resume:push(true)
		for _ = 1, 2 do
			local result = testaux.await(done, "live writer consumes restored connection credit")
			testaux.asserteq(result.ok, true, result.err or "live body completes")
		end
		testaux.asserteq(ch.sendwindow, 0, "two streams consume exactly the nine granted bytes")
		testaux.asserteq(ch.sendwaitq:size(), 0, "successful writers leave no waiters")
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
		{"", "ok"}, {":", "ok"}, {"Upper", "ok"}, {"x::y", "ok"},
		{"bad name", "ok"}, {"x:y", "ok"}, {"bad\0name", "ok"}, {"bad\127", "ok"},
		{"bad\255", "ok"}, {"x-bad", "a\0b"}, {"x-bad", "a\r\nb"},
		{"x-bad", "\0"}, {"x-bad", "\r"}, {"x-bad", "\n"},
		{"x-bad", " "}, {"x-bad", "\t"}, {"x-bad", "a\rb"}, {"x-bad", "a\nb"},
		{"x-bad", " leading"}, {"x-bad", "\tleading"},
		{"x-bad", "trailing "}, {"x-bad", "trailing\t"},
		{"content-length", " 0"}, {"content-length", "0 "},
	}
	local valid_fields = {["x-empty"] = "", ["x-one"] = "a", ["x-high"] = "\255", ["x-valid"] = "a \tb\255"}
	local function check(header)
		for k, v in pairs(valid_fields) do
			testaux.asserteq(header[k], v, "Test 118: valid empty, single-byte and internal whitespace values")
		end
	end
	for _, field in ipairs(fields) do
		peer.withserver(function(s)
			check(s.header)
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
			assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, valid_fields,
				":method", "GET", ":scheme", "http", ":path", "/"))))
			testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "HPACK stays synchronized after rejection")
		end)
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {[field[1]] = field[2]})))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), 1, "invalid response field is rejected")
			local nextrequest = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), nextrequest.id, "200", valid_fields, 4)
				.. frame(0, 1, nextrequest.id, "ok")))
		end, function(ch)
			local s<close> = get(assert(ch))
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "malformed response cannot reach the client")
			testaux.assertneq(err, nil, "malformed response supplies an error")
			s:close()
			local nextstream<close> = get(ch)
			testaux.asserteq(nextstream:readall(2000), "ok", "connection survives invalid response fields")
			check(nextstream.header)
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
		testaux.asserteq(reply.type, 4, "Test 120.1: valid SETTINGS is acknowledged after stream removal")
		peer.untilframe(conn, 6)
		cancelled:push(true)
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		local s = assert(ch:request("POST", "/", {}))

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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

		local ok, err = s:closewrite("x", {["x-trailer"] = "forbidden"})
		testaux.asserteq(ok, false, "a reset received before resumption cancels closewrite")
		testaux.asserteq(err, "Stream cancelled", "the reset reason is preserved")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "reset remains isolated to its stream")
	end)
end)

testaux.case("Test 122: SETTINGS applies the final concurrency limit before admission", function()
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
			started:push(true)
			local s = assert(ch:request("GET", "/", {}))
			local ok, err = s:closewrite()
			assert(ok, err)
			returned = true
			done:push({stream = s, err = err})
		end)
		testaux.await(changed, "both values in SETTINGS are applied")
		testaux.asserteq(returned, false, "an intermediate SETTINGS value cannot admit a request")
		release:push(true)
		local result = testaux.await(done, "opener resumes under the restored limit")
		local s<close> = assert(result.stream, result.err)
		testaux.asserteq(s:readall(2000), "ok", "opener eventually uses exactly one valid slot")
	end)
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
			local s<close> = assert(assert(ch):request(response[1], "/", {}))

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

testaux.case("Test 128: Split Cookie fields use semicolon joining", function()
	for _, cookies in ipairs({{}, {"a=b"}, {"a=b", "c=d", "e=f"}, {"", "a=b", ""}}) do
		local expected = #cookies > 0 and table.concat(cookies, "; ") or nil
		local fields = {cookie = cookies, ["set-cookie"] = {"left", "right"}}
		local function check(header)
			testaux.asserteq(header.cookie, expected, "Test 128: Cookie fragments are joined in wire order")
			testaux.asserteq(header["set-cookie"], {"left", "right"}, "Test 128: other repeated fields stay separate")
		end
		peer.withserver(function(s)
			check(s.header)
			assert(s:respond(200, {}))
			assert(s:closewrite("ok"))
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), fields,
				":method", "GET", ":scheme", "http", ":path", "/"))))
			testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "Test 128: split Cookie request remains valid")
		end)
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", fields)))
		end, function(ch)
			local s<close> = get(assert(ch))
			testaux.asserteq(s:readall(2000), "", "Test 128: split Cookie response remains valid")
			check(s.header)
		end)
	end
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
		local s<close> = assert(assert(ch):request("POST", "/", {}))

		local ok, err = s:closewrite("x", {["x-trailer"] = "forbidden"})
		testaux.asserteq(ok, false, "NO_ERROR can stop request after DATA waiter was detached")
		testaux.asserteq(err, "Request stopped by peer", "request stop has a distinct reason")
		testaux.asserteq(s:readall(2000), "", "the complete response is preserved")
	end)
end)

testaux.case("Test 134: CONNECT requests use authority form without scheme or path", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local fields = assert(hpack.unpack(hpack.new(4096), request.data))
		testaux.asserteq(fields, {":authority", "target.example:443", ":method", "CONNECT"},
			"classic CONNECT has only its two required pseudo-headers")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. frame(0, 1, request.id, "tunnel")))
	end, function(ch)
		local s<close> = assert(assert(ch):request("CONNECT", "target.example:443", {}))

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
		local s<close> = assert(assert(ch):request("CONNECT", "target.example:443", {}))

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
	local closed = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(3, 0, first.id, string.pack(">I4", 8))))
		testaux.await(closed, "Test 137: reset stream was explicitly closed")
		assert(conn:write(peer.headers(encoder, first.id, "200", {["x-reset"] = "retained"})
			.. frame(0, 9, first.id, "\3discard\0\0\0")))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, request.id, "200", {["x-reset"] = "retained"}, 4)
			.. frame(0, 1, request.id, "ok")))
		local credit = 0
		while credit < 13 do
			local update = peer.untilframe(conn, 8)
			if update.id == 0 then
				credit = credit + string.unpack(">I4", update.data)
			end
		end
		testaux.asserteq(credit, 13, "Test 137.1: discarded DATA includes padding in connection credit")
	end, function(ch)
		ch = assert(ch)
		local first<close> = get(ch)
		local body, err = first:readall(2000)
		testaux.asserteq(body, nil, "reset stream does not deliver later DATA")
		testaux.asserteq(err, "Stream cancelled", "the original reset reason is preserved")
		first:close()
		testaux.asserteq(ch.streams[first.id], nil, "Test 137.2: late frames arrive after the stream mapping is removed")
		closed:push(true)
		local second<close> = get(ch)
		testaux.asserteq(second:readall(2000), "ok", "another stream remains usable")
		testaux.asserteq(second.header["x-reset"], "retained", "closed HEADERS update shared HPACK state")
	end)
end)

testaux.case("Test 139: New requests use the latest initial send window", function()
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
		allocated:push(true)
		testaux.await(changed, "SETTINGS was acknowledged before request creation")
		local stream<close> = assert(ch:request("POST", "/", {}))
		assert(stream:closewrite(body))
		testaux.asserteq(stream:readall(2000), "", "Test 139: latest send window initializes new requests")
	end)
end)

testaux.case("Test 140: Pending requests count toward ID exhaustion before admission", function()
	local started, admitted, done, drained = channel.new(), channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		testaux.await(admitted, "Test 140: excess requests failed before admission opened")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 4))))
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.id, 0x7fffffff, "Test 140.1: admitted request uses the final valid ID")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		testaux.await(drained, "Test 140: final request completed")
	end, function(ch)
		ch = assert(ch)
		ch.streamidx = 0x7ffffffd
		for _ = 1, 4 do
			task.fork(function()
				started:push(true)
				local stream, err = ch:request("GET", "/", {}, true)
				done:push({stream = stream, err = err})
			end)
		end
		for _ = 1, 4 do
			testaux.await(started, "Test 140: request entered admission")
		end
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 140.2: only the request with an available ID is queued")
		testaux.asserteq(ch:isalive(), false, "Test 140.8: pending admission reserves the final ID from reuse")
		for _ = 1, 3 do
			local result = testaux.await(done, "Test 140: excess request fails without waiting for a slot")
			testaux.asserteq(result.stream, nil, "Test 140.3: excess request returns no stream")
			testaux.asserteq(result.err, "Stream id exhausted", "Test 140.4: queued requests count toward exhaustion")
		end
		admitted:push(true)
		local result = testaux.await(done, "Test 140: final ID is admitted")
		local stream<close> = assert(result.stream, result.err)
		testaux.asserteq(stream:readall(2000), "", "Test 140.5: final request completes normally")
		stream:close()
		testaux.asserteq(ch.streamcount, 0, "Test 140.6: only the admitted request occupied a slot")
		testaux.asserteq(ch.openwaitq:size(), 0, "Test 140.7: no request remains queued after the final ID")
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
		local stream<close> = assert(assert(ch):request("POST", "/", {}))

		local ok, err = stream:closewrite("blocked")
		testaux.asserteq(ok, false, "reset fails the blocked writer")
		testaux.asserteq(err, "Stream cancelled", "the queued stream error is preserved")
		testaux.asserteq(ch.errstr, "Implementation fault", "connection retains its own later error")
		testaux.asserteq(ch.conn, nil, "the later abort still releases the transport")
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
			local stream = assert(ch:request("POST", "/", {}))

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
			testaux.asserteq(ch:isidle(), true, "no active stream or stale opener remains")
			testaux.asserteq(ch.sendwaitq:size(), 0, "no stale DATA waiter remains")
		end)
	end
end)

testaux.case("Test 152: Response timeout leaves an admitted stream retryable", function()
	local expired = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		testaux.await(expired, "Test 152: response wait timed out")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		local stream<close> = assert(ch:request("POST", "/", {}))
		local ok, err = stream:waitresponse(0)
		testaux.asserteq(ok, false, "Test 152.1: response wait times out")
		testaux.assertcontains(err, "timed out", "Test 152.2: timeout reason is retained")
		testaux.asserteq(stream.readco, nil, "Test 152.3: timed out reader is detached")
		testaux.asserteq(not ch.openwaitq or ch.openwaitq:size() == 0, true, "Test 152.4: response reads do not enter admission")
		expired:push(true)
		assert(stream:waitresponse(2000))
		testaux.asserteq(stream:readall(2000), "", "Test 152.5: the next response wait succeeds")
	end)
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
			local stream<close> = assert(ch:request("POST", "/", {}))

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

testaux.case("Test 159: Respond submits headers before request body reads", function()
	local done = channel.new()
	peer.withserver(function(stream)
		assert(stream:respond(200, {["x-flush"] = "automatic"}))
		local data, err = stream:read(1, 2000)
		done:push({data = data, err = err})
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 4, 1, hpack.pack(hpack.new(4096), {},
			":method", "POST", ":scheme", "http", ":path", "/"))))
		local header = peer.untilframe(conn, 1)
		testaux.asserteq(header.flags & 1, 0, "Test 159.1: automatic response flush leaves DATA open")
		assert(conn:write(frame(0, 1, 1, "x")))
		local result = testaux.await(done, "Test 159: request body wakes the handler")
		testaux.asserteq(result.data, "x", "Test 159.2: server reads without a separate flush")
		local last = peer.untilframe(conn, 0)
		testaux.asserteq({last.flags, last.data}, {1, ""}, "Test 159.3: handler return closes with empty DATA")
	end)
end)

testaux.case("Test 164: Local close drains admitted DATA reads and writes", function()
	local grant, admitted, credit = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4I2I4", 3, 1, 4, 0))
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		admitted:push(true)
		testaux.await(credit, "Test 164: local close retained reader and DATA writer")
		assert(conn:write(frame(8, 0, request.id, string.pack(">I4", 4))
			.. frame(8, 0, 0, string.pack(">I4", 4))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "body", "Test 164.1: DATA drains while closing")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		ch = assert(ch)
		ch.sendwindow = 0
		local stream<close> = assert(ch:request("POST", "/", {}))

		local started, reads, writes = channel.new(), channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local ok, err = stream:closewrite("body")
			writes:push({ok = ok, err = err})
		end)
		testaux.await(started, "Test 164: writer entered admission")
		ch:close()
		testaux.assertneq(stream.writeco, nil, "Test 164.2: local close preserves admitted DATA writer")
		grant:push(true)
		testaux.await(admitted, "Test 164: stream received its wire ID")
		task.fork(function()
			started:push(true)
			local ok, err = stream:waitresponse(2000)
			reads:push({ok = ok, err = err})
		end)
		testaux.await(started, "Test 164: sent stream registered its reader")
		testaux.assertneq(stream.readco, nil, "Test 164.3: reader can start while closing")
		testaux.assertneq(stream.writeco, nil, "Test 164.4: DATA writer remains independent")
		credit:push(true)
		testaux.asserteq(testaux.await(writes, "Test 164: writer completed").ok, true,
			"Test 164.5: queued DATA drains after both window updates")
		testaux.asserteq(testaux.await(reads, "Test 164: reader completed").ok, true,
			"Test 164.6: reader receives the response")
		stream:close()
		testaux.asserteq(ch.conn, nil, "Test 164.7: the drained channel closes automatically")
	end)
end)

testaux.case("Test 167: A closing server refuses new requests and completes an accepted request body", function()
	peer.withserver(function(s)
		s.channel:close()
		assert(s:respond(200, {}))
		assert(s:flush())
		testaux.asserteq(s:readall(2000), "body", "Test 167.1: accepted request DATA is still processed")
		assert(s:closewrite("ok"))
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		local headers = hpack.pack(encoder, {}, ":method", "POST", ":path", "/", ":scheme", "http", ":authority", "test")
		assert(conn:write(frame(1, 4, 1, headers)))
		peer.untilframe(conn, 7)
		peer.untilframe(conn, 1)
		assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {}, ":method", "GET", ":path", "/", ":scheme", "http", ":authority", "test"))))
		local rst = peer.untilframe(conn, 3)
		testaux.asserteq({rst.id, (string.unpack(">I4", rst.data))}, {3, 7},
			"Test 167.2: a new request is refused while the old one drains")
		assert(conn:write(frame(0, 1, 1, "body")))
		testaux.asserteq(peer.untilframe(conn, 0).data, "ok", "Test 167.3: accepted response completes")
	end)
end)

testaux.case("Test 168: Request headers are sent before waiting for a response", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.flags & 1, 0, "Test 168.1: waitresponse leaves request DATA open")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		testaux.asserteq(peer.untilframe(conn, 0).data, "body", "Test 168.2: request body can follow the response")
		peer.untilframe(conn, 7)
	end, function(ch)
		ch = assert(ch)
		local stream<close> = assert(ch:request("POST", "/", {}))

		local ok, err = stream:waitresponse(100)
		testaux.asserteq(ok, true, err or "Test 168.3: waitresponse sends the cached request headers")
		testaux.asserteq(stream:readall(2000), "", "Test 168.4: headers-only response is readable without DATA")
		assert(stream:closewrite("body"))
		stream:close()
		ch:close()
	end)
end)

testaux.case("Test 169: Response headers precede buffered request reads", function()
	for _, method in ipairs({"read", "readall"}) do
		local release, done = channel.new(), channel.new()
		peer.withserver(function(stream)
			testaux.await(release, "Test 169: request DATA was processed before reading")
			assert(stream:respond(200, {}))
			local data, err
			if method == "read" then
				data, err = stream:read(1, 2000)
			else
				data, err = stream:readall(2000)
			end
			done:push({data = data, err = err})
		end, function(conn)
			peer.clienthandshake(conn)
			assert(conn:write(frame(1, 4, 1, hpack.pack(hpack.new(4096), {},
				":method", "POST", ":scheme", "http", ":path", "/"))
				.. frame(0, 1, 1, "x") .. frame(6, 0, 0, "12345678")))
			peer.untilframe(conn, 6)
			release:push(true)
			local header = peer.untilframe(conn, 1)
			testaux.asserteq(header.flags & 1, 0, "Test 169.2: reading does not end the response")
			testaux.asserteq(testaux.await(done, "Test 169: buffered read completed").data, "x",
				"Test 169.3: server can read a completed request")
			peer.untilframe(conn, 0)
		end)
	end
end)

testaux.case("Test 171: Locally detected connection errors retain their HTTP/2 error reason", function()
	for _, fixture in ipairs({
		{data = string.pack(">I4", 0), code = 1, err = "Protocol error detected"},
		{data = "bad", code = 6, err = "Frame size incorrect"},
		{data = string.pack(">I4", 0x7fffffff), code = 3, err = "Flow-control limits exceeded"},
	}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			peer.untilframe(conn, 1)
			assert(conn:write(frame(8, 0, 0, fixture.data)))
			local goaway = peer.untilframe(conn, 7)
			testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture.code,
				"Test 171.1: GOAWAY carries the detected error code")
		end, function(ch)
			ch = assert(ch)
			local stream<close> = get(ch)
			local ok, err = stream:waitresponse(2000)
			testaux.asserteq(ok, false, "Test 171.2: protocol error fails the response wait")
			testaux.asserteq(err, fixture.err, "Test 171.3: waiter receives the mapped local error")
			testaux.asserteq(ch.errstr, fixture.err, "Test 171.4: later transport closure preserves the protocol error")
			local opened, cause = ch:request("GET", "/", {})
			testaux.asserteq(opened, nil, "Test 171.5: failed channel rejects new streams")
			testaux.asserteq(cause, fixture.err, "Test 171.6: new opens retain the same mapped reason")
		end)
	end
end)

testaux.case("Test 172: CONTINUATION read errors do not replace the original frame error", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 0)
			.. frame(9, 4, request.id, string.rep("x", 16385))))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 6, "Test 172.1: oversized continuation reports FRAME_SIZE_ERROR")
	end, function(ch)
		ch = assert(ch)
		local stream<close> = get(ch)
		local ok, err = stream:waitresponse(2000)
		testaux.asserteq(ok, false, "Test 172.2: invalid continuation fails the response")
		testaux.asserteq(err, "Frame size incorrect", "Test 172.3: outer header parsing preserves the original error")
		testaux.asserteq(ch.errstr, err, "Test 172.4: channel retains the same reason")
	end)
end)

testaux.case("Test 173: Handshake failures return the recorded protocol or transport reason", function()
	for _, fixture in ipairs({
		{data = frame(8, 0, 0, string.pack(">I4", 0)), code = 1, err = "Protocol error detected"},
		{data = frame(8, 0, 0, "bad"), code = 6, err = "Frame size incorrect"},
		{data = frame(4, 0, 0, string.rep("x", 16385)), code = 6, err = "Frame size incorrect"},
		{err = EEOF},
	}) do
		peer.withclient(function(conn)
			testaux.asserteq(conn:read(#peer.preface), peer.preface, "Test 173.1: client sends the HTTP/2 preface")
			peer.untilframe(conn, 4)
			assert(conn:write(frame(4, 0, 0)))
			local ack = peer.untilframe(conn, 4)
			testaux.asserteq(ack.flags & 1, 1, "Test 173.2: client processed initial SETTINGS")
			if fixture.data then
				assert(conn:write(fixture.data))
				local goaway = peer.untilframe(conn, 7)
				testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture.code,
					"Test 173.5: handshake sends the original local error code")
			end
		end, function(ch, err)
			testaux.asserteq(ch, nil, "Test 173.3: connection fails before the peer SETTINGS ACK")
			testaux.asserteq(err, fixture.err, "Test 173.4: public handshake error preserves the actual reason")
		end)
	end
end)

testaux.case("Test 174: Empty content before trailers emits no DATA frame", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 4, 0))
		local request = peer.untilframe(conn, 1)
		local trailer
		repeat
			trailer = assert(peer.read(conn))
		until trailer.type ~= 4 and trailer.type ~= 8
		testaux.asserteq({trailer.type, trailer.id, trailer.flags}, {1, request.id, 5},
			"Test 174.1: trailers follow request headers without an empty DATA frame")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		local stream<close> = assert(assert(ch):request("POST", "/", {}))

		assert(stream:closewrite("", {["x-trailer"] = "done"}))
		testaux.asserteq(stream:waitresponse(2000), true, "Test 174.2: empty content and trailers complete")
	end)
end)

testaux.case("Test 175: Transport failure closes before any further read", function()
	for _, location in ipairs({"header", "payload", "continuation header", "continuation payload"}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			local partial = location == "header" and "xx"
				or string.pack(">I3I1I1I4", 4, 0, 0, request.id) .. "xx"
			if location == "continuation header" then
				partial = peer.headers(hpack.new(4096), request.id, "200", {}, 0) .. "xx"
			elseif location == "continuation payload" then
				partial = peer.headers(hpack.new(4096), request.id, "200", {}, 0)
					.. string.pack(">I3I1I1I4", 4, 9, 4, request.id) .. "xx"
			end
			assert(conn:write(partial))
		end, function(ch)
			ch = assert(ch)
			local conn = ch.conn
			local read = conn.read
			local cause
			conn.read = function(self, ...)
				if cause then
					testaux.asserteq(ch.conn, nil, "Test 175.4: failure closes before another read")
				end
				local data, err = read(self, ...)
				if not data then
					cause = cause or err
				end
				return data, err
			end
			local stream<close> = get(ch)
			local ok, err = stream:waitresponse(2000)
			testaux.asserteq(ok, false, "Test 175.1: truncated " .. location .. " fails the response")
			testaux.assertneq(cause, nil, "Test 175.2: transport reports the read failure")
			testaux.asserteq(err, cause, "Test 175.3: caller retains the actual transport error")
			testaux.asserteq(ch.conn, nil, "Test 175.5: failure releases the transport immediately")
		end)
	end
end)

testaux.case("Test 176: Fatal shutdown discards queued application frames", function()
	for _, source in ipairs({"local", "peer"}) do
		local settled, queued = channel.new(), channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			settled:push(true)
			testaux.await(queued, "Test 176: request DATA is queued for flushing")
			local failure = source == "local" and frame(8, 0, 0, string.pack(">I4", 0))
				or frame(7, 0, 0, string.pack(">I4I4", request.id, 2))
			assert(conn:write(failure))
			if source == "local" then
				local goaway = assert(peer.read(conn))
				testaux.asserteq(goaway.type, 7, "Test 176.1: GOAWAY replaces queued request DATA")
				testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1,
					"Test 176.2: local protocol failure retains its code")
			end
			testaux.asserteq(peer.read(conn), nil,
				"Test 176.3: fatal shutdown sends no queued DATA or extra GOAWAY")
		end, function(ch)
			ch = assert(ch)
			local stream<close> = assert(ch:request("POST", "/", {}))

			assert(stream:flush())
			testaux.await(settled, "Test 176: initial request headers were flushed")
			local fork = task.fork
			task.fork = function(fn, arg, ...)
				if arg == ch then
					return task.running()
				end
				return fork(fn, arg, ...)
			end
			local ok, err = pcall(stream.write, stream, "discard me")
			task.fork = fork
			assert(ok, err)
			testaux.assertgt(#ch.sendbuf, 0, "Test 176.4: application DATA awaits its scheduled flush")
			queued:push(true)
			local received, cause = stream:waitresponse(2000)
			testaux.asserteq(received, false, "Test 176.5: fatal shutdown fails the response wait")
			testaux.asserteq(cause, source == "local" and "Protocol error detected" or "Implementation fault",
				"Test 176.6: fatal shutdown retains the correct error source")
			testaux.asserteq(ch.conn, nil, "Test 176.7: fatal shutdown releases the transport")
		end)
	end
end)

testaux.case("Test 177: Graceful EOF preserves a buffered completed response", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. frame(0, 1, request.id, "complete")))
	end, function(ch, err, observer)
		local s<close> = assert(ch:request("GET", "/", {}, true))
		ch:close()
		observer:waitclosed()
		testaux.asserteq(s:waitresponse(2000), true, "Test 177.1: completed headers survive transport EOF")
		testaux.asserteq(s:readall(2000), "complete", "Test 177.2: buffered completed body survives EOF")
	end)
end)


testaux.case("Test 178: Removed server streams preserve HPACK and padded DATA credit", function()
	local first
	peer.withserver(function(s)
		if s.id == 1 then
			first = s
		else
			testaux.asserteq(s.header["x-closed"], "indexed", "Test 178.1: discarded HEADERS update HPACK")
		end
		assert(s:respond(200, {}, true))
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		local function request(id)
			return frame(1, 5, id, hpack.pack(encoder, {["x-closed"] = "indexed"},
				":method", "GET", ":path", "/", ":scheme", "http"))
		end
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {},
			":method", "GET", ":path", "/", ":scheme", "http"))))
		peer.untilframe(conn, 1)
		testaux.asserteq(first.channel.streams[first.id], nil, "Test 178.2: completed handler releases its stream mapping")
		local late = hpack.pack(encoder, {["x-closed"] = "indexed"})
		local split = #late // 2
		assert(conn:write(frame(1, 0, 1, late:sub(1, split))
			.. frame(9, 4, 1, late:sub(split + 1))
			.. frame(0, 9, 1, "\3late\0\0\0")
			.. frame(8, 0, 1, string.pack(">I4", 0))
			.. frame(3, 0, 1, string.pack(">I4", 8))
			.. request(3) .. frame(6, 0, 0, "old-srv!")))
		local credit, response, ping = 0, false, false
		while credit < 8 or not response or not ping do
			local reply = assert(peer.read(conn))
			testaux.asserteq(reply.type == 3 or reply.type == 7, false,
				"Test 178.3: discarded closed frames do not reset or abort")
			if reply.type == 8 and reply.id == 0 then
				credit = credit + string.unpack(">I4", reply.data)
			elseif reply.type == 1 and reply.id == 3 then
				response = reply.flags & 1 == 1
			elseif reply.type == 6 then
				testaux.asserteq({reply.flags, reply.data}, {1, "old-srv!"}, "Test 178.4: PING barrier completes")
				ping = true
			end
		end
		testaux.asserteq(credit, 8, "Test 178.5: all discarded padded DATA is refunded")
	end)
end)

testaux.case("Test 179: Removed stream HEADERS still enforce HPACK validity", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200")))
		peer.untilframe(conn, 1)
		assert(conn:write(frame(1, 4, first.id, "\x80")))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 9, "Test 179.1: client reports COMPRESSION_ERROR")
	end, function(ch)
		local first = get(assert(ch))
		assert(first:waitresponse(2000))
		first:close()
		local second<close> = get(ch)
		testaux.asserteq(second:waitresponse(2000), false, "Test 179.2: corrupt shared HPACK fails other streams")
	end)
	peer.withserver(function(s)
		assert(s:respond(200, {}, true))
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
			":method", "GET", ":path", "/", ":scheme", "http"))))
		peer.untilframe(conn, 1)
		assert(conn:write(frame(1, 4, 1, "\x80")))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 9, "Test 179.3: server reports COMPRESSION_ERROR")
	end)
end)


testaux.case("Test 180: Removed streams still reject invalid DATA and HEADERS padding", function()
	for _, typ in ipairs({0, 1}) do
		for _, fixture in ipairs({{data = "", code = 6}, {data = "\1", code = 1}}) do
			peer.withclient(function(conn)
				peer.serverhandshake(conn)
				local first = peer.untilframe(conn, 1)
				assert(conn:write(peer.headers(hpack.new(4096), first.id, "200")))
				peer.untilframe(conn, 1)
				assert(conn:write(frame(typ, 12, first.id, fixture.data)))
				local goaway = peer.untilframe(conn, 7)
				testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture.code,
					"Test 180.1: client validates padding before discarding a removed stream")
			end, function(ch)
				local first = get(assert(ch))
				assert(first:waitresponse(2000))
				first:close()
				local second<close> = get(ch)
				testaux.asserteq(second:waitresponse(2000), false,
					"Test 180.2: invalid padding remains a connection error")
			end)
			peer.withserver(function(s)
				assert(s:respond(200, {}, true))
			end, function(conn)
				peer.clienthandshake(conn)
				assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {},
					":method", "GET", ":path", "/", ":scheme", "http"))))
				peer.untilframe(conn, 1)
				assert(conn:write(frame(typ, 12, 1, fixture.data)))
				local goaway = peer.untilframe(conn, 7)
				testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture.code,
					"Test 180.3: server validates padding before discarding a removed stream")
			end)
		end
	end
end)

testaux.case("Test 181: Padded priority HEADERS preserve fragmented HPACK on both endpoints", function()
	local function paddedheaders(id, payload)
		local split = #payload // 2
		return frame(1, 0x29, id, "\3" .. string.pack(">I4I1", 0, 15) .. payload:sub(1, split) .. "\0\0\0")
			-- PADDED has no meaning on CONTINUATION and must not strip its HPACK bytes.
			.. frame(9, 12, id, payload:sub(split + 1))
	end
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(paddedheaders(request.id, hpack.pack(hpack.new(4096),
			{["x-padded"] = "response"}, ":status", "200"))))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "", "Test 181.1: padding and priority are excluded from HPACK")
		testaux.asserteq(s.header["x-padded"], "response", "Test 181.2: fragmented response is decoded")
	end)
	peer.withserver(function(s)
		testaux.asserteq(s.header["x-padded"], "request", "Test 181.3: fragmented request is decoded")
		testaux.asserteq(s:readall(2000), "", "Test 181.4: initial END_STREAM survives padding removal")
		assert(s:respond(200, {}, true))
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(paddedheaders(1, hpack.pack(hpack.new(4096), {["x-padded"] = "request"},
			":method", "GET", ":path", "/", ":scheme", "http"))))
		testaux.asserteq(peer.untilframe(conn, 1).flags & 1, 1, "Test 181.5: server completes its response")
	end)
end)


testaux.case("Test 182: Peer GOAWAY error codes stay textual and are not echoed during handshake", function()
	for _, fixture in ipairs({
		{code = 2, err = "Implementation fault"},
		{code = 0xffffffff, err = "Unknown error code: 4294967295"},
	}) do
		peer.withclient(function(conn)
			testaux.asserteq(conn:read(#peer.preface), peer.preface, "Test 182.1: client starts the handshake")
			peer.untilframe(conn, 4)
			assert(conn:write(frame(4, 0, 0)))
			peer.untilframe(conn, 4)
			assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, fixture.code))))
			testaux.asserteq(peer.read(conn), nil, "Test 182.2: peer error is not sent back as a local GOAWAY")
		end, function(ch, err)
			testaux.asserteq(ch, nil, "Test 182.3: peer error terminates the incomplete handshake")
			testaux.asserteq(err, fixture.err, "Test 182.4: public API preserves peer error text")
		end)
	end
end)


testaux.case("Test 183: Queued string and numeric headers preserve admission order and final IDs", function()
	local started, done = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		local decoder, encoder = hpack.new(4096), hpack.new(4096)
		local first = peer.untilframe(conn, 1)
		assert(hpack.unpack(decoder, first.data))
		for _, id in ipairs({0x7ffffffd, 0x7fffffff}) do
			local request = peer.untilframe(conn, 1)
			testaux.asserteq(request.id, id, "Test 183.1: waiters receive the remaining IDs in order")
			local fields = assert(hpack.unpack(decoder, request.data))
			local number, repeated = nil, {}
			for i = 1, #fields, 2 do
				if fields[i] == "x-number" then
					number = fields[i + 1]
				elseif fields[i] == "x-many" then
					repeated[#repeated + 1] = fields[i + 1]
				end
			end
			testaux.asserteq(number, "123", "Test 183.2: queued numeric headers encode as text")
			testaux.asserteq(repeated, {"one", "two"}, "Test 183.3: queued repeated headers remain complete")
			assert(conn:write(peer.headers(encoder, id, "200")))
		end
	end, function(ch)
		local first = get(assert(ch))
		ch.streamidx = 0x7ffffffb
		local headers = {host = "kept", ["x-number"] = 123, ["x-many"] = {"one", "two"}}
		for _ = 1, 2 do
			task.fork(function()
				started:push(true)
				local stream<close> = assert(ch:request("GET", "/queued", headers, true))
				testaux.asserteq(stream:readall(2000), "", "Test 183.4: directly notified waiter completes its response")
				done:push(true)
			end)
			testaux.await(started, "Test 183: request entered admission queue")
		end
		first:close()
		testaux.asserteq(ch.streamcount, 1, "Test 183.5: admission consumes a slot before notification")
		for _ = 1, 2 do testaux.await(done, "Test 183: queued response completed") end
		testaux.asserteq(headers, {host = "kept", ["x-number"] = 123, ["x-many"] = {"one", "two"}},
			"Test 183.6: caller header values retain their original types")
		testaux.asserteq(ch.streamidx, 0x7fffffff, "Test 183.7: the final available ID was admitted")
	end)
end)

testaux.case("Test 184: Closing the transport preserves the original graceful reason", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		while peer.read(conn) do end
	end, function(ch)
		local s<close> = get(assert(ch))
		local resumed = channel.new()
		local function checkpoint()
			task.fork(function() resumed:push(true) end)
			testaux.await(resumed, "Test 184: ready tasks resumed")
		end
		checkpoint() -- Let the dispatcher block in its next frame read.
		ch:close()
		local reason = ch.errstr
		s:close()
		checkpoint() -- The cancelled frame read resumes before this checkpoint.
		testaux.asserteq(ch.conn, nil, "Test 184.1: graceful drain releases the connection")
		testaux.asserteq(ch.errstr, reason, "Test 184.2: a resumed reader cannot overwrite the close reason")
	end)
end)


testaux.case("Test 185: Graceful draining can abort without corrupting a completed exchange", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local completed = peer.untilframe(conn, 1)
		peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		assert(conn:write(peer.headers(hpack.new(4096), completed.id, "200", {}, 4)
			.. frame(0, 1, completed.id, "complete") .. frame(6, 0, completed.id, "bad-ping")))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1,
			"Test 185.1: fatal error during drain sends PROTOCOL_ERROR")
	end, function(ch, err, observer)
		local completed<close> = get(assert(ch))
		local unfinished<close> = assert(ch:request("POST", "/", {}))
		ch:close()
		observer:waitclosed()
		testaux.asserteq(ch.errstr, "Protocol error detected", "Test 185.2: drain upgrades to the fatal reason")
		testaux.asserteq(completed:waitresponse(2000), true, "Test 185.3: completed headers survive abort")
		testaux.asserteq(completed:readall(2000), "complete", "Test 185.4: completed buffered body survives abort")
		local ok, cause = unfinished:waitresponse(2000)
		testaux.asserteq(ok, false, "Test 185.5: unfinished stream fails")
		testaux.asserteq(cause, ch.errstr, "Test 185.6: unfinished stream gets the fatal reason")
	end)
end)


testaux.case("Test 186: Complete responses survive connection failure while the request remains open", function()
	for _, source in ipairs({"eof", "local", "peer"}) do
		for _, ending in ipairs({"body", "headers", "trailers"}) do
			peer.withclient(function(conn)
				peer.serverhandshake(conn)
				local request = peer.untilframe(conn, 1)
				local encoder = hpack.new(4096)
				local response = peer.headers(encoder, request.id, "200", {}, ending == "headers" and 5 or 4)
				if ending ~= "headers" then
					response = response .. frame(0, ending == "body" and 1 or 0, request.id, "complete")
				end
				if ending == "trailers" then
					response = response .. frame(1, 5, request.id, hpack.pack(encoder, {["x-end"] = "yes"}))
				end
				if source == "local" then
					response = response .. frame(6, 0, request.id, "bad-ping")
				elseif source == "peer" then
					response = response .. frame(7, 0, 0, string.pack(">I4I4", request.id, 2))
				end
				assert(conn:write(response))
				if source == "local" then peer.untilframe(conn, 7) end
			end, function(ch, err, observer)
				local s<close> = assert(assert(ch):request("POST", "/", {}))
				observer:waitclosed()
				testaux.asserteq(s:waitresponse(2000), true, "Test 186.1: complete response headers survive " .. source)
				if ending ~= "headers" then
					testaux.asserteq(s:read(3, 2000), "com", "Test 186.2: fixed-size reads retain complete response data")
				end
				testaux.asserteq(s:readall(2000), ending == "headers" and "" or "plete",
					"Test 186.3: completed response remains readable")
				local data, cause = s:read(1, 2000)
				testaux.asserteq({data, cause}, {nil, EEOF}, "Test 186.4: response ends with EOF rather than upload error")
				if ending == "trailers" then
					testaux.asserteq(s.trailer["x-end"], "yes", "Test 186.5: response trailers survive")
				end
				testaux.asserteq(s:write("later"), false, "Test 186.6: failed connection cannot accept more request data")
			end)
		end
	end
end)

testaux.case("Test 187: A content-length reset is not a successful receive END", function()
	for _, mode in ipairs({"read", "readall", "buffered"}) do
		local reset = channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {["content-length"] = "9"}, 4)
				.. frame(0, 1, request.id, "short")))
			peer.untilframe(conn, 3)
			reset:push(true)
			while peer.read(conn) do end
		end, function(ch)
			local s = get(assert(ch))
			if mode == "buffered" then testaux.await(reset, "Test 187: malformed END was reset") end
			local body, err
			if mode == "read" then body, err = s:read(9, 2000) else body, err = s:readall(2000) end
			testaux.asserteq(body, nil, "Test 187.1: malformed response is rejected")
			testaux.asserteq(err, "Protocol error detected", "Test 187.2: reset retains validation error")
			testaux.asserteq(s:eof(), false, "Test 187.3: failed validation cannot report successful EOF")
			testaux.asserteq(s:waitresponse(2000), false, "Test 187.4: reset fails the entire response")
			s:close()
			ch:close()
		end)
	end
end)

testaux.case("Test 188: An incomplete response still fails when an open request loses its connection", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. frame(0, 0, request.id, "partial")))
	end, function(ch, err, observer)
		local s<close> = assert(assert(ch):request("POST", "/", {}))
		observer:waitclosed()
		testaux.asserteq(s:waitresponse(2000), false, "Test 188.1: incomplete response fails")
		local body, cause = s:readall(2000)
		testaux.asserteq(body, nil, "Test 188.2: readall cannot mistake a partial response for success")
		testaux.assertneq(cause, nil, "Test 188.3: readall reports the connection failure")
		testaux.asserteq(s:eof(), false, "Test 188.4: transport EOF is not successful stream EOF")
	end)
end)


testaux.case("Test 189: Peer GOAWAY stops admission retained by a local close", function()
	local ready, done = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		local first = peer.untilframe(conn, 1)
		peer.untilframe(conn, 7)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", first.id, 0))
			.. peer.headers(hpack.new(4096), first.id, "200")))
		while true do
			local reply = peer.read(conn)
			if not reply then break end
			testaux.assertneq(reply.type, 1, "Test 189.1: remote GOAWAY forbids queued request HEADERS")
			testaux.assertneq(reply.type, 7, "Test 189.2: repeated close sends no duplicate graceful GOAWAY")
		end
	end, function(ch)
		local first<close> = get(assert(ch))
		task.fork(function()
			ready:push(true)
			local s, err = ch:request("GET", "/queued", {}, true)
			done:push({stream = s, err = err})
		end)
		testaux.await(ready, "Test 189: request is queued")
		ch:close()
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 189.3: local close retains queued admission")
		local result = testaux.await(done, "Test 189: remote GOAWAY rejects pending admission")
		testaux.asserteq(result.stream, nil, "Test 189.4: no new stream after remote GOAWAY")
		testaux.asserteq(result.err, "Graceful shutdown", "Test 189.5: waiter receives peer shutdown reason")
		testaux.asserteq(ch.goaway, 3, "Test 189.6: both GOAWAY directions are recorded")
		ch:close()
		testaux.asserteq(first:readall(2000), "", "Test 189.7: the admitted response still completes")
		first:close()
	end)
end)

testaux.case("Test 190: SETTINGS admits queued work after a local graceful close", function()
	local ready, done = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 0))
		peer.untilframe(conn, 7)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local request = peer.untilframe(conn, 1)
		testaux.asserteq(request.id, 1, "Test 190.1: SETTINGS admits the queued request despite local GOAWAY")
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		while peer.read(conn) do end
	end, function(ch)
		ch = assert(ch)
		task.fork(function()
			ready:push(true)
			local stream, err = ch:request("GET", "/queued", {}, true)
			done:push({stream = stream, err = err})
		end)
		testaux.await(ready, "Test 190: request awaits peer capacity")
		ch:close()
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 190.2: local close retains admission waiting for SETTINGS")
		local result = testaux.await(done, "Test 190: SETTINGS resumed the requester")
		local stream<close> = assert(result.stream, result.err)
		testaux.asserteq(stream:readall(2000), "", "Test 190.3: admitted request completes normally")
		stream:close()
		testaux.asserteq(ch.conn, nil, "Test 190.4: final stream releases the locally closed connection")
	end)
end)

testaux.case("Test 191: Client GOAWAY permits later requests from that client", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}, true))
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		local function request(id)
			return frame(1, 5, id, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))
		end
		assert(conn:write(request(1) .. frame(7, 0, 0, string.pack(">I4I4", 0, 0))))
		testaux.asserteq(peer.untilframe(conn, 1).id, 1, "Test 191.1: first request completes")
		assert(conn:write(request(3)))
		testaux.asserteq(peer.untilframe(conn, 1).id, 3, "Test 191.2: remote-only GOAWAY preserves incoming admission")
	end)
end)

testaux.case("Test 192: Fatal GOAWAY cannot increase an earlier graceful cutoff", function()
	peer.withserver(function(s)
		s.channel:close()
		s:readall(2000)
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		local function request(id)
			return frame(1, 4, id, hpack.pack(encoder, {}, ":method", "POST", ":scheme", "http", ":path", "/"))
		end
		assert(conn:write(request(1)))
		local first = peer.untilframe(conn, 7)
		local firstid, firstcode = string.unpack(">I4I4", first.data)
		testaux.asserteq({firstid, firstcode}, {1, 0}, "Test 192.1: graceful GOAWAY covers request 1")
		assert(conn:write(request(3)))
		peer.untilframe(conn, 3)
		assert(conn:write(frame(6, 0, 1, "bad-ping")))
		local last = peer.untilframe(conn, 7)
		local id, code = string.unpack(">I4I4", last.data)
		testaux.asserteq(id, 1, "Test 192.2: rejected later requests cannot increase the sent cutoff")
		testaux.asserteq(code, 1, "Test 192.3: fatal shutdown retains its protocol error code")
	end)
end)


-- Inspect actual wire credit up to an ordered PING ACK or a later request's HEADERS.
local function window_updates_until(conn, id, typ)
	local credit = 0
	while true do
		local f = assert(peer.read(conn))
		testaux.assertneq(f.type, 3, "receive-window accounting must not reset the stream")
		if f.type == 8 and f.id == id then
			credit = credit + string.unpack(">I4", f.data)
		elseif f.type == typ then
			return credit, f
		end
	end
end

local function dataframes(id, data)
	local frames = {}
	for offset = 1, #data, 16384 do
		frames[#frames + 1] = frame(0, 0, id, data:sub(offset, offset + 16383))
	end
	return table.concat(frames)
end

testaux.case("Test 193: Small reads return only consumed stream credit", function()
	for _, pending in ipairs({false, true}) do
		local ready, buffered = channel.new(), channel.new()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
			if pending then testaux.await(ready, "Test 193: single-byte read is waiting") end
			assert(conn:write(dataframes(request.id, string.rep("x", 65535)) .. frame(6, 0, 0, "buffered")))
			local credit = window_updates_until(conn, request.id, 6)
			buffered:push(true)
			local more, probe = window_updates_until(conn, request.id, 1)
			testaux.asserteq(credit + more, 1, "Test 193.1: one byte read grants exactly one byte, even after flush")
			assert(conn:write(peer.headers(hpack.new(4096), probe.id, "200") .. frame(0, 1, request.id)))
		end, function(ch)
			local s<close> = get(assert(ch))
			assert(s:waitresponse(2000))
			if pending then
				ready:push(true)
				testaux.asserteq(s:read(1, 2000), "x", "Test 193.2: pending single-byte read completes")
				testaux.await(buffered, "Test 193: remaining response is buffered")
			else
				testaux.await(buffered, "Test 193: initial window is buffered")
				testaux.asserteq(s:read(1, 2000), "x", "Test 193.3: buffered single-byte read completes")
			end
			assert(s:flush())
			local probe<close> = get(ch)
			assert(probe:waitresponse(2000))
			testaux.asserteq(s:readall(2000), string.rep("x", 65534), "Test 193.4: unread body is retained")
		end)
	end
end)

testaux.case("Test 194: Large reads do not return prepaid credit twice", function()
	local buffered = channel.new()
	local need, tail = 150000, 1000
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		local body = string.rep("x", need) .. string.rep("y", tail)
		local sent, window, credit = 0, 65535, 0
		while sent < #body do
			if window == 0 then
				local update = peer.untilframe(conn, 8)
				if update.id == request.id then
					local increment = string.unpack(">I4", update.data)
					window = window + increment
					credit = credit + increment
				end
			else
				local count = math.min(16384, window, #body - sent)
				assert(conn:write(frame(0, 0, request.id, body:sub(sent + 1, sent + count))))
				sent, window = sent + count, window - count
			end
		end
		assert(conn:write(frame(6, 0, 0, "buffered")))
		credit = credit + window_updates_until(conn, request.id, 6)
		buffered:push(true)
		local more, probe = window_updates_until(conn, request.id, 1)
		testaux.asserteq(credit + more, need + 1, "Test 194.1: prepaid large-read credit is returned only once")
		assert(conn:write(peer.headers(hpack.new(4096), probe.id, "200") .. frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:read(need, 2000), string.rep("x", need), "Test 194.2: read exceeds the initial window")
		testaux.await(buffered, "Test 194: unread tail is buffered")
		testaux.asserteq(s:read(1, 2000), "y", "Test 194.3: following small read consumes only one byte")
		assert(s:flush())
		local probe<close> = get(ch)
		assert(probe:waitresponse(2000))
		testaux.asserteq(s:readall(2000), string.rep("y", tail - 1), "Test 194.4: tail remains complete")
	end)
end)

testaux.case("Test 195: A timed-out large read retains its granted receive window", function()
	local timedout, buffered = channel.new(), channel.new()
	local need = 100000
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		local update
		repeat update = peer.untilframe(conn, 8) until update.id == request.id
		testaux.asserteq(string.unpack(">I4", update.data), need - 65535, "Test 195.1: large read grants only the missing window")
		testaux.await(timedout, "Test 195: large read timed out before receiving DATA")
		assert(conn:write(dataframes(request.id, string.rep("x", need)) .. frame(6, 0, 0, "buffered")))
		local credit = window_updates_until(conn, request.id, 6)
		buffered:push(true)
		local more, probe = window_updates_until(conn, request.id, 1)
		testaux.asserteq(credit + more, 0, "Test 195.2: small retry does not grant the prepaid window again")
		assert(conn:write(peer.headers(hpack.new(4096), probe.id, "200") .. frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		local data, err = s:read(need, 30)
		testaux.asserteq(data, nil, "Test 195.3: large read times out without data")
		testaux.asserteq(err, errno.TIMEDOUT, "Test 195.4: timeout leaves the stream usable")
		timedout:push(true)
		testaux.await(buffered, "Test 195: peer used the previously granted window")
		testaux.asserteq(s:read(1, 2000), "x", "Test 195.5: stream accepts data after the read timeout")
		assert(s:flush())
		local probe<close> = get(ch)
		assert(probe:waitresponse(2000))
		testaux.asserteq(s:readall(2000), string.rep("x", need - 1), "Test 195.6: prepaid buffered response stays readable")
	end)
end)

testaux.case("Test 196: A timed-out readall does not release unread buffered credit twice", function()
	local timedout, buffered = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. dataframes(request.id, string.rep("x", 30000))))
		local credit = 0
		while credit < 30000 do
			local update = peer.untilframe(conn, 8)
			if update.id == request.id then credit = credit + string.unpack(">I4", update.data) end
		end
		testaux.await(timedout, "Test 196: readall timed out with buffered data")
		assert(conn:write(dataframes(request.id, string.rep("y", 65535)) .. frame(6, 0, 0, "buffered")))
		local more = window_updates_until(conn, request.id, 6)
		buffered:push(true)
		local last, probe = window_updates_until(conn, request.id, 1)
		testaux.asserteq(more + last, 0, "Test 196.1: a small read consumes prepaid credit after readall timeout")
		assert(conn:write(peer.headers(hpack.new(4096), probe.id, "200") .. frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		local data, err = s:readall(200)
		testaux.asserteq(data, nil, "Test 196.2: incomplete readall times out")
		testaux.asserteq(err, errno.TIMEDOUT, "Test 196.3: buffered readall timeout is recoverable")
		timedout:push(true)
		testaux.await(buffered, "Test 196: remaining window was filled after timeout")
		testaux.asserteq(s:read(1, 2000), "x", "Test 196.4: small retry reads the retained prefix")
		assert(s:flush())
		local probe<close> = get(ch)
		assert(probe:waitresponse(2000))
		testaux.asserteq(s:readall(2000), string.rep("x", 29999) .. string.rep("y", 65535), "Test 196.5: readall retains all data across timeout")
	end)
end)


testaux.case("Test 197: Large-read credit stays within the RFC stream window limit", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		local update
		repeat update = peer.untilframe(conn, 8) until update.id == request.id
		testaux.asserteq(string.unpack(">I4", update.data), 0x7fffffff - 65535,
			"Test 197.1: advance credit cannot raise the window above 2^31-1")
		assert(conn:write(frame(0, 1, request.id)))
	end, function(ch)
		local s<close> = get(assert(ch))
		local data, err = s:read(0x7fffffff, 2000)
		testaux.asserteq(data, nil, "Test 197.2: short response ends a larger read")
		testaux.asserteq(err, EEOF, "Test 197.3: large requested length preserves receive EOF")
	end)
end)

-- The peer sends only the stream credit actually advertised on the wire.
local function send_windowed_body(conn, id, body, sent)
	sent = sent or 0
	local window = 65535 - sent
	while sent < #body do
		if window == 0 then
			local update = assert(peer.read(conn))
			testaux.assertneq(update.type, 3, "large reads must not reset the stream")
			if update.type == 8 and update.id == id then
				window = window + string.unpack(">I4", update.data)
			end
		else
			local count = math.min(16384, window, #body - sent)
			local last = sent + count
			assert(conn:write(frame(0, last == #body and 1 or 0, id, body:sub(sent + 1, last))))
			sent = last
			window = window - count
		end
	end
end

testaux.case("Test 198: A 128 KiB read completes across the initial stream window", function()
	local body = string.rep("a", 65535) .. string.rep("b", 65535) .. "cd"
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		send_windowed_body(conn, request.id, body)
	end, function(ch)
		local s<close> = get(assert(ch))
		local data, err = s:read(131072, 2000)
		testaux.asserteq(err, nil, "Test 198.1: a read larger than 64 KiB completes without timeout")
		testaux.asserteq(data, body, "Test 198.2: one read returns all 128 KiB in order")
		local tail, cause = s:read(1, 2000)
		testaux.asserteq(tail, nil, "Test 198.3: the complete body has no unread tail")
		testaux.asserteq(cause, EEOF, "Test 198.4: END_STREAM remains a normal receive EOF")
	end)
end)

testaux.case("Test 199: readall replenishes credit while receiving 128 KiB", function()
	local body = string.rep("a", 65535) .. string.rep("b", 65535) .. "cd"
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)))
		send_windowed_body(conn, request.id, body)
	end, function(ch)
		local s<close> = get(assert(ch))
		local data, err = s:readall(2000)
		testaux.asserteq(err, nil, "Test 199.1: readall keeps receiving beyond the initial window")
		testaux.asserteq(data, body, "Test 199.2: readall returns all 128 KiB in order")
		testaux.asserteq(s:readall(2000), "", "Test 199.3: a second readall has no duplicate bytes")
	end)
end)

testaux.case("Test 200: readall starts after the initial stream window is exhausted", function()
	local buffered = channel.new()
	local body = string.rep("a", 65535) .. string.rep("b", 65535) .. "cd"
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. dataframes(request.id, body:sub(1, 65535)) .. frame(6, 0, 0, "buffered")))
		local credit = window_updates_until(conn, request.id, 6)
		testaux.asserteq(credit, 0, "Test 200.1: unread initial-window data grants no extra credit")
		buffered:push(true)
		send_windowed_body(conn, request.id, body, 65535)
	end, function(ch)
		local s<close> = get(assert(ch))
		assert(s:waitresponse(2000))
		testaux.await(buffered, "Test 200: all 65535 initial-window bytes are buffered before readall")
		local data, err = s:readall(2000)
		testaux.asserteq(err, nil, "Test 200.2: readall restores credit before waiting for more DATA")
		testaux.asserteq(data, body, "Test 200.3: one readall returns the buffered prefix and the rest of 128 KiB")
		testaux.asserteq(s:readall(2000), "", "Test 200.4: the completed receive buffer is empty")
	end)
end)


testaux.case("Test 230: Invalid connection frames report their protocol error on both endpoints", function()
	local fixtures = {
		{"DATA on stream zero", frame(0, 0, 0), 1},
		{"HEADERS on stream zero", frame(1, 4, 0, "\x88"), 1},
		{"SETTINGS on a stream", frame(4, 0, 1), 1},
		{"nonempty SETTINGS ACK", frame(4, 1, 0, "x"), 6},
		{"truncated SETTINGS", frame(4, 0, 0, "x"), 6},
		{"oversized initial window", frame(4, 0, 0, string.pack(">I2I4", 4, 0x80000000)), 3},
		{"small maximum frame", frame(4, 0, 0, string.pack(">I2I4", 5, 16383)), 1},
		{"large maximum frame", frame(4, 0, 0, string.pack(">I2I4", 5, 16777216)), 1},
		{"PRIORITY on stream zero", frame(2, 0, 0, string.rep("\0", 5)), 1},
		{"short PING", frame(6, 0, 0, "short"), 6},
		{"RST_STREAM on stream zero", frame(3, 0, 0, string.pack(">I4", 8)), 1},
		{"GOAWAY on a stream", frame(7, 0, 1, string.pack(">I4I4", 0, 0)), 1},
		{"unexpected CONTINUATION", frame(9, 4, 1), 1},
		{"forbidden PUSH_PROMISE", frame(5, 4, 1, string.pack(">I4", 2)), 1},
		{"short HEADERS priority", frame(1, 0x24, 1, "x"), 6},
		{"self-dependent HEADERS", frame(1, 0x24, 1, string.pack(">I4I1", 1, 0) .. "\x88"), 1},
		{"wrong CONTINUATION stream", frame(1, 0, 1) .. frame(9, 4, 3, "\x88"), 1},
		{"oversized fragmented headers", frame(1, 0, 1, string.rep("\0", 16384))
			.. frame(9, 0, 1, string.rep("\0", 16384))
			.. frame(9, 0, 1, string.rep("\0", 16384))
			.. frame(9, 4, 1, string.rep("\0", 16384)), 11},
	}
	for _, fixture in ipairs(fixtures) do
		local function reject(conn)
			assert(conn:write(fixture[2]))
			local goaway = peer.untilframe(conn, 7)
			testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture[3], "Test 230: " .. fixture[1])
		end
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			peer.untilframe(conn, 1)
			reject(conn)
		end, function(ch)
			local s<close> = get(assert(ch))
			local ok, err = s:waitresponse(2000)
			testaux.asserteq(ok, false, "Test 230: malformed frame wakes the client waiter")
			testaux.assertneq(err, nil, "Test 230: client receives the connection failure")
		end)
		peer.withserver(function() error("malformed request reached the application") end, function(conn)
			peer.clienthandshake(conn)
			reject(conn)
		end)
	end
end)

testaux.case("Test 221: Invalid request pseudo-headers and connection fields reset only their stream", function()
	local fixtures = {
		{"unknown pseudo-header", {}, {":method", "GET", ":scheme", "http", ":path", "/", ":unknown", "x"}},
		{"duplicate pseudo-header", {}, {":method", "GET", ":scheme", "http", ":path", "/", ":path", "/again"}},
		{"missing path", {}, {":method", "GET", ":scheme", "http"}},
		{"empty path", {}, {":method", "GET", ":scheme", "http", ":path", ""}},
		{"connection field", {connection = "close"}, {":method", "GET", ":scheme", "http", ":path", "/"}},
		{"invalid TE", {te = "gzip"}, {":method", "GET", ":scheme", "http", ":path", "/"}},
	}
	for _, fixture in ipairs(fixtures) do
		peer.withserver(function(s)
			assert(s:respond(200, {}, true))
		end, function(conn)
			peer.clienthandshake(conn)
			local encoder = hpack.new(4096)
			local invalid = hpack.pack(encoder, fixture[2], table.unpack(fixture[3]))
			assert(conn:write(frame(1, 5, 1, invalid)))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq({reset.id, (string.unpack(">I4", reset.data))}, {1, 1}, "Test 221: " .. fixture[1])
			assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
			testaux.asserteq(peer.untilframe(conn, 1).id, 3, "Test 221: a valid later request still succeeds")
		end)
	end
end)

testaux.case("Test 222: Request trailers complete readall and reject pseudo-headers", function()
	for _, invalid in ipairs({false, true}) do
		local started, finished = channel.new(), channel.new()
		peer.withserver(function(s)
			started:push(true)
			local body, err = s:readall(2000)
			finished:push({body = body, err = err, trailer = s.trailer})
			if not invalid then assert(s:respond(200, {}, true)) end
		end, function(conn)
			peer.clienthandshake(conn)
			local encoder = hpack.new(4096)
			local header = hpack.pack(encoder, {}, ":method", "POST", ":scheme", "http", ":path", "/")
			local trailer = invalid and hpack.pack(encoder, {}, ":path", "/forbidden")
				or hpack.pack(encoder, {["x-finished"] = "yes"})
			assert(conn:write(frame(1, 4, 1, header)))
			testaux.await(started, "Test 222: handler is reading before trailers")
			assert(conn:write(frame(0, 0, 1, "body") .. frame(1, 5, 1, trailer)))
			if invalid then
				local reset = peer.untilframe(conn, 3)
				testaux.asserteq(string.unpack(">I4", reset.data), 1, "Test 222.1: request trailers forbid pseudo-headers")
			else
				testaux.asserteq(peer.untilframe(conn, 1).id, 1, "Test 222.2: valid request trailers permit a response")
			end
			local result = testaux.await(finished, "Test 222: trailer processing wakes readall")
			if invalid then
				testaux.asserteq(result.body, nil, "Test 222.3: invalid trailers fail readall")
				testaux.assertneq(result.err, nil, "Test 222.4: invalid trailers carry an error")
			else
				testaux.asserteq(result.body, "body", "Test 222.5: readall retains DATA preceding trailers")
				testaux.asserteq(result.trailer["x-finished"], "yes", "Test 222.6: valid trailers are delivered")
			end
		end)
	end
end)

testaux.case("Test 223: A returning handler cancels a pending writer without closing writes first", function()
	local started, finished = channel.new(), channel.new()
	peer.withserver(function(s)
		testaux.asserteq(s:write(""), true, "Test 223.1: empty writes require no response headers")
		testaux.asserteq(s:write("early"), false, "Test 223.2: DATA cannot precede response headers")
		testaux.asserteq(s:closewrite(), false, "Test 223.3: closewrite cannot precede response headers")
		assert(s:respond(200, {}))
		task.fork(function()
			started:push(true)
			local ok, err = s:write("blocked")
			finished:push({ok = ok, err = err})
		end)
		testaux.await(started, "Test 223: background writer is waiting for stream credit")
		local ok, err = pcall(s.write, s, "racing")
		testaux.asserteq(ok, false, "Test 223.4: a second write is rejected at the API entry")
		testaux.assertcontains(err, "write is pending", "Test 223.5: concurrent write reports the pending writer")
		ok, err = pcall(s.closewrite, s, nil, {["x-forbidden"] = "trailer"})
		testaux.asserteq(ok, false, "Test 223.6: trailer-only closewrite cannot overtake a pending write")
		testaux.assertcontains(err, "write is pending", "Test 223.7: closewrite rejects the race before changing state")
	end, function(conn)
		peer.clienthandshake(conn)
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 4, 0))))
		peer.untilframe(conn, 4)
		assert(conn:write(frame(1, 5, 1, hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/"))))
		local header = peer.untilframe(conn, 1)
		testaux.asserteq(header.flags & 1, 0, "Test 223.8: pending response is not prematurely ended")
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq({reset.id, (string.unpack(">I4", reset.data))}, {1, 8}, "Test 223.9: handler return cancels the unfinished stream")
		local result = testaux.await(finished, "Test 223: handler cleanup wakes the background writer")
		testaux.asserteq(result.ok, false, "Test 223.10: cancelled background write fails")
		testaux.asserteq(result.err, "Stream cancelled", "Test 223.11: background writer receives cancellation")
	end)
end)

testaux.case("Test 224: Held reset streams ignore DATA, HEADERS and window updates", function()
	local processed = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(2, 0, request.id, string.pack(">I4I1", 0, 0))
			.. frame(6, 1, 0, "ack-only")
			.. frame(3, 0, request.id, string.pack(">I4", 8))
			.. frame(0, 0, request.id, "ignored")
			.. peer.headers(hpack.new(4096), request.id, "200")
			.. frame(8, 0, request.id, string.pack(">I4", 1))
			.. frame(6, 0, 0, "rst-done")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq(ack.data, "rst-done", "Test 224.1: PING ACK does not itself trigger another ACK")
		processed:push(true)
		answer(conn, "ok")
	end, function(ch)
		local s = get(assert(ch))
		testaux.await(processed, "Test 224: frames after reset have been processed")
		testaux.asserteq(s:readall(2000), nil, "Test 224.2: reset stream cannot expose later DATA")
		s:close()
		local nextstream<close> = get(ch)
		testaux.asserteq(nextstream:readall(2000), "ok", "Test 224.3: discarded reset-stream frames do not damage the connection")
	end)
end)


testaux.case("Test 225: Successful queued admission cancels its pending timeout", function()
	local started, admitted = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		local first = get(ch)
		task.fork(function()
			started:push(true)
			local stream, err = ch:request("GET", "/next", {}, true, 2000)
			admitted:push({stream = stream, err = err})
		end)
		testaux.await(started, "Test 225: second request waits for the first slot")
		assert(first:waitresponse(2000))
		first:close()
		local result = testaux.await(admitted, "Test 225: released slot admits the timed request")
		testaux.asserteq(result.err, nil, "Test 225.1: admission succeeds before its deadline")
		local nextstream<close> = assert(result.stream)
		testaux.asserteq(nextstream:readall(2000), "ok", "Test 225.2: admitted stream remains usable")
	end)
end)

testaux.case("Test 226: A later peer GOAWAY cannot increase its last stream ID", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 0))
			.. frame(7, 0, 0, string.pack(">I4I4", request.id + 2, 0))))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 1, "Test 226.1: increasing the peer cutoff is PROTOCOL_ERROR")
	end, function(ch)
		local s<close> = get(assert(ch))
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "Test 226.2: invalid GOAWAY cancels an unfinished response")
		testaux.asserteq(err, "Protocol error detected", "Test 226.3: fatal protocol reason replaces graceful shutdown")
	end)
end)

testaux.case("Test 227: Server handshake rejects bad prefaces and initial SETTINGS", function()
	for _, fixture in ipairs({
		{"invalid preface", string.rep("x", 24), 1},
		{"truncated initial SETTINGS", peer.preface .. frame(4, 0, 0, "x"), 6},
	}) do
		peer.withserver(function() error("invalid handshake reached the application") end, function(conn)
			assert(conn:write(fixture[2]))
			local goaway = peer.untilframe(conn, 7)
			testaux.asserteq(string.unpack(">I4", goaway.data, 5), fixture[3], "Test 227: " .. fixture[1])
		end)
	end
end)

testaux.case("Test 228: Server handshake releases the connection after EOF at each read phase", function()
	for _, phase in ipairs({"preface", "settings", "ack"}) do
		peer.withserver(function() error("incomplete handshake reached the application") end, function(conn)
			if phase == "preface" then
				assert(conn:write("PRI * HTTP/2.0"))
			else
				assert(conn:write(peer.preface .. (phase == "ack" and frame(4, 0, 0) or "")))
				local settings = peer.untilframe(conn, 4)
				testaux.asserteq(settings.flags, 0, "Test 228: server sends initial settings before waiting for " .. phase)
				if phase == "ack" then
					testaux.asserteq(peer.untilframe(conn, 4).flags, 1, "Test 228: client settings were acknowledged")
				end
			end
			conn:close()
		end)
	end
end)

testaux.case("Test 229: Frames after END_STREAM and zero stream window updates fail only their stream", function()
	for _, fixture in ipairs({
		{"DATA after END_STREAM", peer.headers(hpack.new(4096), 1, "200") .. frame(0, 0, 1, "late"), 5},
		{"HEADERS after END_STREAM", peer.headers(hpack.new(4096), 1, "200") .. frame(1, 5, 1), 5},
		{"informational END_STREAM", peer.headers(hpack.new(4096), 1, "100"), 1},
		{"zero stream window update", frame(8, 0, 1, string.pack(">I4", 0)), 1},
	}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			peer.untilframe(conn, 1)
			assert(conn:write(fixture[2]))
			local reset = peer.untilframe(conn, 3)
			testaux.asserteq(string.unpack(">I4", reset.data), fixture[3], "Test 229: " .. fixture[1])
			answer(conn, "ok")
		end, function(ch)
			-- Keep the upload open: this tests a forbidden frame on a half-closed stream,
			-- rather than minimal processing after a fully completed response.
			local s = assert(assert(ch):request("GET", "/", {}))
			testaux.asserteq(s:readall(2000), nil, "Test 229: invalid stream cannot return a successful body")
			s:close()
			local nextstream<close> = get(ch)
			testaux.asserteq(nextstream:readall(2000), "ok", "Test 229: another stream survives the reset")
		end)
	end
	peer.withserver(function(s)
		if s:readall(2000) then assert(s:respond(200, {}, true)) end
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		assert(conn:write(frame(1, 5, 1, hpack.pack(encoder, {}, ":method", "GET", ":scheme", "http", ":path", "/"))
			.. frame(1, 5, 1, hpack.pack(encoder, {["x-late"] = "yes"}))))
		local reset = peer.untilframe(conn, 3)
		testaux.asserteq(string.unpack(">I4", reset.data), 5, "Test 229: server rejects HEADERS after request END_STREAM")
	end)
end)


testaux.case("Test 231: Invalid PRIORITY payloads cannot leave an active stream usable", function()
	for _, fixture in ipairs({
		{"short payload", string.rep("\0", 4), 6},
		{"self dependency", string.pack(">I4I1", 1, 0), 1},
		{"exclusive self dependency", string.pack(">I4I1", 0x80000001, 0), 1},
	}) do
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			assert(conn:write(frame(2, 0, request.id, fixture[2])))
			local failure
			repeat failure = assert(peer.read(conn)) until failure.type == 3 or failure.type == 7
			-- A stream error may be escalated to a connection error (RFC 9113 Section 5.4.1).
			local offset = failure.type == 3 and 1 or 5
			testaux.asserteq(string.unpack(">I4", failure.data, offset), fixture[3], "Test 231: " .. fixture[1])
			if failure.type == 3 then answer(conn, "ok") end
		end, function(ch)
			ch = assert(ch)
			local s = get(ch)
			local ok, err = s:waitresponse(2000)
			testaux.asserteq(ok, false, "Test 231: malformed priority wakes the active stream with failure")
			testaux.assertneq(err, nil, "Test 231: priority failure has a reason")
			s:close()
			if ch:isalive() then
				local nextstream<close> = get(ch)
				testaux.asserteq(nextstream:readall(2000), "ok", "Test 231: a stream-only error preserves the connection")
			end
		end)
	end
end)

testaux.case("Test 232: Client handshake preserves EOF and a closed transport write error", function()
	peer.withclient(function(conn)
		testaux.asserteq(conn:read(#peer.preface), peer.preface, "Test 232.1: client sent its preface")
		peer.untilframe(conn, 4)
	end, function(ch, err)
		testaux.asserteq(ch, nil, "Test 232.2: EOF before initial SETTINGS fails channel construction")
		testaux.asserteq(err, EEOF, "Test 232.3: initial SETTINGS read retains the transport EOF")
	end)
	local ready = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		ready:push(true)
		while true do
			local credit, err = peer.read(conn)
			if not credit then
				testaux.assertcontains(err, "EOF", "Test 232.4: closed transport reaches the peer")
				break
			end
			testaux.asserteq({credit.type, credit.id}, {8, 0}, "Test 232: only handshake connection credit may precede EOF")
		end
	end, function(ch)
		testaux.await(ready, "Test 232: peer completed the handshake before local transport close")
		local conn = assert(ch).conn
		conn:close()
		local nextchannel, err = h2.newchannel("http", conn, "example.test")
		testaux.asserteq(nextchannel, nil, "Test 232.5: an already closed transport cannot send the preface")
		testaux.asserteq(err, ECLOSED, "Test 232.6: constructor preserves the initial write failure")
	end)
end)

testaux.case("Test 233: Local GOAWAY before SETTINGS ACK still drains an accepted request", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}))
		s.channel:close()
		local body, err = s:readall(2000)
		testaux.asserteq(body, "body", err or "Test 233.1: request body survives local GOAWAY during handshake")
		assert(s:closewrite(body))
	end, function(conn)
		local request = hpack.pack(hpack.new(4096), {}, ":method", "POST", ":scheme", "http", ":path", "/")
		assert(conn:write(peer.preface .. frame(4, 0, 0) .. frame(1, 4, 1, request)))
		local goaway = peer.untilframe(conn, 7)
		testaux.asserteq(string.unpack(">I4", goaway.data, 5), 0, "Test 233.2: local close sends graceful GOAWAY")
		assert(conn:write(frame(6, 0, 0, "go-local")))
		testaux.asserteq(peer.untilframe(conn, 6).data, "go-local", "Test 233.3: handshake yields to drain before peer SETTINGS ACK")
		assert(conn:write(frame(4, 1, 0) .. frame(0, 1, 1, "body")))
		testaux.asserteq(peer.untilframe(conn, 0).data, "body", "Test 233.4: accepted request receives its complete response")
	end)
end)


testaux.case("Test 234: Reset request HEADERS still update HPACK without reopening the stream", function()
	peer.withserver(function(s)
		if s.path == "/held" then
			local body, err = s:readall(2000)
			testaux.asserteq(body, nil, "Test 234.1: peer reset stops the first request")
			testaux.asserteq(err, "Stream cancelled", "Test 234.2: later HEADERS do not replace the reset reason")
		else
			testaux.asserteq(s.header["x-indexed"], "after-reset", "Test 234.3: discarded HEADERS retain shared HPACK state")
			assert(s:respond(200, {}, true))
		end
	end, function(conn)
		peer.clienthandshake(conn)
		local encoder = hpack.new(4096)
		local first = hpack.pack(encoder, {}, ":method", "POST", ":scheme", "http", ":path", "/held")
		local discarded = hpack.pack(encoder, {["x-indexed"] = "after-reset"})
		assert(conn:write(frame(1, 4, 1, first) .. frame(3, 0, 1, string.pack(">I4", 8))
			.. frame(1, 5, 1, discarded) .. frame(6, 0, 0, "rst-done")))
		while true do
			local reply = assert(peer.read(conn))
			testaux.assertneq(reply.type, 3, "Test 234.4: reset request is not reset a second time")
			if reply.type == 6 then break end
		end
		assert(conn:write(frame(1, 5, 3, hpack.pack(encoder, {["x-indexed"] = "after-reset"},
			":method", "GET", ":scheme", "http", ":path", "/next"))))
		testaux.asserteq(peer.untilframe(conn, 1).id, 3, "Test 234.5: indexed fields on the next request remain decodable")
	end)
end)


testaux.case("Test 235: Unknown frames and PING can precede SETTINGS ACK on both endpoints", function()
	peer.withclient(function(conn)
		testaux.asserteq(conn:read(#peer.preface), peer.preface, "Test 235.1: client sends its preface")
		peer.untilframe(conn, 4)
		assert(conn:write(frame(4, 0, 0)))
		testaux.asserteq(peer.untilframe(conn, 4).flags, 1, "Test 235.2: client acknowledges initial settings")
		assert(conn:write(frame(0xfe, 0, 0, "ignored") .. frame(6, 0, 0, "hs-ping!")))
		testaux.asserteq(peer.untilframe(conn, 6).data, "hs-ping!", "Test 235.3: client handles PING before peer SETTINGS ACK")
		assert(conn:write(frame(4, 1, 0)))
		local request = peer.untilframe(conn, 1)
		assert(conn:write(frame(0xfe, 0, 0, "ignored")
			.. frame(4, 0, 0, string.pack(">I2I4", 4, 65535))
			.. peer.headers(hpack.new(4096), request.id, "200")))
		testaux.asserteq(peer.untilframe(conn, 4).flags, 1, "Test 235.4: unchanged initial window is still acknowledged")
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "", "Test 235.5: unknown frames do not obstruct the response")
	end)
	peer.withserver(function(s)
		assert(s:respond(200, {}, true))
	end, function(conn)
		assert(conn:write(peer.preface .. frame(4, 0, 0)))
		testaux.asserteq(peer.untilframe(conn, 4).flags, 0, "Test 235.6: server sends its initial settings")
		testaux.asserteq(peer.untilframe(conn, 4).flags, 1, "Test 235.7: server acknowledges peer settings")
		assert(conn:write(frame(0xfe, 0, 0, "ignored") .. frame(6, 0, 0, "hs-ping!")))
		testaux.asserteq(peer.untilframe(conn, 6).data, "hs-ping!", "Test 235.8: server handles PING before peer SETTINGS ACK")
		local request = hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/")
		assert(conn:write(frame(4, 1, 0) .. frame(0xfe, 0, 0, "ignored") .. frame(1, 5, 1, request)))
		testaux.asserteq(peer.untilframe(conn, 1).id, 1, "Test 235.9: unknown frames do not obstruct the request")
	end)
end)

testaux.case("Test 236: Local close after peer GOAWAY finishes an accepted server stream", function()
	peer.withserver(function(s)
		assert(s:respond(200, {}, true))
		s.channel:close()
	end, function(conn)
		peer.clienthandshake(conn)
		local request = hpack.pack(hpack.new(4096), {}, ":method", "GET", ":scheme", "http", ":path", "/")
		assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", 0, 0)) .. frame(1, 5, 1, request)))
		local responded = false
		while true do
			local reply = assert(peer.read(conn))
			if reply.type == 1 then
				responded = reply.id == 1 and reply.flags & 1 ~= 0
			elseif reply.type == 7 then
				local last, code = string.unpack(">I4I4", reply.data)
				testaux.asserteq({last, code}, {1, 0}, "Test 236.1: local graceful GOAWAY covers the accepted request")
				break
			end
		end
		testaux.asserteq(responded, true, "Test 236.2: response finishes before locally closing a remote-only GOAWAY channel")
	end)
end)


-- Active client PING keepalive regressions.

testaux.case("Test 61: Client keepalive probes without streams and matches ACK", function()
	local probes_done = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		for _ = 1, 2 do
			local ping = peer.untilframe(conn, 6)
			testaux.asserteq(ping.id, 0, "connection PING")
			testaux.asserteq(#ping.data, 8, "eight-byte token")
			assert(conn:write(frame(6, 1, 0, ping.data)))
		end
		probes_done:push(true)
		answer(conn, "ok")
	end, function(ch)
		testaux.await(probes_done, "two idle probes acknowledged")
		local s<close> = get(assert(ch))
		testaux.asserteq(s:readall(2000), "ok", "channel survives ACKs while idle")
	end, {keep_alive_interval = 30, keep_alive_timeout = 300, keep_alive_while_idle = true})
end)

testaux.case("Test 62: Client PING timeout wakes readers and initial HEADERS waiters", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4", 3, 1))
		peer.untilframe(conn, 6)
		testaux.asserteq(peer.read(conn), nil, "client closes on PING timeout")
	end, function(ch)
		local s<close> = get(assert(ch))
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			local stream, err = ch:request("GET", "/", {}, true)
			if stream then
				stream:close()
			end
			done:push({cause = err})
		end)
		testaux.await(started, "initial HEADERS waiter started before PING timeout")
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "reader fails on PING timeout")
		testaux.asserteq(err, "PING timeout", "specific timeout cause")
		local cause = testaux.await(done, "initial HEADERS writer wakes on PING timeout").cause
		testaux.asserteq(cause, "PING timeout", "initial HEADERS timeout cause")
	end, {keep_alive_interval = 30, keep_alive_timeout = 50})
end)

testaux.case("Test 63: Wrong ACK and other frames do not complete a pending PING", function()
	local probe_seen, send_frames, processed = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local ping = peer.untilframe(conn, 6)
		probe_seen:push(ping.data)
		testaux.await(send_frames, "pending probe captured")
		assert(conn:write(frame(6, 1, 0, "wrongACK") .. frame(0xfe, 0, 0) .. frame(6, 0, 0, "activity")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq(ack.data, "activity", "PING barrier follows wrong ACK and other frame")
		processed:push(true)
		testaux.asserteq(peer.read(conn), nil, "peer observes PING timeout EOF")
	end, function(ch, err, observer)
		local token = testaux.await(probe_seen, "peer received pending probe")
		send_frames:push(true)
		testaux.await(processed, "wrong ACK and other frame processed")
		testaux.asserteq(assert(ch).pingtoken, token, "unrelated frames leave probe pending")
		observer:waitclosed()
		testaux.asserteq(ch:isalive(), false, "wrong ACK cannot complete probe")
		testaux.asserteq(ch.errstr, "PING timeout", "pending probe fails before peer closes")
	end, {keep_alive_interval = 30, keep_alive_timeout = 300, keep_alive_while_idle = true})
end)

testaux.case("Test 65: Received frames postpone keepalive", function()
	local ready = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local ch = testaux.await(ready, "client channel ready")
		local function activity()
			assert(conn:write(frame(0xfe, 0, 0) .. frame(6, 0, 0, "activity")))
			while true do
				local incoming = peer.untilframe(conn, 6)
				if incoming.flags & 1 ~= 0 then
					testaux.asserteq(incoming.data, "activity", "activity barrier processed")
					return
				end
				-- A slow runner may legitimately become idle between inputs.
				assert(conn:write(frame(6, 1, 0, incoming.data)))
			end
		end
		for _ = 1, 6 do
			activity()
			testaux.elapse(20)
		end
		activity()
		-- Drain any probe queued before the last activity barrier.
		while ch.pingtoken do
			local pending = peer.untilframe(conn, 6)
			assert(conn:write(frame(6, 1, 0, pending.data)))
			activity()
		end
		local lastrecvtime = ch.lastrecvtime
		local ping = peer.untilframe(conn, 6)
		testaux.asserteq(time.monotonic() - lastrecvtime >= 60, true, "probe follows a full idle interval after processed activity")
		assert(conn:write(frame(6, 1, 0, ping.data)))
	end, function(ch)
		ready:push(assert(ch))
	end, {keep_alive_interval = 60, keep_alive_timeout = 1000, keep_alive_while_idle = true})
end)

testaux.case("Test 67: PING works with exhausted connection and stream windows", function()
	local received = false
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		local bytes = 0
		while bytes < 65535 do
			bytes = bytes + #peer.untilframe(conn, 0).data
		end
		local ping = peer.untilframe(conn, 6)
		assert(conn:write(frame(6, 1, 0, ping.data) .. frame(6, 0, 0, "zero-win")))
		local ack = peer.untilframe(conn, 6)
		testaux.asserteq({ack.flags, ack.data}, {1, "zero-win"}, "ACK also bypasses exhausted windows")
		received = true
		assert(conn:write(frame(8, 0, 0, string.pack(">I4", 1)) .. frame(8, 0, request.id, string.pack(">I4", 1))))
		testaux.asserteq(peer.untilframe(conn, 0).data, "b", "DATA resumes with both windows restored")
	end, function(ch)
		local s<close> = assert(assert(ch):request("POST", "/", {}))
		assert(s:write(string.rep("a", 65535)))
		assert(s:closewrite("b"))
		testaux.asserteq(received, true, "PING bypassed flow control")
	end, {keep_alive_interval = 30, keep_alive_timeout = 500})
end)

testaux.case("Test 68: PING does not split outgoing HEADERS and CONTINUATION", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local request = peer.untilframe(conn, 1)
		while request.flags & 4 == 0 do
			request = assert(peer.read(conn))
			testaux.asserteq(request.type, 9, "header block stays contiguous")
		end
		local ping = peer.untilframe(conn, 6)
		assert(conn:write(frame(6, 1, 0, ping.data)))
		assert(conn:write(peer.headers(hpack.new(4096), request.id, "200")))
	end, function(ch)
		local s<close> = assert(assert(ch):request("GET", "/", {["x-large"] = string.rep("abcdef0123456789", 2500)}))
		assert(s:closewrite())
		testaux.asserteq(s:waitresponse(2000), true, "fragmented request survives probe")
	end, {keep_alive_interval = 30, keep_alive_timeout = 500})
end)

testaux.case("Test 69: Closing channel cancels all keepalive timers", function()
	local snapshot = time._dump().timer_user_data
	local captured
	local ping_seen = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		peer.untilframe(conn, 6)
		ping_seen:push(true)
		peer.untilframe(conn, 7)
	end, function(ch)
		captured = assert(ch)
		testaux.await(ping_seen, "keepalive probe pending")
		ch:close()
	end, {keep_alive_interval = 30, keep_alive_timeout = 500, keep_alive_while_idle = true})
	for _, user_data in pairs(snapshot) do
		testaux.assertneq(user_data, captured, "no timer retains closed channel")
	end
end)

testaux.case("Test 91: Keepalive can be enabled and disabled on an established channel", function()
	local pending = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local ping = peer.untilframe(conn, 6)
		pending:push(ping.data)
		local request = peer.untilframe(conn, 1)
		-- An ACK for the cancelled probe must not re-enable probing.
		assert(conn:write(frame(6, 1, 0, ping.data)
			.. peer.headers(hpack.new(4096), request.id, "200", {}, 4)
			.. frame(0, 1, request.id, "ok")))
	end, function(ch)
		ch = assert(ch)
		ch.lastrecvtime = time.monotonic() - 1000
		ch:keepalive(30, 1000, true)
		testaux.asserteq(ch.keepaliveinterval, 30, "method enables active probes")
		local token = testaux.await(pending, "peer received the enabled probe")
		testaux.asserteq(ch.pingtoken, token, "probe is outstanding before disabling")
		ch:keepalive(0, 1000)
		testaux.asserteq(ch.pingtoken, nil, "disabling cancels the outstanding probe")
		testaux.asserteq(ch.timer, nil, "disabled idle channel has no scheduled timer")
		local s<close> = get(ch)
		testaux.asserteq(s:readall(2000), "ok", "channel remains usable after disabling")
		testaux.asserteq(ch.keepaliveinterval, nil, "late ACK leaves probing disabled")
	end)
end)

testaux.case("Test 92: Keepalive normalizes nonpositive timeouts and defaults only enabled probes", function()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		answer(conn, "ok")
	end, function(ch)
		ch = assert(ch)
		testaux.asserteq(ch.keepaliveinterval, nil, "new channels have no receive interval")
		testaux.asserteq(ch.keepalivetimeout, nil, "new channels have no ACK timeout")
		for _, timeout in ipairs({0, -1, 1000}) do
			ch:keepalive(60000, timeout)
			testaux.asserteq(ch.keepaliveinterval, 60000, "positive receive interval is preserved")
			testaux.asserteq(ch.keepalivetimeout, timeout > 0 and timeout or 15000,
				"enabled probes default nonpositive ACK timeouts")
		end
		ch:keepalive(60000)
		testaux.asserteq(ch.keepalivetimeout, 15000, "enabled probes default an omitted ACK timeout")
		ch:keepalive(nil, 1234)
		testaux.asserteq(ch.keepaliveinterval, nil, "nil receive interval disables probes")
		testaux.asserteq(ch.keepalivetimeout, 1234, "specified positive ACK timeout is preserved")
		testaux.asserteq(ch.timer, nil, "disabling probes cancels the timer")
		for _, interval in ipairs({0, -1}) do
			ch:keepalive(interval, interval)
			testaux.asserteq(ch.keepaliveinterval, nil, "nonpositive receive interval becomes nil")
			testaux.asserteq(ch.keepalivetimeout, nil, "disabled probes do not populate the ACK default")
			testaux.asserteq(ch.timer, nil, "nonpositive interval leaves no timer")
		end
		ch:keepalive()
		testaux.asserteq(ch.keepaliveinterval, nil, "omitted arguments disable probing")
		testaux.asserteq(ch.keepalivetimeout, nil, "omitted arguments leave no ACK timeout")
		testaux.asserteq(ch:isalive(), true, "reconfiguration preserves the connection")
		local s<close> = get(ch)
		testaux.asserteq(s:readall(2000), "ok", "channel remains usable after reconfiguration")
	end)
end)

testaux.case("Test 93: Disabling keepalive preserves an active stream read deadline", function()
	local pending, done = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		peer.untilframe(conn, 1)
		peer.untilframe(conn, 6)
		pending:push(true)
		while peer.read(conn) do
		end
	end, function(ch)
		ch = assert(ch)
		ch:keepalive(30, 1000)
		local s<close> = get(ch)
		task.fork(function()
			local ok, err = s:waitresponse(150)
			done:push({ok = ok, err = err})
		end)
		testaux.await(pending, "probe was sent while the response reader was waiting")
		testaux.assertneq(s.readco, nil, "reader is registered before disabling probes")
		ch:keepalive(0, 1000)
		testaux.asserteq(ch.timer, nil, "disabling probes cancels only the channel timer")
		local result = testaux.await(done, "response deadline survives disabling probes")
		testaux.asserteq(result.ok, false, "response reader still times out")
		testaux.assertneq(result.err, nil, "read deadline reports an error")
		testaux.asserteq(ch:isalive(), true, "read timeout leaves the channel alive")
		ch:close()
	end)
end)

testaux.case("Test 102: Keepalive maintains at most one live channel timer through ACK and close", function()
	local after, cancel = time.after, time.cancel
	local pending, peak = {}, 0
	time.after = function(delay, fn, arg, ...)
		if type(arg) ~= "table" then
			return after(delay, fn, arg, ...)
		end
		local owner = arg.sendhpack and arg
		if not owner then
			return after(delay, fn, arg, ...)
		end
		local id
		id = after(delay, function(...)
			pending[id] = nil
			return fn(...)
		end, arg, ...)
		pending[id] = owner
		local count = 0
		for _, ch in pairs(pending) do
			if ch == owner then
				count = count + 1
			end
		end
		peak = math.max(peak, count)
		return id
	end
	time.cancel = function(id)
		pending[id] = nil
		return cancel(id)
	end
	local finished = channel.new()
	local ok, err = pcall(function()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			for _ = 1, 3 do
				local ping = peer.untilframe(conn, 6)
				assert(conn:write(frame(6, 1, 0, ping.data)))
			end
			finished:push(true)
			while peer.read(conn) do
			end
		end, function(ch)
			local s<close> = get(assert(ch))
			local response, cause = s:waitresponse(40)
			testaux.asserteq(response, false, "read deadline expires independently of PING ACKs")
			testaux.assertneq(cause, nil, "read timeout provides an error")
			testaux.asserteq(ch:isalive(), true, "read timeout leaves the healthy channel alive")
			testaux.await(finished, "three independent probe exchanges completed")
			assert(ch):close()
		end, {keep_alive_interval = 30, keep_alive_timeout = 1000})
	end)
	time.after, time.cancel = after, cancel
	if not ok then
		error(err, 0)
	end
	testaux.asserteq(peak, 1, "only one scheduled health timer per channel")
	testaux.asserteq(next(pending), nil, "closing clears the scheduled timer")
end)

testaux.case("Test 110: Matching ACK restarts idle timing without polling the pending probe", function()
	local after, cancel, monotonic = time.after, time.cancel, time.monotonic
	local captured, serial, cancelled = nil, 0, 0
	local now, pending = monotonic(), {}
	local probes, ackgate, activitygate = channel.new(), channel.new(), channel.new()
	local wronggate, wrongdone = channel.new(), channel.new()
	local requested = channel.new()
	local acked, active, goawaygate, finish = channel.new(), channel.new(), channel.new(), channel.new()
	time.monotonic = function()
		return now
	end
	time.after = function(delay, fn, arg, ...)
		if not captured or arg ~= captured then
			return after(delay, fn, arg, ...)
		end
		serial = serial - 1
		pending[serial] = {delay = delay, deadline = now + delay, fn = fn, arg = arg}
		return serial
	end
	time.cancel = function(id)
		if pending[id] then
			pending[id] = nil
			cancelled = cancelled + 1
			return
		end
		return cancel(id)
	end
	local function fire(id)
		local timer = assert(pending[id], "expected a scheduled channel timer")
		pending[id] = nil
		timer.fn(timer.arg)
	end
	local ok, err = pcall(function()
		peer.withclient(function(conn)
			peer.serverhandshake(conn)
			local request = peer.untilframe(conn, 1)
			requested:push(true)
			local first = peer.untilframe(conn, 6)
			probes:push(first.data)
			testaux.await(wronggate, "release unmatched ACK", 2000)
			assert(conn:write(frame(6, 1, 0, "wrongACK") .. frame(6, 0, 0, "bad-done")))
			testaux.asserteq(peer.untilframe(conn, 6).data, "bad-done", "unmatched ACK processed")
			wrongdone:push(true)
			testaux.await(ackgate, "release matching ACK", 2000)
			assert(conn:write(frame(6, 1, 0, first.data) .. frame(6, 1, 0, first.data)
				.. frame(6, 0, 0, "ack-done")))
			testaux.asserteq(peer.untilframe(conn, 6).data, "ack-done", "matching ACK processed")
			acked:push(true)
			testaux.await(activitygate, "release receive activity", 2000)
			assert(conn:write(frame(6, 0, 0, "activity")))
			testaux.asserteq(peer.untilframe(conn, 6).data, "activity", "receive time updated")
			active:push(true)
			local second = peer.untilframe(conn, 6)
			probes:push(second.data)
			testaux.await(goawaygate, "release graceful GOAWAY", 2000)
			assert(conn:write(frame(7, 0, 0, string.pack(">I4I4", request.id, 0))))
			testaux.await(finish, "finish accepted response", 2000)
			assert(conn:write(frame(6, 1, 0, second.data)
				.. peer.headers(hpack.new(4096), request.id, "200")))
			while peer.read(conn) do
			end
		end, function(ch, _, observer)
			captured = assert(ch)
			local s = get(ch)
			testaux.await(requested, "request received before probing")
			ch:keepalive(100, 500)
			testaux.asserteq(pending[ch.timer].delay, 100, "initial idle timer")
			local previous = ch.timer
			now = now + 20
			ch:keepalive(60, 500)
			testaux.asserteq(pending[previous], nil, "shorter interval cancels the old timer")
			testaux.asserteq(pending[ch.timer].delay, 40, "shorter interval uses elapsed receive idle time")
			previous = ch.timer
			now = now + 10
			ch:keepalive(200, 500)
			testaux.asserteq(pending[previous], nil, "longer interval replaces the old timer")
			testaux.asserteq(pending[ch.timer].delay, 170, "longer interval preserves elapsed idle time")
			ch:keepalive(10, 500)
			testaux.asserteq(pending[ch.timer].delay, -20, "elapsed receive interval passes through to time.after")
			ch:keepalive(100, 500)
			testaux.asserteq(pending[ch.timer].delay, 70, "reconfiguration never resets the receive clock")
			local count = 0
			for _ in pairs(pending) do
				count = count + 1
			end
			testaux.asserteq(count, 1, "reconfiguration leaves exactly one timer")
			cancelled = 0
			now = now + 70
			fire(ch.timer)
			local token = testaux.await(probes, "first probe sent")
			local timer = ch.timer
			testaux.asserteq(pending[timer].delay, 500, "pending probe waits only for the ACK deadline")
			now = now + 200
			wronggate:push(true)
			testaux.await(wrongdone, "unmatched ACK handled")
			testaux.asserteq(ch.timer, timer, "unmatched ACK and receive activity leave the ACK timer alone")
			testaux.asserteq(ch.pingtoken, token, "unmatched ACK leaves the probe outstanding")
			testaux.asserteq(pending[timer].deadline, now + 300,
				"receive activity never extends the ACK deadline")
			now = now + 100
			ackgate:push(true)
			testaux.await(acked, "matching ACK handled")
			testaux.asserteq(pending[timer], nil, "matching ACK cancels the old ACK timer")
			testaux.assertneq(ch.timer, timer, "matching ACK schedules the next idle check")
			testaux.asserteq(pending[ch.timer].delay, 100, "idle interval starts from ACK receive time")
			testaux.asserteq(cancelled, 1, "duplicate ACK does not reset the timer twice")
			testaux.asserteq(ch.pingtoken, nil, "ACK completes the outstanding probe")
			timer = ch.timer
			now = now + 50
			activitygate:push(true)
			testaux.await(active, "receive activity handled")
			testaux.asserteq(ch.timer, timer, "ordinary receive activity leaves the idle timer alone")
			now = now + 50
			fire(timer)
			testaux.asserteq(ch.pingtoken, nil, "early callback does not probe an active connection")
			testaux.asserteq(pending[ch.timer].delay, 50, "callback adapts to the later receive time")
			now = now + 50
			fire(ch.timer)
			testaux.assertneq(testaux.await(probes, "second probe sent"), token, "next probe uses a new token")
			timer = ch.timer
			goawaygate:push(true)
			observer:waituntil(function()
				return ch.goaway ~= 0
			end, "graceful GOAWAY processed")
			testaux.asserteq(ch.timer, timer, "GOAWAY leaves the pending timer alone")
			testaux.asserteq(cancelled, 1, "only the matching ACK cancels a timer")
			finish:push(true)
			testaux.asserteq(s:readall(2000), "", "accepted response survives graceful shutdown")
			testaux.asserteq(ch.timer, nil, "completed GOAWAY drain cancels the health timer")
			testaux.asserteq(ch.errstr, "Graceful shutdown", "healthy draining connection preserves its close reason")
			s:close()
		end)
	end)
	time.after, time.cancel, time.monotonic = after, cancel, monotonic
	if not ok then
		error(err, 0)
	end
	testaux.asserteq(next(pending), nil, "no synthetic channel timer remains")
end)

testaux.case("Test 237: A pending PING timeout still fails an active stream during local drain", function()
	local probing = channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		peer.untilframe(conn, 1)
		peer.untilframe(conn, 6)
		probing:push(true)
		peer.untilframe(conn, 7)
		testaux.asserteq(peer.read(conn), nil, "Test 237.1: failed probe closes the draining connection")
	end, function(ch)
		local s<close> = get(assert(ch))
		testaux.await(probing, "Test 237: probe is outstanding before local close")
		ch:close()
		local ok, err = s:waitresponse(2000)
		testaux.asserteq(ok, false, "Test 237.2: draining reader is released")
		testaux.asserteq(err, "PING timeout", "Test 237.3: drain does not suppress probe failure")
		testaux.asserteq(ch.streamcount, 0, "Test 237.4: failed stream releases its slot")
	end, {keep_alive_interval = 30, keep_alive_timeout = 60})
end)

testaux.case("Test 238: A late ACK completes the pending probe without restarting an idle channel", function()
	local release, acknowledged = channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local ping = peer.untilframe(conn, 6)
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200", {}, 4)
			.. frame(0, 1, first.id, "complete")))
		testaux.await(release, "Test 238: completed stream still owns its pending probe")
		assert(conn:write(frame(6, 1, 0, ping.data) .. frame(6, 0, 0, "ack-done")))
		local barrier = peer.untilframe(conn, 6)
		testaux.asserteq({barrier.flags, barrier.data}, {1, "ack-done"}, "Test 238.1: ACK was processed")
		acknowledged:push(true)
		answer(conn, "next")
	end, function(ch)
		local first<close> = get(assert(ch))
		testaux.asserteq(first:readall(2000), "complete", "Test 238.2: response completes before probe ACK")
		testaux.asserteq(ch.streamcount, 0, "Test 238.3: completed object is not protocol activity")
		testaux.assertneq(ch.pingtoken, nil, "Test 238.4: completion preserves the outstanding probe")
		release:push(true)
		testaux.await(acknowledged, "Test 238: late ACK reached the client")
		testaux.asserteq(ch.pingtoken, nil, "Test 238.5: ACK clears the token")
		testaux.asserteq(ch.timer, nil, "Test 238.6: ACK does not restart idle probing")
		local second<close> = get(ch)
		testaux.asserteq(second:readall(2000), "next", "Test 238.7: the next request remains usable")
		ch:close()
	end, {keep_alive_interval = 30, keep_alive_timeout = 1000})
end)

testaux.case("Test 239: Completed objects survive late frames while HPACK stays synchronized", function()
	local completed, release, processed = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn)
		local first = peer.untilframe(conn, 1)
		local encoder = hpack.new(4096)
		assert(conn:write(peer.headers(encoder, first.id, "200", {}, 4)
			.. frame(0, 1, first.id, "retained") .. frame(6, 0, 0, "complete")))
		peer.untilframe(conn, 6)
		completed:push(true)
		testaux.await(release, "Test 239: completed owner is still retained")
		assert(conn:write(peer.headers(encoder, first.id, "200", {["x-late"] = "indexed"})
			.. frame(0, 0, first.id, "discard") .. frame(6, 0, 0, "late-old")))
		local barrier = peer.untilframe(conn, 6)
		testaux.asserteq({barrier.flags, barrier.data}, {1, "late-old"}, "Test 239.1: late frames were processed")
		processed:push(true)
		local second = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(encoder, second.id, "200", {["x-late"] = "indexed"}, 4)
			.. frame(0, 1, second.id, "next")))
	end, function(ch)
		local first<close> = get(assert(ch))
		testaux.await(completed, "Test 239: first response ended on the protocol")
		testaux.asserteq(first.closed, true, "Test 239.2: completion unregisters before owner close")
		release:push(true)
		testaux.await(processed, "Test 239: late stream frames consumed")
		testaux.asserteq(first:readall(2000), "retained", "Test 239.3: late DATA cannot alter completed data")
		local second<close> = get(ch)
		testaux.asserteq(second:readall(2000), "next", "Test 239.4: another stream still decodes")
		testaux.asserteq(second.header["x-late"], "indexed", "Test 239.5: closed HEADERS updated HPACK")
		ch:close()
	end)
end)

testaux.case("Test 240: SETTINGS finishes window updates before admitting queued requests", function()
	local started, queued, release = channel.new(), channel.new(), channel.new()
	local written, admitted, paused = channel.new(), channel.new(), channel.new()
	peer.withclient(function(conn)
		peer.serverhandshake(conn, string.pack(">I2I4I2I4", 3, 1, 4, 0))
		local first = peer.untilframe(conn, 1)
		assert(conn:write(peer.headers(hpack.new(4096), first.id, "200", {})))
		testaux.await(started, "Test 240: final writer is blocked")
		testaux.await(queued, "Test 240: next request is queued")
		-- Resuming the last DATA must not admit a request before the later limit applies.
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4I2I4", 4, 1, 3, 0))))
		local data, ack
		while not data or not ack do
			local incoming = assert(peer.read(conn))
			testaux.assertneq(incoming.type, 1, "Test 240.2: no request bypasses the lowered limit")
			if incoming.type == 0 then
				data = incoming
			elseif incoming.type == 4 and incoming.flags == 1 then
				ack = incoming
			end
		end
		testaux.asserteq({data.id, data.data, data.flags}, {first.id, "a", 1},
			"Test 240.1: SETTINGS completes the blocked final DATA")
		paused:push(true)
		testaux.await(release, "Test 240: zero concurrency keeps admission queued")
		assert(conn:write(frame(4, 0, 0, string.pack(">I2I4", 3, 1))))
		local second = peer.untilframe(conn, 1)
		local body = peer.untilframe(conn, 0)
		testaux.asserteq({body.id, body.data, body.flags}, {second.id, "b", 1},
			"Test 240.3: admitted stream sends within its new initial window")
		assert(conn:write(peer.headers(hpack.new(4096), second.id, "200", {})))
	end, function(ch)
		ch = assert(ch)
		local first<close> = assert(ch:request("POST", "/", {}))
		assert(first:waitresponse(2000))
		task.fork(function()
			started:push(true)
			local ok, err = first:closewrite("a")
			written:push({ok = ok, err = err})
		end)
		task.fork(function()
			queued:push(true)
			local stream, err = ch:request("POST", "/", {}, false, 2000)
			admitted:push({stream = stream, err = err})
		end)
		testaux.await(paused, "Test 240: SETTINGS was acknowledged")
		local result = testaux.await(written, "Test 240: writer completed")
		testaux.asserteq(result.ok, true, "Test 240.4: final writer succeeds")
		testaux.asserteq(ch.streamcount, 0, "Test 240.5: completed stream returns its slot")
		testaux.asserteq(ch.openwaitq:size(), 1, "Test 240.6: lowered limit preserves queued admission")
		release:push(true)
		local nextresult = testaux.await(admitted, "Test 240: raised limit admits next request")
		local second<close> = assert(nextresult.stream, nextresult.err)
		testaux.asserteq(second.sendwindow, 1, "Test 240.7: new stream receives initial credit only once")
		assert(second:closewrite("b"))
		testaux.asserteq(second:readall(2000), "", "Test 240.8: the next response completes")
		ch:close()
	end)
end)

testaux.case("Test 213: Go HTTP2 server ACKs Lua client keepalive during delayed response", function()
	local client = http.newclient({alpnprotos = {"h2"}, keep_alive_interval = 30, keep_alive_timeout = 100})
	goserver("slow_response", {chunks = {"al", "ive"}, delay_ms = 200}, function(url)
		local response, err = client:get(url)
		assert(response, err)
		testaux.asserteq(response.status, 200, "delayed Go response survives probes")
	end)
	client:close()
end)

end

httpc:close()
server:close()
c:close()
wait_readers()
