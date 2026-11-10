local silly = require "silly"
local websocket = require "silly.net.websocket"
local http = require "silly.net.http"
local env = require "silly.env"
local channel = require "silly.sync.channel"
local base64 = require "silly.encoding.base64"
local metrics = require "silly.metrics.c"
local testaux = require "test.testaux"
local conformance = require "test.conformance"
local pcall = silly.pcall
local errno = require "silly.errno"
local c = conformance.connect("127.0.0.1", tonumber(env.get("conf_port")) or 19090)

local function goserver(secure, params, fn)
	params.tls = secure
	params.cert = testaux.CERT_DEFAULT
	params.key = testaux.KEY_DEFAULT
	local info = assert(c:start_server("websocket", params))
	local ok, err = pcall(fn, (secure and "wss://" or "ws://") .. info.addr)
	assert(c:stop_server(info.server_id))
	assert(ok, err)
end

local invalid_frames = {
	{name = "RSV bit", wire = "\xc1\x01x", code = 1002},
	{name = "orphan continuation", wire = "\x80\x01x", code = 1002},
	{name = "fragmented Ping", wire = "\x09\x01p\x80\x00", code = 1002},
	{name = "oversized Ping", wire = "\x89\x7e\x00\x7e" .. string.rep("p", 126), code = 1002},
	{name = "nonminimal 16-bit length", wire = "\x81\x7e\x00\x01x", code = 1002},
	{name = "nonminimal 64-bit length", wire = "\x82\x7f\0\0\0\0\0\0\0\1x", code = 1002},
	{name = "64-bit length high bit", wire = "\x82\x7f\x80\0\0\0\0\0\0\0", code = 1002},
	{name = "length beyond transport range", wire = "\x82\x7f\0\0\0\0\x80\0\0\0", code = 1009},
	{name = "invalid UTF-8 text", wire = "\x81\x01\xff", code = 1007},
	{name = "one-byte Close", wire = "\x88\x01x", code = 1002},
	{name = "reserved Close status", wire = "\x88\x02\x03\xed", code = 1002},
	{name = "invalid Close reason", wire = "\x88\x03\x03\xe8\xff", code = 1007},
	{name = "new message within fragments", wire = "\x01\x01a\x82\x01b\x80\x01c", code = 1002},
	{name = "reserved opcode within fragments", wire = "\x01\x01a\x83\x01b", code = 1002},
}

for mode, secure in ipairs({false, true}) do
	local scheme = secure and "wss" or "ws"
	for i, spec in ipairs({
		{omit = "Upgrade"}, {omit = "Connection"}, {omit = "Sec-WebSocket-Accept"},
		{headers = {["Sec-WebSocket-Accept"] = "wrong"}},
		{headers = {Connection = "notupgrade"}},
		{headers = {["Sec-WebSocket-Extensions"] = "permessage-deflate"}},
		{headers = {["Sec-WebSocket-Protocol"] = "unsolicited"}},
	}) do
		testaux.case("Test 1." .. mode .. "." .. i .. ": Reject an invalid Go " .. scheme .. " handshake", function()
			goserver(secure, spec, function(url)
				local sock, err = websocket.connect(url)
				if sock then
					sock:close()
				end
				testaux.asserteq(sock, nil, "Invalid upgrade response cannot establish WebSocket")
				testaux.assertneq(err, nil, "Handshake rejection reports an error")
			end)
		end)
	end
	for i, spec in ipairs(invalid_frames) do
		testaux.case("Test 2." .. mode .. "." .. i .. ": Reject Go " .. scheme .. " " .. spec.name, function()
			goserver(secure, {frames = {base64.encode(spec.wire)}}, function(url)
				local sock = assert(websocket.connect(url))
				local ok, data, err = pcall(sock.read, sock)
				local alive = sock.conn and sock.conn:isalive()
				sock:close()
				testaux.asserteq(ok, true, "Malformed network input returns an error without throwing")
				testaux.asserteq(data, nil, "Malformed frames are not delivered as messages")
				testaux.assertneq(err, nil, "Frame rejection reports an error")
				testaux.assertneq(err, errno.EOF, "A protocol violation is rejected before transport EOF")
				testaux.asserteq(not alive, true, "A protocol failure closes the connection")
			end)
		end)
	end
	for i, spec in ipairs({
		{wire = "\x01\x01\xc3\x89\x01p\x80\x01\xa9", first = "p", kind = "ping", last = "é"},
		{wire = "\x81\x02ok\x82\x02\0\xff", first = "ok", kind = "text", last = "\0\xff", lastkind = "binary"},
	}) do
		testaux.case("Test 3." .. mode .. "." .. i .. ": Go " .. scheme .. " preserves consecutive message state", function()
			goserver(secure, {frames = {base64.encode(spec.wire)}}, function(url)
				local sock<close> = assert(websocket.connect(url))
				local first, kind = sock:read()
				local last, lastkind = sock:read()
				testaux.asserteq(first, spec.first, "First frame is preserved")
				testaux.asserteq(kind, spec.kind, "Control frames do not change the fragmented message type")
				testaux.asserteq(last, spec.last, "The following message preserves its bytes")
				testaux.asserteq(lastkind, spec.lastkind or "text", "The following message preserves its type")
			end)
		end)
	end
	local handler
	local listener = assert(http.listen {
		addr = "127.0.0.1:0", tls = secure,
		certs = {{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}},
		handler = function(stream)
			handler(stream)
		end,
	})
	local addr = metrics.socketstat(listener.fd).localaddr
	for i, spec in ipairs({
		{index = 1}, {index = 2}, {index = 3}, {index = 4},
		{index = 5, value = "Sec-WebSocket-Key: eA=="},
		{index = 3, value = "Connection: notupgrade"},
		{index = 2, value = "Upgrade: WebSocket", status = 101},
		{index = 3, value = "Connection: keep-alive\r\nConnection: Upgrade", status = 101},
		{index = 4, value = "Sec-WebSocket-Version: 12", status = 426},
		{index = 5, value = "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="},
		{index = 1, value = "Host: localhost\r\nHost: localhost"},
	}) do
		testaux.case("Test 4." .. mode .. "." .. i .. ": Validate a raw Go " .. scheme .. " opening request", function()
			local done = channel.new()
			handler = function(stream)
				local ok, sock, err = pcall(websocket.upgrade, stream)
				if ok and sock then
					sock:close()
				else
					stream:closewrite()
					stream.conn:close()
				end
				done:push({ok = ok, err = err})
			end
			local fields = {"Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
				"Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="}
			if spec.value then
				fields[spec.index] = spec.value
			else
				table.remove(fields, spec.index)
			end
			local response, err = c:websocketrequest({addr = addr, tls = secure,
				request = "GET / HTTP/1.1\r\n" .. table.concat(fields, "\r\n") .. "\r\n\r\n"})
			local result = testaux.await(done, "Go handshake is handled")
			assert(response, err)
			testaux.asserteq(result.ok, true, "Handshake fields do not cause Lua exceptions")
			testaux.asserteq(response.status, spec.status or 400, "The request receives the correct upgrade decision")
			if spec.status == 426 then
				testaux.asserteq(response.version, "13", "An unsupported version advertises the supported version")
			end
		end)
	end
	for i, spec in ipairs({
		{wire = "\xc1\x81\0\0\0\0x", code = 1002},
		{wire = "\x80\x81\0\0\0\0x", code = 1002},
		{wire = "\x89\xfe\x00\x7e\0\0\0\0", code = 1002},
		{wire = "\x82\xff\x80\0\0\0\0\0\0\0", code = 1002},
		{wire = "\x82\xff\0\0\0\0\x80\0\0\0", code = 1009},
		{wire = "\x81\x81\0\0\0\0\xff", code = 1007},
		{wire = "\x81\x01x", code = 1002},
	}) do
		testaux.case("Test 5." .. mode .. "." .. i .. ": Fail a malformed masked Go " .. scheme .. " frame", function()
			local done = channel.new()
			handler = function(stream)
				local sock = assert(websocket.upgrade(stream))
				local ok, data, err = pcall(sock.read, sock)
				sock:close()
				done:push({ok = ok, data = data, err = err})
			end
			local response, err = c:websocketrequest({addr = addr, tls = secure,
				frames = {base64.encode(spec.wire)}})
			local result = testaux.await(done, "Malformed Go frame is rejected")
			assert(response, err)
			testaux.asserteq(result.ok, true, "Protocol errors do not escape as exceptions")
			testaux.asserteq(result.data, nil, "No malformed payload is delivered")
			testaux.asserteq(response.opcode, 8, "The peer receives a Close frame")
			testaux.asserteq(response.close_code, spec.code, "The Close status matches the protocol failure")
			testaux.asserteq(response.masked, false, "Server Close frames remain unmasked")
		end)
	end
	testaux.case("Test 6." .. mode .. ": Go " .. scheme .. " Close ends message delivery", function()
		goserver(secure, {frames = {base64.encode("\x88\x02\x03\xe8\x81\x04late")}}, function(url)
			local sock<close> = assert(websocket.connect(url))
			local close, kind = sock:read()
			local data, err = sock:read()
			local ok, writeerr = sock:write("late", "text")
			testaux.asserteq(kind, "close", "A Close is delivered to its owner")
			testaux.asserteq(close, "\x03\xe8", "The Close status is preserved")
			testaux.asserteq(data, nil, "Data following a Close cannot become a new message")
			testaux.assertneq(err, nil, "Reads after Close report closure")
			testaux.asserteq(ok, false, "Writes after a received Close report closure")
			testaux.assertneq(writeerr, nil, "Writes after Close return an error")
		end)
	end)
	for i, spec in ipairs({
		{name = "single message boundary", wire = "\x82\x04abcd", limit = 4, reads = {{"abcd", "binary"}}},
		{name = "fragment boundary", wire = "\x02\x02ab\x80\x02cd", limit = 4, reads = {{"abcd", "binary"}}},
		{name = "reject before payload", wire = "\x82\x08", limit = 4, reject = true},
		{name = "reject extended length", wire = "\x82\x7e\x00\x7e", limit = 125, reject = true},
		{name = "fragment sum", wire = "\x02\x03abc\x80\x02", limit = 4, reject = true},
		{name = "control payload excluded", wire = "\x02\x02ab\x89\x7d" .. string.rep("p", 125) .. "\x80\x02cd",
			limit = 4, reads = {{string.rep("p", 125), "ping"}, {"abcd", "binary"}}},
		{name = "fragment sum across reads", wire = "\x02\x03abc\x89\x01p\x80\x02",
			limit = 4, reads = {{"p", "ping"}}, reject = true},
		{name = "reset for next message", wire = "\x82\x04abcd\x82\x04efgh", limit = 4,
			reads = {{"abcd", "binary"}, {"efgh", "binary"}}},
		{name = "empty fragments", wire = "\x02\x00\x00\x00\x80\x04abcd", limit = 4, reads = {{"abcd", "binary"}}},
		{name = "UTF-8 byte boundary", wire = "\x81\x03éa", limit = 3, reads = {{"éa", "text"}}},
		{name = "UTF-8 bytes exceed limit", wire = "\x81\x04éé", limit = 3, reject = true},
		{name = "nil disables", wire = "\x82\x04abcd", limit = 1, disable = true, reads = {{"abcd", "binary"}}},
		{name = "zero disables", wire = "\x82\x04abcd", limit = 1, disable = true, disabled = 0,
			reads = {{"abcd", "binary"}}},
		{name = "negative disables", wire = "\x82\x04abcd", limit = 1, disable = true, disabled = -1,
			reads = {{"abcd", "binary"}}},
		{name = "lower limit during fragments", wire = "\x02\x04abcd\x89\x01p", limit = 8,
			reads = {{"p", "ping"}}, lower = 3, reject = true},
		{name = "enable limit during fragments", wire = "\x02\x04abcd\x89\x01p", limit = 0,
			reads = {{"p", "ping"}}, lower = 3, reject = true},
	}) do
		testaux.case("Test 7." .. mode .. "." .. i .. ": Go " .. scheme .. " message limit " .. spec.name, function()
			goserver(secure, {frames = {base64.encode(spec.wire)}}, function(url)
				local sock<close> = assert(websocket.connect(url))
				sock:limit(spec.limit)
				if spec.disable then
					sock:limit(spec.disabled)
				end
				for _, want in ipairs(spec.reads or {}) do
					local data, kind = sock:read()
					testaux.asserteq(data, want[1], "Accepted frames retain their data within the message limit")
					testaux.asserteq(kind, want[2], "Message limits preserve data and control frame types")
				end
				if spec.lower then
					sock:limit(spec.lower)
				end
				if spec.reject then
					local data, err = sock:read()
					testaux.asserteq(data, nil, "An oversized message is not delivered")
					testaux.assertcontains(err, "Message", "Message size is rejected before waiting for absent payload")
					testaux.asserteq(sock.conn, nil, "An oversized message closes its transport")
				end
			end)
		end)
	end
	for i, spec in ipairs({
		{wire = "\x82\x88", code = 1009},
		{wire = "\x02\x83\0\0\0\0abc\x80\x82", code = 1009},
		{wire = "\x02\x82\0\0\0\0ab\x80\x82\0\0\0\0cd", data = "abcd"},
	}) do
		testaux.case("Test 8." .. mode .. "." .. i .. ": Go " .. scheme .. " observes the server message limit", function()
			local done = channel.new()
			handler = function(stream)
				local sock = assert(websocket.upgrade(stream))
				sock:limit(4)
				local data, kind = sock:read()
				if data then
					assert(sock:write(data, kind))
				end
				sock:close()
				done:push({data = data, kind = kind})
			end
			local response, err = c:websocketrequest({addr = addr, tls = secure,
				frames = {base64.encode(spec.wire)}})
			local result = testaux.await(done, "server message limit finishes the Go exchange")
			assert(response, err)
			if spec.code then
				testaux.asserteq(result.data, nil, "Oversized masked payload is not delivered")
				testaux.asserteq(response.opcode, 8, "Go receives a Close frame")
				testaux.asserteq(response.close_code, spec.code, "Go observes Close status 1009 before sending payload")
			else
				testaux.asserteq(result.data, spec.data, "A message exactly at the limit is accepted")
				testaux.asserteq(base64.decode(response.data), spec.data, "Go receives the accepted message")
			end
		end)
	end
	listener:close()
end
c:close()
