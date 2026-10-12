local silly = require "silly"
local pcall = silly.pcall
local tls = require "silly.net.tls"
local env = require "silly.env"
local http = require "silly.net.http"
local hpack = require "silly.http2.hpack"
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"
local testaux = require "test.testaux"
local conformance = require "test.conformance"

local _, wait_readers = testaux.track_connections(tls)
local c = conformance.connect("127.0.0.1", tonumber(env.get("conf_port")) or 19090)
local httpc = http.newclient({alpnprotos = {"h2"}, keepalive = {read_idle_timeout = 50, ping_timeout = 1000}})
local handler
local server = assert(http.listen {
	addr = "127.0.0.1:18084",
	tls = true,
	alpnprotos = {"h2"},
	certs = {{cert = testaux.CERT_DEFAULT, key = testaux.KEY_DEFAULT}},
	keepalive = {read_idle_timeout = 50, ping_timeout = 1000},
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
	if not ok then error(cause, 0) end
end

testaux.case("Go HTTP2 client decodes fragmented Lua response headers", function()
	local value = string.rep("0123456789abcdef", 2500)
	handler = function(s) s:respond(200, {["x-large"] = value}); s:closewrite("ok") end
	local response, err = c:http_request("GET", "https://127.0.0.1:18084/", {http2 = true})
	assert(response, err)
	testaux.asserteq(response.protocol, "HTTP/2.0", "Go confirms protocol version")
	testaux.asserteq(response.headers["x-large"], value, "Go reassembles CONTINUATION frames")
	testaux.asserteq(response.body, "ok", "fragmented response body")
end)

testaux.case("Lua HTTP2 client obeys Go small HPACK table across reused requests", function()
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

testaux.case("Go HPACK decoder agrees on same-block eviction", function()
	local wire = "\x40\x01a\x01b\x40\x01c\x01d\xbe"
	local decoded, err = c:hpack_decode({base64.encode(wire)}, 64)
	assert(decoded, err)
	local lua_headers = {}
	assert(hpack.unpack(hpack.new(64), wire, lua_headers))
	for i, field in ipairs(decoded[1]) do
		testaux.asserteq(lua_headers[i * 2 - 1], field.Name, "Go and Lua agree on indexed name")
		testaux.asserteq(lua_headers[i * 2], field.Value, "Go and Lua agree on indexed value")
	end
end)

testaux.case("Go HPACK decoder agrees on partial FIFO eviction and shrink", function()
	local first = "\x40\x01a\x01b\x40\x01c\x01d\x40\x01e\x01f"
	local second = "\xbf\x40\x01g\x01h\xc0"
	local third = "\x3f\x25\xbf\xbe"
	local expected = {
		{"a", "b", "c", "d", "e", "f"},
		{"c", "d", "g", "h", "c", "d"},
		{"e", "f", "g", "h"},
	}
	local function compare(blocks, headers)
		local encoded = {}
		for i, wire in ipairs(blocks) do encoded[i] = base64.encode(wire) end
		local decoded, err = c:hpack_decode(encoded, 102)
		assert(decoded, err)
		local decoder = hpack.new(102)
		for i, wire in ipairs(blocks) do
			local lua_headers = {}
			testaux.asserteq(hpack.unpack(decoder, wire, lua_headers), true, "Lua decodes Go-accepted block")
			testaux.asserteq(lua_headers, headers[i], "FIFO table gives expected Lua fields")
			local go_headers = {}
			for _, field in ipairs(decoded[i]) do
				go_headers[#go_headers + 1] = field.Name
				go_headers[#go_headers + 1] = field.Value
			end
			testaux.asserteq(go_headers, headers[i], "FIFO table gives expected Go fields")
		end
	end
	compare({first, second, third}, expected)
	local encoder = hpack.new(102)
	first = hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f")
	second = hpack.pack(encoder, nil, "a", "b", "g", "h", "c", "d", "e", "f", "g", "h")
	hpack.hardlimit(encoder, 68)
	third = hpack.pack(encoder, nil, "e", "f", "g", "h")
	local oversized = string.rep("x", 103)
	local fourth = hpack.pack(encoder, nil, "large", oversized, "g", "h")
	compare({first, second, third, fourth}, {
		expected[1],
		{"a", "b", "g", "h", "c", "d", "e", "f", "g", "h"},
		expected[3],
		{"large", oversized, "g", "h"},
	})
end)

testaux.case("Go HPACK decoder accepts Lua shrink and grow updates", function()
	local encoder = hpack.new(4096)
	local blocks = {base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))}
	hpack.hardlimit(encoder, 0)
	blocks[2] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	hpack.hardlimit(encoder, 128)
	blocks[3] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	blocks[4] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	local decoded, err = c:hpack_decode(blocks, 4096)
	assert(decoded, err)
	for _, fields in ipairs(decoded) do
		testaux.asserteq(fields[1].Name, "x-cache", "Go name after resizing")
		testaux.asserteq(fields[1].Value, "value", "Go value after resizing")
	end
end)

testaux.case("Lua client handles Go HTTP2 information response and trailers", function()
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
	end)
end)

testaux.case("Go HTTP2 client and Lua server exchange large flow-controlled body", function()
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

testaux.case("Go HTTP2 peer ACKs Lua keepalive during delayed response", function()
	goserver("slow_response", {chunks = {"al", "ive"}, delay_ms = 200}, function(url)
		local response, err = httpc:get(url)
		assert(response, err)
		testaux.asserteq(response.status, 200, "delayed Go response survives probes")
	end)
	handler = function(s) testaux.elapse(200); s:respond(200, {}); s:closewrite("alive") end
	local response, err = c:http_request("GET", "https://127.0.0.1:18084/", {http2 = true})
	assert(response, err)
	testaux.asserteq(response.body, "alive", "Go ACKs server probes while waiting")
end)


testaux.case("Go HPACK decoder agrees with RFC and nghttp2 golden sequences", function()
	local file = assert(io.open("test/data/hpack.json", "rb"))
	local data = file:read("a")
	file:close()
	local fixtures = assert(json.decode(data))
	for _, story in ipairs(fixtures.stories) do
		local blocks = {}
		for i, case in ipairs(story.cases) do
			local wire = case.wire:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)
			blocks[i] = base64.encode(wire)
		end
		local decoded, err = c:hpack_decode(blocks, story.table_size)
		assert(decoded, err)
		for i, fields in ipairs(decoded) do
			local headers = {}
			for _, field in ipairs(fields) do headers[#headers + 1] = field.Name; headers[#headers + 1] = field.Value end
			testaux.asserteq(headers, story.cases[i].headers, story.name .. " gives independent Go fields")
		end
	end
end)

testaux.case("Go HPACK decoder agrees after same-block eviction and reuse", function()
	local encoder = hpack.new(102)
	local first = hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f")
	local fields = {"a", "b", "g", "h", "c", "d", "e", "f", "g", "h", "a", "b", "g", "h"}
	local second = hpack.pack(encoder, nil, table.unpack(fields))
	local decoded, err = c:hpack_decode({base64.encode(first), base64.encode(second)}, 102)
	assert(decoded, err)
	local headers = {}
	for _, field in ipairs(decoded[2]) do headers[#headers + 1] = field.Name; headers[#headers + 1] = field.Value end
	testaux.asserteq(headers, fields, "Go resolves early indices before later eviction and reinsertion")
end)

testaux.case("Go HPACK decoder receives distinct opaque cache keys", function()
	local encoder = hpack.new(4096)
	local expected = {{"a: b", "c"}, {"a", "b: c"}, {":method: GET", "other"}, {"x\0y", "z\0w"}}
	local blocks = {}
	for _ = 1, 2 do
		for _, field in ipairs(expected) do
			blocks[#blocks + 1] = base64.encode(hpack.pack(encoder, nil, table.unpack(field)))
		end
	end
	local decoded, err = c:hpack_decode(blocks, 4096)
	assert(decoded, err)
	for i, fields in ipairs(decoded) do
		testaux.asserteq(#fields, 1, "one opaque field per block")
		local field = expected[(i - 1) % #expected + 1]
		testaux.asserteq({fields[1].Name, fields[1].Value}, field, "Go sees the original opaque name and value")
	end
end)

testaux.case("Go HPACK decoder rejects the same Huffman padding and EOS vectors", function()
	for _, payload in ipairs({"\xff", "\x1f\xff", "\x1f\xff\xff", "\x1f\xff\xff\xff",
		"\xff\x9f\xff\xff\xff", "R\xbc0\xff\xff\xff\xff", "\x00",
		"\xff\xff\xff\xff\xfc", "00\x91\xff\xff\xff\xff\xc8"}) do
		local wire = "\x00\x01x" .. string.char(0x80 + #payload) .. payload
		local decoded, err = c:hpack_decode({base64.encode(wire)}, 4096)
		testaux.asserteq(decoded, nil, "Go rejects malformed Huffman value")
		testaux.assertneq(err, nil, "Go reports a compression error")
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, {}), false, "C agrees with Go rejection")
	end
end)


testaux.case("Go HPACK decoder agrees on seeded table changes and cached reuse", function()
	local seed = 0x75419113
	local function next_value()
		seed = (seed * 1664525 + 1013904223) & 0xffffffff
		return seed
	end
	local names = {"a", "c", "x-reused", ":path", ":method", "a: b", ":method: GET", "x\0binary"}
	local values = {"b", "d", "GET", "/", "b: c", "", string.rep("cached-", 13), "z\0w"}
	local capacities = {0, 32, 33, 34, 68, 128, 256, 4096}
	for _ = 1, 16 do
		local encoder, decoder = hpack.new(4096), hpack.new(4096)
		local blocks, expected = {}, {}
		for step = 1, 32 do
			if step % 8 == 1 then
				local capacity = capacities[next_value() % #capacities + 1]
				hpack.hardlimit(encoder, 0)
				hpack.hardlimit(encoder, capacity)
			end
			local fields = {}
			for _ = 1, next_value() % 6 + 1 do
				fields[#fields + 1] = names[next_value() % #names + 1]
				fields[#fields + 1] = values[next_value() % #values + 1]
			end
			local wire = hpack.pack(encoder, nil, table.unpack(fields))
			local headers = {}
			testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "C decodes seeded block")
			testaux.asserteq(headers, fields, "C fields agree through table changes")
			blocks[step] = base64.encode(wire)
			expected[step] = fields
		end
		local decoded, err = c:hpack_decode(blocks, 4096)
		assert(decoded, err)
		for step, fields in ipairs(decoded) do
			local headers = {}
			for _, field in ipairs(fields) do headers[#headers + 1] = field.Name; headers[#headers + 1] = field.Value end
			testaux.asserteq(headers, expected[step], "independent Go fields agree on the seeded sequence")
		end
	end
end)

httpc:close()
server:close()
c:close()
wait_readers()
