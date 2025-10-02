local crypto = require "silly.crypto.utils"
local hpack = require "silly.http2.hpack"
local testaux = require "test.testaux"
local send_hpack = hpack.new(4096)
local prefix = crypto.randomkey(200)
local unit = 250+32

-- Test 0: test prune
do
	local idx =  0
	local n = 4096//unit
	local prun_count = 0
	repeat
		prun_count = prun_count + n
	until prun_count > (prun_count // 2) and prun_count > 64
	local data = {}
	for i = 1, prun_count + 32 do
		idx = idx + 1
		data[i] = prefix .. string.format("%045d", idx)
	end
	for i = 1, prun_count do
		hpack.pack(send_hpack, nil, ":path", data[i])
	end
	local evict_count = hpack.dbg_evictcount(send_hpack)
	testaux.asserteq(evict_count, (prun_count // n - 1) * n, "Test 0: hpack queue is full")
	hpack.pack(send_hpack, nil,
		":path", data[prun_count-3],
		":path", data[prun_count-2],
		":path", data[prun_count-1],
		":path", data[prun_count+1])
	local evict_count = hpack.dbg_evictcount(send_hpack)
	testaux.asserteq(evict_count, 0, "hpack queue is prune")
	local id1 = hpack.dbg_stringid(send_hpack, ":path", data[prun_count])
	local id2 = hpack.dbg_stringid(send_hpack, ":path", data[prun_count+1])
	testaux.asserteq((id1 + 1), id2, "Test 0: hpack prune")
end
-- Test 1: Static table indexing
do
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

	local decoded = hpack.unpack(decoder, buffer)

	for k, v in pairs(headers) do
		testaux.asserteq(decoded[k], v, "Test 1: static table index: " .. k)
	end
end

-- Test 2: Integer representation
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Generate a long path to test integer encoding
	local long_path = "/" .. string.rep("a", 300)

	local buffer = hpack.pack(encoder, {}, ":path", long_path)

	local decoded = hpack.unpack(decoder, buffer)

	testaux.asserteq(decoded[":path"], long_path, "Test 2: integer representation")
end

-- Test 3: Huffman encoding
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Header value with various ASCII characters
	local complex_value = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()"

	local buffer = hpack.pack(encoder, {}, "x-custom-header", complex_value)

	local decoded = hpack.unpack(decoder, buffer)

	testaux.asserteq(decoded["x-custom-header"], complex_value, "Test 3: Huffman encoding")
end

-- Test 4: Dynamic table update
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	local buffer1 = hpack.pack(encoder, {}, "custom-header", "value1")
	local buffer2 = hpack.pack(encoder, {}, "custom-header", "value1")

	-- Second encoding should reference dynamic table
	testaux.assertlt(#buffer2, #buffer1, "Test 4: dynamic table update")

	local decoded = hpack.unpack(decoder, buffer1)
	local decoded2 = hpack.unpack(decoder, buffer2)

	testaux.asserteq(decoded["custom-header"], "value1", "Test 4: dynamic table decoding")
	testaux.asserteq(decoded2["custom-header"], "value1", "Test 4: dynamic table decoding")
end

-- Test 5: Special characters
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Header value with special characters
	local special_chars = "Unicode test: Hello world! ñáéíóú 😀🚀"

	local buffer = hpack.pack(encoder, {["x-special"] = special_chars})

	local decoded = hpack.unpack(decoder, buffer)

	testaux.asserteq(decoded["x-special"], special_chars, "Test 5: special characters encoding")
end

-- Test 6: Multiple header fields
do
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
	local decoded = hpack.unpack(decoder, buffer)
	for k, v in pairs(headers) do
		testaux.asserteq(decoded[k], v, "Test 6: multiple header fields: " .. k)
	end
end

-- Test 7: Duplicate header names with different values
do
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

	local decoded = hpack.unpack(decoder, {buffer1, buffer2})
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
end

-- Test 8: Dynamic table eviction
do
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
	testaux.asserteq(cnt, 9, "Test 8: should have 9 evicted headers")

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
	local decoded = hpack.unpack(decoder, table.concat(buffer))
	for _, header in ipairs(headers) do
		testaux.asserteq(decoded[header.name], header.value,
			"Test 8: dynamic table eviction: " .. header.name)
	end
end

-- Test 9: Error handling for malformed input
do
	local decoder = hpack.new(4096)
	-- Test with invalid Huffman sequence
	local invalid_data = string.char(0x80, 0xff, 0xff) -- Invalid Huffman sequence
	local decoded = hpack.unpack(decoder, invalid_data)
	testaux.asserteq(decoded, nil, "Test 9: should handle malformed input gracefully")
end

-- Test 10: Header field size limits
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Create extremely large header value (16KB)
	local large_value = string.rep("x", 16 * 1024)
	local buffer = hpack.pack(encoder, {
		["x-large-header"] = large_value,
	})

	local decoded = hpack.unpack(decoder, buffer)
	testaux.asserteq(decoded["x-large-header"], large_value,
		"Test 10: should handle large header values")
end

-- Test 11: Encoder-decoder synchronization
do
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
		local decoded_req = hpack.unpack(decoder, buf)

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
		local decoded_resp = hpack.unpack(decoder, buf)
		-- Verify response
		for k, v in pairs(exchange.response) do
			testaux.asserteq(decoded_resp[k], v, "Test 11: encoder-decoder sync response: " .. k)
		end
		testaux.asserteq(decoded_resp[":status"], status, "Test 11: encoder-decoder sync response: :status")
	end
end

-- Test 12: Dynamic table size changes during communication
do
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
	local decoded1 = hpack.unpack(decoder, buffer1)
	local decoded2 = hpack.unpack(decoder, buffer2)

	-- Verify all headers
	testaux.asserteq(decoded1["header1"], "value1", "Test 12: pre-resize header1")
	testaux.asserteq(decoded1["header2"], "value2", "Test 12: pre-resize header2")
	testaux.asserteq(decoded1["header3"], "value3", "Test 12: pre-resize header3")

	testaux.asserteq(decoded2["header1"], "value1", "Test 12: post-resize header1")
	testaux.asserteq(decoded2["header4"], "value4", "Test 12: post-resize header4")
	testaux.asserteq(decoded2["header5"], "value5", "Test 12: post-resize header5")
end

-- Test 13: Concurrent encoding sessions
do
	local encoder1 = hpack.new(4096)
	local encoder2 = hpack.new(4096)
	local decoder = hpack.new(4096)

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
	local decoded1 = hpack.unpack(decoder, buffer1)
	local decoded2 = hpack.unpack(decoder, buffer2)

	-- Verify headers from different encoders
	testaux.asserteq(decoded1["session"], "encoder1", "Test 13: encoder1 session")
	testaux.asserteq(decoded1["header1"], "value1-from-encoder1", "Test 13: encoder1 header1")

	testaux.asserteq(decoded2["session"], "encoder2", "Test 13: encoder2 session")
	testaux.asserteq(decoded2["header1"], "value1-from-encoder2", "Test 13: encoder2 header1")
end

-- Test 14: Zero-length header values
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)
	local buffer = hpack.pack(encoder, {
		empty_value = ""
	})

	local decoded = hpack.unpack(decoder, buffer)
	testaux.asserteq(decoded["empty_value"], "", "Test 14: zero-length header value")
end

-- Test 15: Table size update
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)

	-- Change table size
	local new_size = 2048
	hpack.hardlimit(encoder, new_size)

	local buffer = hpack.pack(encoder, {
		["x-custom-header"] =  "test-value"
	})
	local decoded = hpack.unpack(decoder, buffer)
	testaux.asserteq(decoded["x-custom-header"], "test-value", "Test 15: table size update")
end

-- Test 16: encode empty table
do
	local encoder = hpack.new(4096)
	local decoder = hpack.new(4096)
	local buffer = hpack.pack(encoder, {})
	local decoded = hpack.unpack(decoder, buffer)
	testaux.asserteq(next(decoded), nil, "Test 16: encode empty table")

	local buffer = hpack.pack(encoder, {
		["x-custom-header"] =  "test-value",
		["cookie"] =  {},
		["x-custom-header2"] =  "test-value2",
	})
	local decoded = hpack.unpack(decoder, buffer)
	testaux.asserteq(decoded["cookie"], nil, "Test 16: encode empty table")
	testaux.asserteq(decoded["x-custom-header"], "test-value", "Test 16: encode empty table")
	testaux.asserteq(decoded["x-custom-header2"], "test-value2", "Test 16: encode empty table")
end
