local env = require "silly.env"
local hpack = require "silly.http2.hpack"
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"
local testaux = require "test.testaux"
local conformance = require "test.conformance"

local c = conformance.connect("127.0.0.1", tonumber(env.get("conf_port")) or 9090)

testaux.case("Test 202: Go and Lua HPACK agree on indexed field-list amplification", function()
	local wire = "\x88" .. string.rep("\x90", 1200)
	local decoded, err = c:hpackdecode({base64.encode(wire)}, 4096)
	assert(decoded, err)
	testaux.asserteq(#wire, 1201, "compressed block is much smaller than the decoded list")
	testaux.asserteq(#decoded[1], 1201, "Go HPACK accepts all valid fields without a list limit")
	local fields = assert(hpack.unpack(hpack.new(4096), wire))
	local size = 0
	for i, field in ipairs(decoded[1]) do
		testaux.asserteq(fields[i * 2 - 1], field.Name, "amplified names agree")
		testaux.asserteq(fields[i * 2], field.Value, "amplified values agree")
		size = size + #field.Name + #field.Value + 32
	end
	testaux.asserteq(size, 72042, "RFC field-list size includes every indexed occurrence")
	for _, limit in ipairs({65535, 72041, 72042}) do
		local ok, limited = hpack.unpack(hpack.new(4096), wire, limit)
		testaux.asserteq(ok ~= nil, limit >= size, "bounded Lua decoding uses the same decoded size")
		testaux.asserteq(limited, limit < size and true or nil, "list budget is separate from valid HPACK")
	end
end)

testaux.case("Test 205: Go HPACK decoder agrees on same-block eviction", function()
	local wire = "\x40\x01a\x01b\x40\x01c\x01d\xbe"
	local decoded, err = c:hpackdecode({base64.encode(wire)}, 64)
	assert(decoded, err)
	local lua_headers = assert(hpack.unpack(hpack.new(64), wire))
	for i, field in ipairs(decoded[1]) do
		testaux.asserteq(lua_headers[i * 2 - 1], field.Name, "Go and Lua agree on indexed name")
		testaux.asserteq(lua_headers[i * 2], field.Value, "Go and Lua agree on indexed value")
	end
end)

testaux.case("Test 206: Go HPACK decoder agrees on partial FIFO eviction and shrink", function()
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
		for i, wire in ipairs(blocks) do
			encoded[i] = base64.encode(wire)
		end
		local decoded, err = c:hpackdecode(encoded, 102)
		assert(decoded, err)
		local decoder = hpack.new(102)
		for i, wire in ipairs(blocks) do
			local lua_headers = hpack.unpack(decoder, wire)
			testaux.assertneq(lua_headers, nil, "Lua decodes Go-accepted block")
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

testaux.case("Test 207: Go HPACK decoder accepts grown argument buffers and subsequent cached fields", function()
	local encoder = hpack.new(4096)
	local value = string.rep("x", 4096)
	local first = hpack.pack(encoder, {["x-tail"] = "end"}, ":path", value)
	local second = hpack.pack(encoder, nil, "x-tail", "end")
	testaux.asserteq(second, "\xbe", "the small tail field stays indexed after buffer growth")
	local decoded, err = c:hpackdecode({base64.encode(first), base64.encode(second)}, 4096)
	assert(decoded, err)
	testaux.asserteq(decoded[1], {
		{Name = ":path", Value = value, Sensitive = false},
		{Name = "x-tail", Value = "end", Sensitive = false},
	}, "Go receives the full argument value and following table field")
	testaux.asserteq(decoded[2], {{Name = "x-tail", Value = "end", Sensitive = false}},
		"Go and Lua keep the same dynamic index after growth")
end)

testaux.case("Test 208: Go and Lua agree on oversized literals using an evicted dynamic name", function()
	local value = string.rep("x", 4096)
	local wire = "\x7e\x7f\x81\x1f" .. value .. "\x40\x01c\x01d\xbe"
	local blocks = {"\x40\x01a\x01b", wire, "\xbe"}
	local decoded, err = c:hpackdecode({base64.encode(blocks[1]), base64.encode(blocks[2]),
		base64.encode(blocks[3])}, 68)
	assert(decoded, err)
	local decoder = hpack.new(68)
	for i, block in ipairs(blocks) do
		local fields = assert(hpack.unpack(decoder, block))
		local expected = {}
		for _, field in ipairs(decoded[i]) do
			expected[#expected + 1] = field.Name
			expected[#expected + 1] = field.Value
		end
		testaux.asserteq(fields, expected, "both decoders preserve source names and following entries")
	end
	testaux.asserteq(decoded[2][1].Value, value, "the oversized value remains complete")
	testaux.asserteq(decoded[3][1].Name, "c", "the next dynamic index refers to the new entry")
end)

testaux.case("Test 209: Go HPACK decoder accepts Lua shrink and grow updates", function()
	local encoder = hpack.new(4096)
	local blocks = {base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))}
	hpack.hardlimit(encoder, 0)
	blocks[2] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	hpack.hardlimit(encoder, 128)
	blocks[3] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	blocks[4] = base64.encode(hpack.pack(encoder, {}, "x-cache", "value"))
	local decoded, err = c:hpackdecode(blocks, 4096)
	assert(decoded, err)
	for _, fields in ipairs(decoded) do
		testaux.asserteq(fields[1].Name, "x-cache", "Go name after resizing")
		testaux.asserteq(fields[1].Value, "value", "Go value after resizing")
	end
end)

testaux.case("Test 214: Go HPACK decoder agrees with RFC and nghttp2 golden sequences", function()
	local file = assert(io.open("test/data/hpack.json", "rb"))
	local data = file:read("a")
	file:close()
	local fixtures = assert(json.decode(data))
	for _, story in ipairs(fixtures.stories) do
		local blocks = {}
		for i, case in ipairs(story.cases) do
			local wire = case.wire:gsub("..", function(byte)
				return string.char(tonumber(byte, 16))
			end)
			blocks[i] = base64.encode(wire)
		end
		local decoded, err = c:hpackdecode(blocks, story.table_size)
		assert(decoded, err)
		for i, fields in ipairs(decoded) do
			local headers = {}
			for _, field in ipairs(fields) do
				headers[#headers + 1] = field.Name
				headers[#headers + 1] = field.Value
			end
			testaux.asserteq(headers, story.cases[i].headers, story.name .. " gives independent Go fields")
		end
	end
end)

testaux.case("Test 215: Go HPACK decoder agrees after same-block eviction and reuse", function()
	local encoder = hpack.new(102)
	local first = hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f")
	local fields = {"a", "b", "g", "h", "c", "d", "e", "f", "g", "h", "a", "b", "g", "h"}
	local second = hpack.pack(encoder, nil, table.unpack(fields))
	local decoded, err = c:hpackdecode({base64.encode(first), base64.encode(second)}, 102)
	assert(decoded, err)
	local headers = {}
	for _, field in ipairs(decoded[2]) do
		headers[#headers + 1] = field.Name
		headers[#headers + 1] = field.Value
	end
	testaux.asserteq(headers, fields, "Go resolves early indices before later eviction and reinsertion")
end)

testaux.case("Test 216: Go HPACK decoder receives distinct opaque cache keys", function()
	local encoder = hpack.new(4096)
	local expected = {{"a: b", "c"}, {"a", "b: c"}, {":method: GET", "other"}, {"x\0y", "z\0w"}}
	local blocks = {}
	for _ = 1, 2 do
		for _, field in ipairs(expected) do
			blocks[#blocks + 1] = base64.encode(hpack.pack(encoder, nil, table.unpack(field)))
		end
	end
	local decoded, err = c:hpackdecode(blocks, 4096)
	assert(decoded, err)
	for i, fields in ipairs(decoded) do
		testaux.asserteq(#fields, 1, "one opaque field per block")
		local field = expected[(i - 1) % #expected + 1]
		testaux.asserteq({fields[1].Name, fields[1].Value}, field, "Go sees the original opaque name and value")
	end
end)

testaux.case("Test 217: Go HPACK decoder rejects the same Huffman padding and EOS vectors", function()
	for _, payload in ipairs({"\xff", "\x1f\xff", "\x1f\xff\xff", "\x1f\xff\xff\xff",
		"\xff\x9f\xff\xff\xff", "R\xbc0\xff\xff\xff\xff", "\x00",
		"\xff\xff\xff\xff\xfc", "00\x91\xff\xff\xff\xff\xc8"}) do
		local wire = "\x00\x01x" .. string.char(0x80 + #payload) .. payload
		local decoded, err = c:hpackdecode({base64.encode(wire)}, 4096)
		testaux.asserteq(decoded, nil, "Go rejects malformed Huffman value")
		testaux.assertneq(err, nil, "Go reports a compression error")
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire), nil, "C agrees with Go rejection")
	end
end)

testaux.case("Test 218: Go HPACK decoder agrees on seeded table changes and cached reuse", function()
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
			local headers = hpack.unpack(decoder, wire)
			testaux.assertneq(headers, nil, "C decodes seeded block")
			testaux.asserteq(headers, fields, "C fields agree through table changes")
			blocks[step] = base64.encode(wire)
			expected[step] = fields
		end
		local decoded, err = c:hpackdecode(blocks, 4096)
		assert(decoded, err)
		for step, fields in ipairs(decoded) do
			local headers = {}
			for _, field in ipairs(fields) do
				headers[#headers + 1] = field.Name
				headers[#headers + 1] = field.Value
			end
			testaux.asserteq(headers, expected[step], "independent Go fields agree on the seeded sequence")
		end
	end
end)

testaux.case("Test 219: Go HPACK entry capacity agrees on original octets and 32-byte overhead", function()
	for _, field in ipairs({{"", ""}, {"x", "é"}, {"é", "中"},
		{"aaaaaaaa", "aaaaaaaaaaaaaaa"}}) do
		local name, value = table.unpack(field)
		local size = #name + #value + 32
		local literal = hpack.pack(hpack.new(4096), nil, name, value)
		for _, cap in ipairs({size - 1, size, size + 1}) do
			local decoded, err = c:hpackdecode({base64.encode(literal), base64.encode("\xbe")}, cap)
			if cap < size then
				testaux.asserteq(decoded, nil, "Go cannot index an entry larger than table capacity")
				testaux.assertneq(err, nil, "Go rejects the missing dynamic entry")
			else
				assert(decoded, err)
				testaux.asserteq({decoded[2][1].Name, decoded[2][1].Value}, field,
					"Go retains the exact-capacity entry with original UTF-8/Huffman lengths")
			end
		end
	end
end)

c:close()
