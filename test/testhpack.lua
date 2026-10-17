local silly = require "silly"
local pcall = silly.pcall
local crypto = require "silly.crypto.utils"
local hpack = require "silly.http2.hpack"
local testaux = require "test.testaux"
local send_hpack = hpack.new(4096)
local prefix = crypto.randomkey(200)
local unit = 250+32

-- Helper function to convert array format {k1, v1, k2, v2, ...} to hash table
-- Multiple values with same key are stored in array
local function array_to_headers(arr)
	local headers = {}
	for i = 1, #arr, 2 do
		local k, v = arr[i], arr[i + 1]
		if headers[k] then
			if type(headers[k]) == "table" then
				headers[k][#headers[k] + 1] = v
			else
				headers[k] = {headers[k], v}
			end
		else
			headers[k] = v
		end
	end
	return headers
end

testaux.case("Test 0: test prune", function()
	local decoder = hpack.new(4096)
	local n = 4096 // unit
	local data = {}
	local pruned = false
	local previous = 0
	for i = 1, n + 96 do
		data[i] = prefix .. string.format("%045d", i)
		local wire = hpack.pack(send_hpack, nil, ":path", data[i])
		local headers = {}
		testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "Test 0: decode across prune")
		testaux.asserteq(headers, {":path", data[i]}, "Test 0: prune preserves field values")
		local count = hpack.dbg_evictcount(send_hpack)
		if count < previous then
			pruned = true
		end
		previous = count
	end
	testaux.asserteq(pruned, true, "Test 0: long-running encoder compacts the queue")
	for i = #data - n + 1, #data do
		local wire = hpack.pack(send_hpack, nil, ":path", data[i])
		testaux.asserteq(#wire, 1, "Test 0: surviving entries remain indexed after prune")
		local headers = {}
		testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "Test 0: decode surviving entry")
		testaux.asserteq(headers, {":path", data[i]}, "Test 0: compacted index references correct entry")
	end
end)
testaux.case("Test 1: Static table indexing", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Use common headers from static table
	local headers = {
		[":method"] = "GET",
		[":scheme"] = "https",
		[":authority"] = "example.com",
		[":path"] = "/",
		["user-agent"] = "test-client"
	}

	local buffer = hpack.pack(encoder, {},
		":method", "GET",
		":scheme", "https",
		":authority", "example.com",
		":path", "/",
		"user-agent", "test-client"
	)

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 1: unpack should succeed")
	decoded = array_to_headers(decoded)

	for k, v in pairs(headers) do
		testaux.asserteq(decoded[k], v, "Test 1: static table index: " .. k)
	end
end)

testaux.case("Test 2: Integer representation", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Generate a long path to test integer encoding
	local long_path = "/" .. string.rep("a", 300)

	local buffer = hpack.pack(encoder, {}, ":path", long_path)

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 2: unpack should succeed")
	decoded = array_to_headers(decoded)

	testaux.asserteq(decoded[":path"], long_path, "Test 2: integer representation")
end)

testaux.case("Test 3: Huffman encoding", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Header value with various ASCII characters
	local complex_value = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()"

	local buffer = hpack.pack(encoder, {}, "x-custom-header", complex_value)

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 3: unpack should succeed")
	decoded = array_to_headers(decoded)

	testaux.asserteq(decoded["x-custom-header"], complex_value, "Test 3: Huffman encoding")
end)

testaux.case("Test 4: Dynamic table update", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	local buffer1 = hpack.pack(encoder, {}, "custom-header", "value1")
	local buffer2 = hpack.pack(encoder, {}, "custom-header", "value1")

	-- Second encoding should reference dynamic table
	testaux.assertlt(#buffer2, #buffer1, "Test 4: dynamic table update")

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer1, decoded)
	testaux.asserteq(ok, true, "Test 4: unpack should succeed")
	decoded = array_to_headers(decoded)
	local decoded2 = {}
	local ok2 = hpack.unpack(decoder, buffer2, decoded2)
	testaux.asserteq(ok2, true, "Test 4: unpack should succeed")
	decoded2 = array_to_headers(decoded2)

	testaux.asserteq(decoded["custom-header"], "value1", "Test 4: dynamic table decoding")
	testaux.asserteq(decoded2["custom-header"], "value1", "Test 4: dynamic table decoding")
end)

testaux.case("Test 5: Special characters", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Header value with special characters
	local special_chars = "Unicode test: Hello world! ñáéíóú 😀🚀"

	local buffer = hpack.pack(encoder, {["x-special"] = special_chars})

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 5: unpack should succeed")
	decoded = array_to_headers(decoded)

	testaux.asserteq(decoded["x-special"], special_chars, "Test 5: special characters encoding")
end)

testaux.case("Test 6: Multiple header fields", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	local headers = {
		["content-type"] = "application/json",
		["content-length"] = "256",
		["user-agent"] = "test-client",
		["accept"] = "application/json",
		["accept-encoding"] = "gzip, deflate, br",
		["accept-language"] = "en-US,en;q=0.9,zh-CN;q=0.8",
	}

	local buffer = hpack.pack(encoder, headers, ":method", "POST", ":scheme", "https", ":path", "/api/data")
	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 6: unpack should succeed")
	decoded = array_to_headers(decoded)
	for k, v in pairs(headers) do
		testaux.asserteq(decoded[k], v, "Test 6: multiple header fields: " .. k)
	end
end)

testaux.case("Test 7: Duplicate header names with different values", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	local buffer1 = hpack.pack(encoder, {
		["set-cookie"] = "cookie1=value1; Path=/",
	})
	local buffer2 = hpack.pack(encoder, {
		["set-cookie"] = "cookie2=value2; Path=/api",
		["cookie"] = {
			"value1",
			"value2",
		}
	})

	local decoded = {}
	local ok = hpack.unpack(decoder, {buffer1, buffer2}, decoded)
	testaux.asserteq(ok, true, "Test 7: unpack should succeed")
	decoded = array_to_headers(decoded)
	print(require "silly.encoding.json".encode(decoded))
	-- Check if multiple headers with same name are handled correctly
	local set_cookies = decoded["set-cookie"]
	local cookies = decoded["cookie"]
	testaux.asserteq(type(set_cookies), "table", "Test 7.1: multiple headers with same name should be a table")
	testaux.asserteq(type(cookies), "table", "Test 7.2: multiple headers with same name should be a table")
	testaux.asserteq(#set_cookies, 2, "Test 7.3: should have two cookies")
	testaux.asserteq(#cookies, 2, "Test 7.4: should have two cookies")
	testaux.asserteq(set_cookies[1], "cookie1=value1; Path=/", "Test 7.5: first cookie")
	testaux.asserteq(set_cookies[2], "cookie2=value2; Path=/api", "Test 7.6: second cookie")
	testaux.asserteq(cookies[1], "value1", "Test 7.7: first cookie value")
	testaux.asserteq(cookies[2], "value2", "Test 7.8: second cookie value")
end)

testaux.case("Test 8: Dynamic table eviction", function()
	local small_table_size = 256
	local encoder = hpack.new(small_table_size)
	local decoder = hpack.new(small_table_size)
	-- Add several headers to fill the dynamic table
	local headers = {}
	for i = 1, 10 do
		headers[i] = {
			name = "x-custom-header-" .. i,
			value = string.rep("v", 20) .. i  -- Create values with consistent size
		}
	end

	-- Add headers to the dynamic table
	local buffer = {}
	for _, header in ipairs(headers) do
		local buf = hpack.pack(encoder, {
			[header.name] = header.value,
		})
		buffer[#buffer+1] = buf
	end

	local cnt = hpack.dbg_evictcount(encoder)
	testaux.asserteq(cnt, 7, "Test 8: FIFO eviction keeps the three entries that fit")

	-- Check if oldest entries were evicted
	local buffer_test = hpack.pack(encoder, {
		[headers[1].name] = headers[1].value,
	})

	-- This should be encoded as a new header (not found in dynamic table)
	-- because it should have been evicted
	local buffer_new = hpack.pack(encoder, {
		["new-header"] = "new-value",
	})

	-- The most recently added headers should still be in the table
	local buffer_recent = hpack.pack(encoder, {
		[headers[10].name] = headers[10].value,
	})

	-- The evicted header should be encoded with a larger size than the recent one
	testaux.asserteq(#buffer_recent, 1, "Test 8: should have one buffer")
	testaux.assertgt(#buffer_test, #buffer_recent,
		"Test 8: oldest entries should be evicted from dynamic table")

	-- Decode and verify
	local decoded = {}
	local ok = hpack.unpack(decoder, table.concat(buffer), decoded)
	testaux.asserteq(ok, true, "Test 8: unpack should succeed")
	decoded = array_to_headers(decoded)
	for _, header in ipairs(headers) do
		testaux.asserteq(decoded[header.name], header.value,
			"Test 8: dynamic table eviction: " .. header.name)
	end
end)

testaux.case("Test 9: Error handling for malformed input", function()
	local decoder = hpack.new(4096)
	-- Test with invalid Huffman sequence
	local invalid_data = string.char(0x80, 0xff, 0xff) -- Invalid Huffman sequence
	local decoded = {}
	local ok = hpack.unpack(decoder, invalid_data, decoded)
	testaux.asserteq(ok, false, "Test 9: should handle malformed input gracefully")
end)

testaux.case("Test 10: Header field size limits", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Create extremely large header value (16KB)
	local large_value = string.rep("x", 16 * 1024)
	local buffer = hpack.pack(encoder, {
		["x-large-header"] = large_value,
	})

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 10: unpack should succeed")
	decoded = array_to_headers(decoded)
	testaux.asserteq(decoded["x-large-header"], large_value,
		"Test 10: should handle large header values")
end)

testaux.case("Test 11: Encoder-decoder synchronization", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Simulate HTTP/2 request-response pattern with multiple exchanges
	local exchanges = {
		{
			request = {
				[":method"] = "GET",
				[":path"] = "/resource1",
				["user-agent"] = "client/1.0"
			},
			response = {
				[":status"] = "200",
				["content-type"] = "text/html",
				["server"] = "test-server/1.0"
			}
		},
		{
			request = {
				[":method"] = "POST",
				[":path"] = "/resource2",
				["content-type"] = "application/json"
			},
			response = {
				[":status"] = "201",
				["location"] = "/resource2/1",
				["content-length"] = "0"
			}
		}
	}

	for _, exchange in ipairs(exchanges) do
		-- Encode request
		local request = exchange.request
		local method = request[":method"]
		local path = request[":path"]
		request[':method'] = nil
		request[':path'] = nil
		local buf = hpack.pack(encoder, request, ":method", method, ":path", path)
		-- Decode request
		local decoded_req = {}
		local ok = hpack.unpack(decoder, buf, decoded_req)
		testaux.asserteq(ok, true, "Test 11: unpack request should succeed")
		decoded_req = array_to_headers(decoded_req)

		-- Verify request
		for k, v in pairs(exchange.request) do
			testaux.asserteq(decoded_req[k], v, "Test 11: encoder-decoder sync request: " .. k)
		end
		testaux.asserteq(decoded_req[":method"], method, "Test 11: encoder-decoder sync request: :method")
		testaux.asserteq(decoded_req[":path"], path, "Test 11: encoder-decoder sync request: :path")

		-- Encode response
		local response = exchange.response
		local status = response[":status"]
		response[':status'] = nil
		local buf = hpack.pack(encoder, response, ":status", status)
		-- Decode response
		local decoded_resp = {}
		local ok = hpack.unpack(decoder, buf, decoded_resp)
		testaux.asserteq(ok, true, "Test 11: unpack response should succeed")
		decoded_resp = array_to_headers(decoded_resp)
		-- Verify response
		for k, v in pairs(exchange.response) do
			testaux.asserteq(decoded_resp[k], v, "Test 11: encoder-decoder sync response: " .. k)
		end
		testaux.asserteq(decoded_resp[":status"], status, "Test 11: encoder-decoder sync response: :status")
	end
end)

testaux.case("Test 12: Dynamic table size changes during communication", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Initial headers
	local buffer1 = hpack.pack(encoder, {
		header1 = "value1",
		header2 = "value2",
		header3 = "value3"
	})

	-- Resize table
	local new_size = 2048
	hpack.hardlimit(encoder, new_size)
	hpack.hardlimit(decoder, new_size)

	-- More headers after resize
	local buffer2 = hpack.pack(encoder, {
		header1 = "value1",  -- Should reference dynamic table
		header4 = "value4",  -- New header
		header5 = "value5"   -- New header
	})

	-- Decode both buffers
	local decoded1 = {}
	local ok1 = hpack.unpack(decoder, buffer1, decoded1)
	testaux.asserteq(ok1, true, "Test 12: unpack buffer1 should succeed")
	decoded1 = array_to_headers(decoded1)
	local decoded2 = {}
	local ok2 = hpack.unpack(decoder, buffer2, decoded2)
	testaux.asserteq(ok2, true, "Test 12: unpack buffer2 should succeed")
	decoded2 = array_to_headers(decoded2)

	-- Verify all headers
	testaux.asserteq(decoded1["header1"], "value1", "Test 12: pre-resize header1")
	testaux.asserteq(decoded1["header2"], "value2", "Test 12: pre-resize header2")
	testaux.asserteq(decoded1["header3"], "value3", "Test 12: pre-resize header3")

	testaux.asserteq(decoded2["header1"], "value1", "Test 12: post-resize header1")
	testaux.asserteq(decoded2["header4"], "value4", "Test 12: post-resize header4")
	testaux.asserteq(decoded2["header5"], "value5", "Test 12: post-resize header5")
end)

testaux.case("Test 13: Concurrent encoding sessions", function()
	local encoder1 = hpack.new(4096)
	local encoder2 = hpack.new(4096)
	local decoder1, decoder2 = hpack.new(4096), hpack.new(4096)

	-- Encoder 1 headers
	local buffer1 = hpack.pack(encoder1, {
		session = "encoder1",
		header1 = "value1-from-encoder1"
	})

	-- Encoder 2 headers
	local buffer2 = hpack.pack(encoder2, {
		session = "encoder2",
		header1 = "value1-from-encoder2"
	})

	-- Decode both buffers
	local decoded1 = {}
	local ok1 = hpack.unpack(decoder1, buffer1, decoded1)
	testaux.asserteq(ok1, true, "Test 13: unpack buffer1 should succeed")
	decoded1 = array_to_headers(decoded1)
	local decoded2 = {}
	local ok2 = hpack.unpack(decoder2, buffer2, decoded2)
	testaux.asserteq(ok2, true, "Test 13: unpack buffer2 should succeed")
	decoded2 = array_to_headers(decoded2)

	-- Verify headers from different encoders
	testaux.asserteq(decoded1["session"], "encoder1", "Test 13: encoder1 session")
	testaux.asserteq(decoded1["header1"], "value1-from-encoder1", "Test 13: encoder1 header1")

	testaux.asserteq(decoded2["session"], "encoder2", "Test 13: encoder2 session")
	for _, context in ipairs({{encoder1, decoder1, "encoder1"}, {encoder2, decoder2, "encoder2"}}) do
		local wire = hpack.pack(context[1], nil, "session", context[3])
		testaux.asserteq(#wire, 1, "Test 13: each context reuses its own dynamic index")
		local headers = {}
		testaux.asserteq(hpack.unpack(context[2], wire, headers), true, "Test 13: independent context decodes its index")
		testaux.asserteq(headers, {"session", context[3]}, "Test 13: contexts never share cached values")
	end
	testaux.asserteq(decoded2["header1"], "value1-from-encoder2", "Test 13: encoder2 header1")
end)

testaux.case("Test 14: Zero-length header values", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)
	local buffer = hpack.pack(encoder, {
		empty_value = ""
	})

	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 14: unpack should succeed")
	decoded = array_to_headers(decoded)
	testaux.asserteq(decoded["empty_value"], "", "Test 14: zero-length header value")
end)

testaux.case("Test 15: Table size update", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Change table size
	local new_size = 2048
	hpack.hardlimit(encoder, new_size)

	local buffer = hpack.pack(encoder, {
		["x-custom-header"] =  "test-value"
	})
	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 15: unpack should succeed")
	decoded = array_to_headers(decoded)
	testaux.asserteq(decoded["x-custom-header"], "test-value", "Test 15: table size update")
end)

testaux.case("Test 16: encode empty table", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)
	local buffer = hpack.pack(encoder, {})
	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 16: unpack should succeed")
	decoded = array_to_headers(decoded)
	testaux.asserteq(next(decoded), nil, "Test 16: encode empty table")

	local buffer = hpack.pack(encoder, {
		["x-custom-header"] =  "test-value",
		["cookie"] =  {},
		["x-custom-header2"] =  "test-value2",
	})
	local decoded = {}
	local ok = hpack.unpack(decoder, buffer, decoded)
	testaux.asserteq(ok, true, "Test 16: unpack should succeed")
	decoded = array_to_headers(decoded)
	testaux.asserteq(decoded["cookie"], nil, "Test 16: encode empty table")
	testaux.asserteq(decoded["x-custom-header"], "test-value", "Test 16: encode empty table")
	testaux.asserteq(decoded["x-custom-header2"], "test-value2", "Test 16: encode empty table")
end)


testaux.case("Test 17: Reusing decoded table should append new pairs", function()
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)
	local decoded = {}
	local header = {
		[":status"] = "200",
		["content-type"] = "text/plain",
	}
	local buffer1 = hpack.pack(encoder, header)
	local ok1 = hpack.unpack(decoder, buffer1, decoded)
	testaux.asserteq(ok1, true, "Test 17: first unpack should succeed")
	testaux.asserteq(#decoded, 4, "Test 17: first unpack should succeed")
	for i = 1, #decoded, 2 do
		local k = decoded[i]
		local v = decoded[i+1]
		testaux.asserteq(v, header[k], "Test 17: first decode key value")
	end

	local buffer2 = hpack.pack(encoder, {
		[":status"] = "204",
	})
	local ok2 = hpack.unpack(decoder, buffer2, decoded)
	testaux.asserteq(ok2, true, "Test 17: second unpack should succeed")
	testaux.asserteq(decoded[5], ":status", "Test 17: appended new key")
	testaux.asserteq(decoded[6], "204", "Test 17: appended new value")
	testaux.asserteq(#decoded, 6, "Test 17: table length should reflect appended entries")
end)

testaux.case("Test 18: HPACK decoder evicts entries inserted in the same block", function()
	local decoder = hpack.new(64)
	-- Each entry costs 34 bytes. Inserting c:d evicts a:b; index 62 is c:d.
	local wire = "\x40\x01a\x01b\x40\x01c\x01d\xbe"
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode literals and index")
	testaux.asserteq(headers, {"a", "b", "c", "d", "c", "d"}, "latest index after eviction")
end)

testaux.case("Test 19: HPACK oversized indexed entry clears the dynamic table", function()
	local decoder = hpack.new(64)
	local wire = "\x40\x01a\x01b\x40\x01c" .. string.char(40) .. string.rep("d", 40)
	testaux.asserteq(hpack.unpack(decoder, wire, {}), true, "oversized literal is valid")
	testaux.asserteq(hpack.unpack(decoder, "\xbe", {}), false, "old index was evicted")
end)

testaux.case("Test 20: HPACK shrink emits table size update and decodes subsequent blocks", function()
	local encoder, decoder = hpack.new(4096), hpack.new(4096)
	local function exchange()
		local headers = {}
		local wire = hpack.pack(encoder, {}, "x-shrink", "cached")
		testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "peer decodes after shrink")
		testaux.asserteq(headers, {"x-shrink", "cached"}, "peer receives correct value")
		return wire
	end
	exchange()
	exchange()
	hpack.hardlimit(encoder, 0)
	hpack.hardlimit(decoder, 0)
	local wire = exchange()
	testaux.asserteq(wire:byte(1), 0x20, "encoder announces zero table size")
	exchange()
end)

testaux.case("Test 21: HPACK shrink then grow announces smallest and final table sizes", function()
	local encoder, decoder = hpack.new(4096), hpack.new(4096)
	assert(hpack.unpack(decoder, hpack.pack(encoder, {}, "x-cache", "value"), {}))
	hpack.hardlimit(encoder, 0)
	hpack.hardlimit(encoder, 128)
	hpack.hardlimit(decoder, 128)
	local wire = hpack.pack(encoder, {}, "x-cache", "value")
	testaux.asserteq(wire:sub(1, 3), "\x20\x3f\x61", "smallest then final update")
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode updated block")
	testaux.asserteq(headers, {"x-cache", "value"}, "value after shrink and grow")
end)

testaux.case("Test 22: HPACK validates integer termination and overflow", function()
	for _, wire in ipairs({"\x3f\x00", "\x3f\x61"}) do
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, {}), true,
			"complete continuation integer may end at EOF")
	end
	for _, wire in ipairs({"\x3f", "\x3f\x80", "\xff\x80", "\x00\x7f\x80", "\x3f\xff\xff\xff\xff\x7f"}) do
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, {}), false, "invalid HPACK integer")
	end
end)

testaux.case("Test 23: HPACK rejects Huffman EOS in a literal", function()
	testaux.asserteq(hpack.unpack(hpack.new(4096), "\x00\x01a\x84\xff\xff\xff\xff", {}), false, "EOS is forbidden")
end)

testaux.case("Test 24: HPACK FIFO eviction preserves entries when space is sufficient", function()
	local decoder = hpack.new(102)
	local first = "\x40\x01a\x01b\x40\x01c\x01d\x40\x01e\x01f"
	assert(hpack.unpack(decoder, first, {}))
	local headers = {}
	local second = "\xbf\x40\x01g\x01h\xc0"
	testaux.asserteq(hpack.unpack(decoder, second, headers), true,
		"only the oldest entry is evicted before the last index")
	testaux.asserteq(headers, {"c", "d", "g", "h", "c", "d"},
		"previously referenced entry remains after minimal eviction")
end)

testaux.case("Test 25: HPACK FIFO encoder may evict an entry already referenced in the block", function()
	local encoder, decoder = hpack.new(102), hpack.new(102)
	assert(hpack.unpack(decoder,
		hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f"), {}))
	local wire = hpack.pack(encoder, nil, "a", "b", "g", "h", "c", "d", "e", "f", "g", "h")
	testaux.asserteq(wire, "\xc0\x40\x01g\x01h\xc0\xbf\xbe",
		"new field is indexed even after referring to the oldest entry")
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode across FIFO eviction")
	testaux.asserteq(headers, {"a", "b", "g", "h", "c", "d", "e", "f", "g", "h"},
		"indices follow the current dynamic table")
end)

testaux.case("Test 26: HPACK FIFO shrink retains entries that fit the new capacity", function()
	local encoder, decoder = hpack.new(102), hpack.new(102)
	assert(hpack.unpack(decoder,
		hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f"), {}))
	hpack.hardlimit(encoder, 68)
	local wire = hpack.pack(encoder, nil, "c", "d", "e", "f")
	testaux.asserteq(wire, "\x3f\x25\xbf\xbe", "shrink evicts only one oldest entry")
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode partial shrink")
	testaux.asserteq(headers, {"c", "d", "e", "f"}, "retained entries keep their indices")
end)

testaux.case("Test 27: HPACK oversized unindexed field leaves the encoder table intact", function()
	local encoder, decoder = hpack.new(34), hpack.new(34)
	assert(hpack.unpack(decoder, hpack.pack(encoder, nil, "a", "b"), {}))
	local wire = hpack.pack(encoder, nil, "large", "value", "a", "b")
	testaux.asserteq(wire:byte(1), 0, "oversized field uses a literal without indexing")
	testaux.asserteq(wire:byte(-1), 0xbe, "unindexed field preserves cached entry")
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode oversized literal and old index")
	testaux.asserteq(headers, {"large", "value", "a", "b"}, "unindexed field does not change the table")
end)

-- Fixed independent vectors: RFC 7541 Appendix C and nghttp2 golden stories.
local function hpack_fromhex(hex)
	return (hex:gsub("..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

local hpack_vectors
local function hpack_reference_vectors()
	if not hpack_vectors then
		local file = assert(io.open("test/data/hpack.json", "rb"))
		local data = file:read("a")
		file:close()
		hpack_vectors = assert(require "silly.encoding.json".decode(data))
	end
	return hpack_vectors
end

local function hpack_test_length(length, flag)
	if length < 127 then
		return string.char(flag + length)
	end
	local bytes = {string.char(flag + 127)}
	length = length - 127
	while length >= 128 do
		bytes[#bytes + 1] = string.char(128 + length % 128)
		length = length // 128
	end
	bytes[#bytes + 1] = string.char(length)
	return table.concat(bytes)
end

testaux.case("Test 28: HPACK follows RFC and nghttp2 golden sequences", function()
	for _, story in ipairs(hpack_reference_vectors().stories) do
		local decoder = hpack.new(story.table_size)
		for _, case in ipairs(story.cases) do
			if case.limit then
				hpack.hardlimit(decoder, case.limit)
			end
			local headers = {}
			testaux.asserteq(hpack.unpack(decoder, hpack_fromhex(case.wire), headers), true,
				story.name .. " decodes external wire")
			testaux.asserteq(headers, case.headers, story.name .. " preserves field order and values")
		end
	end
end)

testaux.case("Test 29: HPACK concatenates fragments at every RFC wire boundary", function()
	for _, story in ipairs(hpack_reference_vectors().stories) do
		if story.name:sub(1, 3) == "RFC" then
			for index, case in ipairs(story.cases) do
				local wire = hpack_fromhex(case.wire)
				for split = 0, #wire do
					local decoder = hpack.new(story.table_size)
					for i = 1, index - 1 do
						assert(hpack.unpack(decoder, hpack_fromhex(story.cases[i].wire), {}))
					end
					local headers = {}
					testaux.asserteq(hpack.unpack(decoder,
						{"", wire:sub(1, split), "", wire:sub(split + 1), ""}, headers), true,
						"fragment boundary may split an integer or Huffman string")
					testaux.asserteq(headers, case.headers, "fragmentation preserves decoded fields")
				end
			end
		end
	end
end)

testaux.case("Test 30: HPACK Huffman accepts all octets and every valid padding length", function()
	for _, vector in ipairs(hpack_reference_vectors().huffman) do
		local payload = hpack_fromhex(vector.huffman_hex)
		local value = hpack_fromhex(vector.value_hex)
		local wire = "\x00\x01x" .. hpack_test_length(#payload, 0x80) .. payload
		local headers = {}
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, headers), true,
			"decode independent Go Huffman vector")
		testaux.asserteq(headers, {"x", value}, "Huffman preserves opaque octets")
		for cut = 1, #wire - 1 do
			testaux.asserteq(hpack.unpack(hpack.new(4096), wire:sub(1, cut), {}), false,
				"truncated literal cannot end inside a name, length or payload")
		end
	end
end)

testaux.case("Test 31: HPACK Huffman rejects nghttp2 and Go padding and EOS regressions", function()
	-- nghttp2 test_nghttp2_hd_huff_decode and Go's excess/corrupt padding,
	-- EOS and historical fuzz-crash vectors; apply to names as well as values.
	local invalid = {
		"\xff", "\x1f\xff", "\x1f\xff\xff", "\x1f\xff\xff\xff",
		"\xff\x9f\xff\xff\xff", "R\xbc0\xff\xff\xff\xff", "\x00",
		"\xff\xff\xff\xff\xfc", "00\x91\xff\xff\xff\xff\xc8",
	}
	for _, payload in ipairs(invalid) do
		local encoded = hpack_test_length(#payload, 0x80) .. payload
		testaux.asserteq(hpack.unpack(hpack.new(4096), "\x00\x01x" .. encoded, {}), false,
			"invalid Huffman value is rejected")
		testaux.asserteq(hpack.unpack(hpack.new(4096), "\x00" .. encoded .. "\x00", {}), false,
			"invalid Huffman name is rejected")
	end
end)

testaux.case("Test 32: HPACK dynamic name remains valid when insertion evicts its source", function()
	local decoder = hpack.new(68)
	assert(hpack.unpack(decoder, "\x40\x01a\x01b\x40\x01c\x01d", {}))
	local headers = {}
	-- Index 63 supplies a's name, then inserting a:e evicts the old a:b.
	testaux.asserteq(hpack.unpack(decoder, "\x7f\x00\x01e\xbf\xbe", headers), true,
		"referenced name survives eviction while decoding the new field")
	testaux.asserteq(headers, {"a", "e", "c", "d", "a", "e"}, "dynamic names and values stay paired")
	testaux.asserteq(hpack.unpack(decoder, "\xc0", {}), false, "evicted index is no longer addressable")
end)

testaux.case("Test 33: HPACK encoder can reuse a field after same-block eviction", function()
	local encoder, decoder = hpack.new(102), hpack.new(102)
	assert(hpack.unpack(decoder, hpack.pack(encoder, nil, "a", "b", "c", "d", "e", "f"), {}))
	local fields = {"a", "b", "g", "h", "c", "d", "e", "f", "g", "h", "a", "b", "g", "h"}
	local wire = hpack.pack(encoder, nil, table.unpack(fields))
	testaux.asserteq(wire, "\xc0\x40\x01g\x01h\xc0\xbf\xbe\x40\x01a\x01b\xbf",
		"evicted field becomes a literal and subsequent indices use the current table")
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, wire, headers), true, "decode reference, eviction and reinsertion")
	testaux.asserteq(headers, fields, "earlier references remain valid after later eviction")
end)

testaux.case("Test 34: HPACK duplicate entries survive eviction and queue compaction", function()
	local decoder = hpack.new(68)
	local headers, expected = {}, {}
	for _ = 1, 98 do
		expected[#expected + 1] = "a"
		expected[#expected + 1] = "b"
	end
	testaux.asserteq(hpack.unpack(decoder,
		string.rep("\x40\x01a\x01b", 96) .. "\xbe\xbf", headers), true,
		"duplicate dynamic entries remain separately addressable after prune")
	testaux.asserteq(headers, expected, "both newest duplicates decode correctly")
end)

testaux.case("Test 35: HPACK integer prefixes distinguish indices, names and string lengths", function()
	local decoder = hpack.new(4096)
	local first = {}
	for i = 1, 66 do
		local name = "x" .. i
		first[#first + 1] = "\x40" .. string.char(#name) .. name .. "\x01v"
	end
	assert(hpack.unpack(decoder, table.concat(first), {}))
	local headers = {}
	testaux.asserteq(hpack.unpack(decoder, "\xff\x00\x7f\x00\x01z\x0f\x00\x01v\x1f\x00\x01w\xbe", headers), true,
		"saturated 7-, 6- and 4-bit prefixes decode in their own contexts")
	testaux.asserteq(headers, {"x1", "v", "x65", "z", "accept-charset", "v", "accept-charset", "w", "x65", "z"},
		"nonindexed and neverindexed fields leave the latest index intact")
	for _, size in ipairs({126, 127, 128, 255, 256}) do
		local value = string.rep("z", size)
		local fields = {}
		testaux.asserteq(hpack.unpack(hpack.new(4096), "\x00\x01x" .. hpack_test_length(size, 0) .. value, fields), true,
			"string length crosses the seven-bit prefix boundary")
		testaux.asserteq(fields, {"x", value}, "length uses decoded raw octets")
	end
	for _, wire in ipairs({"\x80", "\xbe", "\x7f", "\x7f\x00\x00", "\x0f", "\x82\x20", "\x3f\xe2\x1f"}) do
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, {}), false,
			"zero/missing index, truncated name or invalid table update is rejected")
	end
end)

testaux.case("Test 36: HPACK cache keys preserve opaque names and values", function()
	local encoder, decoder = hpack.new(4096), hpack.new(4096)
	local fields = {{"a: b", "c"}, {"a", "b: c"}, {":method: GET", "other"}, {"x\0y", "z\0w"}}
	for _ = 1, 2 do
		for _, field in ipairs(fields) do
			local headers = {}
			testaux.asserteq(hpack.unpack(decoder, hpack.pack(encoder, nil, table.unpack(field)), headers), true,
				"decode opaque field")
			testaux.asserteq(headers, field, "cache key cannot confuse a name with part of its value")
		end
	end
end)

testaux.case("Test 37: HPACK rejects missing literal string lengths", function()
	for _, wire in ipairs({"\x00", "\x00\x00", "\x40", "\x40\x00", "\x10", "\x10\x00", "\x01"}) do
		testaux.asserteq(hpack.unpack(hpack.new(4096), wire, {}), false,
			"a literal must include both name and value length prefixes")
	end
	testaux.asserteq(hpack.unpack(hpack.new(4096), "", {}), true,
		"an empty field block itself remains valid")
end)


testaux.case("Test 38: HPACK entry size counts raw octets plus 32 at capacity boundaries", function()
	for _, field in ipairs({{"", ""}, {"x", ""}, {"x", "é"}, {"é", "中"},
		{"aaaaaaaa", "aaaaaaaaaaaaaaa"}}) do
		local name, value = table.unpack(field)
		local size = #name + #value + 32
		local literal = hpack.pack(hpack.new(4096), nil, name, value)
		for _, cap in ipairs({size - 1, size, size + 1}) do
			local encoder, decoder = hpack.new(cap), hpack.new(cap)
			local first = hpack.pack(encoder, nil, name, value)
			local second = hpack.pack(encoder, nil, name, value)
			testaux.asserteq(second, cap >= size and "\xbe" or first,
				"encoder caches exactly when decoded octets plus overhead fit")
			assert(hpack.unpack(decoder, literal, {}))
			local headers = {}
			testaux.asserteq(hpack.unpack(decoder, "\xbe", headers), cap >= size,
				"decoder uses original lengths even for Huffman literals and UTF-8")
			if cap >= size then
				testaux.asserteq(headers, field, "indexed boundary entry")
			end
		end
		local decoder = hpack.new(size * 2)
		assert(hpack.unpack(decoder, literal .. literal, {}))
		local headers = {}
		testaux.asserteq(hpack.unpack(decoder, "\xbf\xbe", headers), true,
			"duplicate entries each consume their full raw size")
		testaux.asserteq(headers, {name, value, name, value}, "both duplicates survive exact capacity")
	end
end)

testaux.case("Test 39: HPACK static name lookup cannot alias a full-field cache key", function()
	-- This is the internal key for the static :method/GET entry, used as an opaque name.
	local name = string.pack("T", #":method") .. ":methodGET"
	local encoder, decoder = hpack.new(4096), hpack.new(4096)
	for _ = 1, 2 do
		local headers = {}
		assert(hpack.unpack(decoder, hpack.pack(encoder, nil, name, "opaque"), headers))
		testaux.asserteq(headers, {name, "opaque"}, "a full cache key must not become a static name index")
	end
end)


testaux.case("Test 40: HPACK rejects invalid capacities before constructing a table", function()
	for _, cap in ipairs({-1, 2147483648, 1.5}) do
		local ok = pcall(hpack.new, cap)
		testaux.asserteq(ok, false, "capacity must be a nonnegative integer bounded by INT_MAX")
	end
	for _, cap in ipairs({0, 32, 4096}) do
		testaux.assertneq(hpack.new(cap), nil, "valid table capacities remain accepted")
	end
end)


testaux.case("Test 41: HPACK static names are bidirectional and isolated in their own upvalue", function()
	local _, static = debug.getupvalue(hpack.pack, 1)
	local _, names = debug.getupvalue(hpack.pack, 2)
	testaux.asserteq(type(static), "table", "full static fields have their own table")
	testaux.asserteq(type(names), "table", "static names have a parallel table")
	testaux.asserteq(static[0], nil, "name table does not occupy static index zero")
	local first = {}
	for id = 1, 61 do
		local name = names[id]
		testaux.asserteq(type(name), "string", "every static index has a reverse name")
		first[name] = first[name] or id
		testaux.asserteq(names[name], first[name], "forward names use their first RFC index")
		local fields = {}
		assert(hpack.unpack(hpack.new(4096), string.char(0x40 + id) .. "\x01v", fields))
		testaux.asserteq(fields, {name, "v"}, "indexed names include duplicate static names")
		local value = static[id]
		testaux.asserteq(type(value), "string", "static values are stored at the same index")
		testaux.asserteq(hpack.pack(hpack.new(4096), nil, name, value), string.char(0x80 + id),
			"every static field, including an empty value, uses its full index")
	end
end)


testaux.case("Test 42: HPACK decoded list limit counts indexed fields and keeps compression state", function()
	local decoder = hpack.new(4096)
	local wire = "\x82\x40\x01x\x01v\x82\x40\x01y\x01z"
	local fields = {}
	local ok, limited = hpack.unpack(decoder, wire, fields, 75)
	testaux.asserteq(ok, false, "42-byte static field plus 34-byte literal exceeds 75")
	testaux.asserteq(limited, true, "resource limit is distinct from malformed compression")
	testaux.asserteq(fields, {":method", "GET"}, "output stops growing at the decoded limit")
	local nextfields = {}
	assert(hpack.unpack(decoder, "\xbe\xbf", nextfields, 68))
	testaux.asserteq(nextfields, {"y", "z", "x", "v"},
		"entries after the limit still update the shared dynamic table")
	local bad, overflow = hpack.unpack(hpack.new(4096), wire .. "\x80", {}, 0)
	testaux.asserteq(bad, false, "malformed bytes after the limit still fail decoding")
	testaux.asserteq(overflow, nil, "compression error takes precedence over resource rejection")
end)

testaux.case("Test 43: HPACK list limits count empty fields and exact capacity", function()
	for _, cap in ipairs({31, 32, 63, 64}) do
		local fields = {}
		local ok, limited = hpack.unpack(hpack.new(4096), "\x40\x00\x00\xbe", fields, cap)
		testaux.asserteq(ok, cap >= 64, "two empty fields consume 64 octets")
		testaux.asserteq(limited, cap < 64 and true or nil, "empty lengths still count overhead")
		testaux.asserteq(#fields, cap < 32 and 0 or cap < 64 and 2 or 4,
			"materialized fields fit the budget")
	end
	testaux.asserteq(hpack.unpack(hpack.new(4096), "", {}, 0), true, "empty block fits zero")
	for _, limit in ipairs({-1, 1.5, false}) do
		local ok = pcall(hpack.unpack, hpack.new(4096), "", {}, limit)
		testaux.asserteq(ok, false, "decoded size limit must be a nonnegative integer")
	end
end)


testaux.case("Test 44: HPACK indexed amplification accepts exactly its RFC field-list size", function()
	local wire = "\x88" .. string.rep("\x90", 1200)
	for _, limit in ipairs({65535, 72041, 72042}) do
		local fields = {}
		local ok, limited = hpack.unpack(hpack.new(4096), wire, fields, limit)
		testaux.asserteq(ok, limit >= 72042, "every indexed occurrence includes its 32-byte overhead")
		testaux.asserteq(limited, limit < 72042 and true or nil, "valid encoding can exceed local policy")
		testaux.asserteq(#fields, 2 * (1 + math.min(1200, (limit - 42) // 60)),
			"only complete fields that fit the budget are materialized")
	end
	local fields = {}
	assert(hpack.unpack(hpack.new(4096), wire, fields))
	testaux.asserteq(#fields, 2402, "standalone HPACK decoding has no implicit 64 KiB limit")
end)

testaux.case("Test 45: HPACK pack keeps the buffer on top across growth and argument conversion", function()
	for _, size in ipairs({1023, 1024, 1025, 4096, 16384}) do
		local value = string.rep("x", size)
		for _, mode in ipairs({"arguments", "table", "values", "tostring"}) do
			local encoder, decoder = hpack.new(4096), hpack.new(4096)
			local wire, expected
			if mode == "arguments" then
				wire = hpack.pack(encoder, {["x-tail"] = "end"}, ":path", value)
				expected = {":path", value, "x-tail", "end"}
			elseif mode == "table" then
				wire = hpack.pack(encoder, {[":path"] = value})
				expected = {":path", value}
			elseif mode == "values" then
				wire = hpack.pack(encoder, {[":path"] = {value, "end"}})
				expected = {":path", value, ":path", "end"}
			else
				local object = setmetatable({}, {__tostring = function()
					return value
				end})
				wire = hpack.pack(encoder, nil, ":path", object)
				expected = {":path", value}
			end
			collectgarbage("collect")
			local fields = {}
			testaux.asserteq(hpack.unpack(decoder, wire, fields), true,
				"decode after buffer growth: " .. mode .. " " .. size)
			testaux.asserteq(fields, expected, "growth preserves converted field values")
			local nextfields = {}
			assert(hpack.unpack(decoder, hpack.pack(encoder, nil, ":path", value), nextfields))
			testaux.asserteq(nextfields, {":path", value}, "next block keeps the tables synchronized")
		end
	end
end)


testaux.case("Test 46: HPACK oversized dynamic-name literals clear the table and preserve later entries", function()
	local value = string.rep("x", 4096)
	local wire = "\x7e" .. hpack_test_length(#value, 0) .. value .. "\x40\x01c\x01d\xbe"
	for _, limit in ipairs({0, 65535}) do
		local decoder = hpack.new(68)
		assert(hpack.unpack(decoder, "\x40\x01a\x01b", {}))
		local fields = {}
		local ok, limited = hpack.unpack(decoder, wire, fields, limit)
		testaux.asserteq(ok, limit > 0, "oversized table entry is valid independently of output limit")
		testaux.asserteq(limited, limit == 0 and true or nil, "output budget does not change compression state")
		testaux.asserteq(fields, limit == 0 and {} or {"a", value, "c", "d", "c", "d"},
			"source name survives table clearing and the following fields stay on the stack")
		local nextfields = {}
		assert(hpack.unpack(decoder, "\xbe", nextfields))
		testaux.asserteq(nextfields, {"c", "d"}, "new dynamic entry survives oversized eviction")
		testaux.asserteq(hpack.unpack(decoder, "\xbf", {}), false, "the old source entry is evicted")
	end
end)

testaux.case("Test 47: HPACK resumes with synchronized tables after a conversion error", function()
	for _, mode in ipairs({"fresh", "populated", "shrink", "repeat"}) do
		local encoder, decoder = hpack.new(4096), hpack.new(4096)
		if mode == "populated" then
			assert(hpack.unpack(decoder, hpack.pack(encoder, nil, "x-before", "old"), {}))
		elseif mode == "shrink" then
			hpack.hardlimit(encoder, 0)
			hpack.hardlimit(encoder, 64)
		end
		local bad = setmetatable({}, {__tostring = function()
			error("intentional late HPACK conversion failure")
		end})
		for _ = 1, mode == "repeat" and 2 or 1 do
			local ok = pcall(hpack.pack, encoder, {["x-poison"] = {"good", bad}})
			testaux.asserteq(ok, false, "conversion fails after a dynamic insertion")
		end
		local wire = hpack.pack(encoder, nil, "x-poison", "good")
		local fields = {}
		testaux.asserteq(hpack.unpack(decoder, wire, fields), true,
			"next block decodes after an unsent partial block: " .. mode)
		testaux.asserteq(fields, {"x-poison", "good"}, "no stale dynamic index aliases an old entry")
		local nextfields = {}
		assert(hpack.unpack(decoder, hpack.pack(encoder, nil, "x-before", "old"), nextfields))
		testaux.asserteq(nextfields, {"x-before", "old"}, "later reuse stays synchronized")
	end
end)
