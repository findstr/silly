local buffer = require "silly.adt.buffer"
local testaux = require "test.testaux"

local function build(n)
	local tbl = {}
	local char = string.char
	for i = 1, n do
		tbl[i] = char(i % 56 + 97)
	end
	return table.concat(tbl)
end

-- Test 1: Basic buffer creation and size
testaux.case("Test 1: Basic buffer creation and size", function()
	local b = buffer.new()
	testaux.asserteq(type(b), "userdata", "new returns userdata")
	testaux.asserteq(buffer.size(b), 0, "new buffer size == 0")

	local state = buffer.dump(b)
	testaux.asserteq(state.bytes, 0, "dump: bytes == 0")
	testaux.asserteq(state.cap, 0, "dump: cap == 0")
	testaux.asserteq(state.readi, 0, "dump: readi == 0")
	testaux.asserteq(state.writei, 0, "dump: writei == 0")
	testaux.asserteq(state.offset, 0, "dump: offset == 0")
end)

-- Test 2: Single append and read
testaux.case("Test 2: Single append and read", function()
	local b = buffer.new()
	local bytes = buffer.append(b, "hello")
	testaux.asserteq(bytes, 5, "append returns total bytes")
	testaux.asserteq(buffer.size(b), 5, "size after append")

	local data = buffer.read(b, 5)
	testaux.asserteq(data, "hello", "read data matches")
	testaux.asserteq(buffer.size(b), 0, "size after read is 0")
end)

-- Test 3: Multiple appends
testaux.case("Test 3: Multiple appends", function()
	local b = buffer.new()
	buffer.append(b, "foo")
	buffer.append(b, "bar")
	buffer.append(b, "baz")

	testaux.asserteq(buffer.size(b), 9, "total size after 3 appends")

	local data = buffer.read(b, 9)
	testaux.asserteq(data, "foobarbaz", "read all data")
	testaux.asserteq(buffer.size(b), 0, "size after read")
end)

-- Test 4: Partial read - offset handling
testaux.case("Test 4: Partial read - offset handling", function()
	local b = buffer.new()
	buffer.append(b, "hello")

	local data1 = buffer.read(b, 2)
	testaux.asserteq(data1, "he", "first partial read")
	testaux.asserteq(buffer.size(b), 3, "size after partial read")

	local state = buffer.dump(b)
	testaux.asserteq(state.bytes, 3, "dump: bytes == 3 (consumed 2)")
	testaux.asserteq(state.offset, 2, "dump: offset == 2 after partial read")
	testaux.asserteq(state.readi, 0, "dump: readi still 0")
	testaux.asserteq(state.writei, 1, "dump: writei == 1 (one node)")

	local data2 = buffer.read(b, 2)
	testaux.asserteq(data2, "ll", "second partial read")
	testaux.asserteq(buffer.size(b), 1, "size after second partial read")

	state = buffer.dump(b)
	testaux.asserteq(state.bytes, 1, "dump: bytes == 1")
	testaux.asserteq(state.offset, 4, "dump: offset == 4 after second read")

	local data3 = buffer.read(b, 1)
	testaux.asserteq(data3, "o", "third partial read")
	testaux.asserteq(buffer.size(b), 0, "size after all reads")

	state = buffer.dump(b)
	testaux.asserteq(state.bytes, 0, "dump: bytes == 0")
	testaux.asserteq(state.readi, 1, "dump: node popped, readi == 1")
	testaux.asserteq(state.offset, 0, "dump: offset reset after pop")
end)

-- Test 4b: Long string with multiple partial reads - offset progression
testaux.case("Test 4b: Long string with multiple partial reads - offset progression", function()
	local b = buffer.new()

	-- Create a long string (1024 bytes) that won't be interned
	local long_str = string.rep("0123456789", 102) .. "0123"  -- 1024 bytes
	testaux.asserteq(#long_str, 1024, "long string is 1024 bytes")

	buffer.append(b, long_str)
	testaux.asserteq(buffer.size(b), 1024, "buffer size is 1024")

	local state = buffer.dump(b)
	testaux.asserteq(state.readi, 0, "initial readi == 0")
	testaux.asserteq(state.writei, 1, "initial writei == 1 (single node)")
	testaux.asserteq(state.offset, 0, "initial offset == 0")

	-- Read in 100-byte chunks, verify offset progression
	local chunks = {}
	for i = 1, 10 do
		local chunk = buffer.read(b, 100)
		testaux.asserteq(#chunk, 100, string.format("chunk %d is 100 bytes", i))
		table.insert(chunks, chunk)

		local s = buffer.dump(b)
		local expected_offset = i * 100
		local expected_remaining = 1024 - expected_offset

		testaux.asserteq(s.offset, expected_offset, string.format("offset == %d after %d chunks", expected_offset, i))
		testaux.asserteq(s.bytes, expected_remaining, string.format("bytes == %d after %d chunks", expected_remaining, i))
		testaux.asserteq(s.readi, 0, "readi still 0 (same node)")
		testaux.asserteq(s.writei, 1, "writei still 1 (same node)")
		testaux.asserteq(buffer.size(b), expected_remaining, string.format("size == %d", expected_remaining))
	end

	-- Read last 24 bytes
	local last_chunk = buffer.read(b, 24)
	testaux.asserteq(#last_chunk, 24, "last chunk is 24 bytes")
	table.insert(chunks, last_chunk)

	-- Verify buffer is now empty
	local final_state = buffer.dump(b)
	testaux.asserteq(buffer.size(b), 0, "buffer empty after all reads")
	testaux.asserteq(final_state.readi, 1, "node popped, readi == 1")
	testaux.asserteq(final_state.offset, 0, "offset reset after pop")

	-- Verify concatenated chunks match original string
	local reconstructed = table.concat(chunks)
	testaux.asserteq(reconstructed, long_str, "reconstructed data matches original")
end)

-- Test 5: Partial read across multiple nodes - offset handling
testaux.case("Test 5: Partial read across multiple nodes - offset handling", function()
	local b = buffer.new()
	buffer.append(b, "abc")
	buffer.append(b, "def")
	buffer.append(b, "ghi")

	testaux.asserteq(buffer.size(b), 9, "total size")

	-- Read less than first node
	local d1 = buffer.read(b, 2)
	testaux.asserteq(d1, "ab", "read 2 bytes from first node")
	testaux.asserteq(buffer.size(b), 7, "size after partial read")

	-- Read rest of first node + part of second
	local d2 = buffer.read(b, 3)
	testaux.asserteq(d2, "cde", "read across node boundary")
	testaux.asserteq(buffer.size(b), 4, "size after cross-node read")

	-- Read rest
	local d3 = buffer.read(b, 4)
	testaux.asserteq(d3, "fghi", "read remaining")
	testaux.asserteq(buffer.size(b), 0, "buffer empty")
end)

-- Test 6: Read from empty buffer
testaux.case("Test 6: Read from empty buffer", function()
	local b = buffer.new()
	local data = buffer.read(b, 1)
	testaux.asserteq(data, nil, "read from empty returns nil")
end)

-- Test 7: Read zero bytes
testaux.case("Test 7: Read zero bytes", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local data = buffer.read(b, 0)
	testaux.asserteq(data, "", "read 0 returns empty string")
	testaux.asserteq(buffer.size(b), 4, "size unchanged")
end)

-- Test 8: Read negative bytes
testaux.case("Test 8: Read negative bytes", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local data = buffer.read(b, -1)
	testaux.asserteq(data, "", "read negative returns empty string")
	testaux.asserteq(buffer.size(b), 4, "size unchanged")
end)

-- Test 9: Read more than available
testaux.case("Test 9: Read more than available", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local data = buffer.read(b, 10)
	testaux.asserteq(data, nil, "read over size returns nil")
	testaux.asserteq(buffer.size(b), 4, "size unchanged")
end)

-- Test 10: Append empty string
testaux.case("Test 10: Append empty string", function()
	local b = buffer.new()
	local bytes = buffer.append(b, "")
	testaux.asserteq(bytes, 0, "append empty returns 0")
	testaux.asserteq(buffer.size(b), 0, "size remains 0")
end)

-- Test 11: Readline basic - single delimiter
testaux.case("Test 11: Readline basic - single delimiter", function()
	local b = buffer.new()
	buffer.append(b, "hello\n")

	local line = buffer.read(b, "\n")
	testaux.asserteq(line, "hello\n", "readline includes delimiter")
	testaux.asserteq(buffer.size(b), 0, "buffer empty after readline")
end)

-- Test 12: Readline - delimiter not found
testaux.case("Test 12: Readline - delimiter not found", function()
	local b = buffer.new()
	buffer.append(b, "hello")

	local line = buffer.read(b, "\n")
	testaux.asserteq(line, nil, "readline returns nil when no delimiter")
	testaux.asserteq(buffer.size(b), 5, "size unchanged")
end)

-- Test 13: Readline - multiple lines
testaux.case("Test 13: Readline - multiple lines", function()
	local b = buffer.new()
	buffer.append(b, "line1\nline2\nline3\n")

	local l1 = buffer.read(b, "\n")
	testaux.asserteq(l1, "line1\n", "first line")

	local l2 = buffer.read(b, "\n")
	testaux.asserteq(l2, "line2\n", "second line")

	local l3 = buffer.read(b, "\n")
	testaux.asserteq(l3, "line3\n", "third line")

	testaux.asserteq(buffer.size(b), 0, "buffer empty")
end)

-- Test 14: Readline - across multiple nodes
testaux.case("Test 14: Readline - across multiple nodes", function()
	local b = buffer.new()
	buffer.append(b, "hel")
	buffer.append(b, "lo\nwo")
	buffer.append(b, "rld\n")

	local l1 = buffer.read(b, "\n")
	testaux.asserteq(l1, "hello\n", "line across nodes")

	local l2 = buffer.read(b, "\n")
	testaux.asserteq(l2, "world\n", "second line")

	testaux.asserteq(buffer.size(b), 0, "buffer empty")
end)

-- Test 15: Readline - delimiter at start
testaux.case("Test 15: Readline - delimiter at start", function()
	local b = buffer.new()
	buffer.append(b, "\nhello")

	local line = buffer.read(b, "\n")
	testaux.asserteq(line, "\n", "empty line with delimiter")
	testaux.asserteq(buffer.size(b), 5, "rest remains")
end)

-- Test 16: Readline - empty delimiter error
testaux.case("Test 16: Readline - empty delimiter error", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local ok, err = pcall(function() buffer.read(b, "") end)
	testaux.asserteq(ok, false, "empty delimiter throws error")
	testaux.asserteq(not not err:find("delimiter length must be 1"), true, "error message correct")
end)

-- Test 17: Readline - multi-char delimiter error
testaux.case("Test 17: Readline - multi-char delimiter error", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local ok, err = pcall(function() buffer.read(b, "\\r\\n") end)
	testaux.asserteq(ok, false, "multi-char delimiter throws error")
	testaux.asserteq(not not err:find("delimiter length must be 1"), true, "error message correct")
end)

-- Test 18: Switch delimiter - cache invalidation
testaux.case("Test 18: Switch delimiter - cache invalidation", function()
	local b = buffer.new()
	buffer.append(b, "a")
	buffer.append(b, "b")
	buffer.append(b, "cd")
	buffer.append(b, "e\rf")

	-- Try reading with \n (not found)
	local x = buffer.read(b, "\n")
	testaux.asserteq(x, nil, "delimiter not found")

	-- Switch to \r (should invalidate cache)
	local y = buffer.read(b, "\r")
	testaux.asserteq(y, "abcde\r", "switched delimiter found")
	testaux.asserteq(buffer.size(b), 1, "one byte left")

	local z = buffer.read(b, 1)
	testaux.asserteq(z, "f", "read last char")
end)

-- Test 19: Large data append and read
testaux.case("Test 19: Large data append and read", function()
	local b = buffer.new()
	local big = build(1024 * 128)

	buffer.append(b, big)
	testaux.asserteq(buffer.size(b), #big, "size matches")

	local data = buffer.read(b, #big)
	testaux.asserteq(data, big, "large data matches")
	testaux.asserteq(buffer.size(b), 0, "buffer empty")
end)

-- Test 20: Buffer capacity expansion
testaux.case("Test 20: Buffer capacity expansion", function()
	local b = buffer.new()

	-- Initial state
	local state = buffer.dump(b)
	testaux.asserteq(state.cap, 0, "initial capacity 0")

	-- Add nodes to trigger expansion
	for i = 1, 64 do
		buffer.append(b, "a")
	end

	state = buffer.dump(b)
	testaux.asserteq(state.cap >= 64, true, "capacity expanded to fit 64 nodes")
	testaux.asserteq(state.writei, 64, "writei == 64")

	-- Read all
	buffer.read(b, 64)
	testaux.asserteq(buffer.size(b), 0, "buffer empty")

	state = buffer.dump(b)
	testaux.asserteq(state.readi, 64, "readi == 64 after reading all")

	-- Add more to test compaction
	for i = 1, 65 do
		buffer.append(b, "a")
	end

	state = buffer.dump(b)
	testaux.asserteq(state.cap >= 65, true, "capacity expanded again")
	testaux.asserteq(state.readi, 0, "readi compacted to 0")
	testaux.asserteq(state.writei, 65, "writei == 65")
end)

-- Test 21: Offset handling - partial consume then append
testaux.case("Test 21: Offset handling - partial consume then append", function()
	local b = buffer.new()
	buffer.append(b, "hello")

	-- Partial read creates offset
	buffer.read(b, 2)
	testaux.asserteq(buffer.size(b), 3, "3 bytes remain")

	-- Append new data
	buffer.append(b, "world")
	testaux.asserteq(buffer.size(b), 8, "size is 3 + 5")

	-- Read all should be "lloworld"
	local data = buffer.read(b, 8)
	testaux.asserteq(data, "lloworld", "offset preserved correctly")
end)

-- Test 22: Offset handling - readline with partial node
testaux.case("Test 22: Offset handling - readline with partial node", function()
	local b = buffer.new()
	buffer.append(b, "abcdef\ngh")

	-- Read 2 bytes creates offset in first node
	buffer.read(b, 2)
	testaux.asserteq(buffer.size(b), 7, "7 bytes remain (9 - 2)")

	-- Readline from offset position
	local line = buffer.read(b, "\n")
	testaux.asserteq(line, "cdef\n", "readline from offset")
	testaux.asserteq(buffer.size(b), 2, "2 bytes remain")
end)

-- Test 23: Offset reset after pop
testaux.case("Test 23: Offset reset after pop", function()
	local b = buffer.new()
	buffer.append(b, "12345")
	buffer.append(b, "67890")

	-- Partial read first node (offset = 3)
	buffer.read(b, 3)
	testaux.asserteq(buffer.size(b), 7, "7 bytes remain")

	-- Read rest of first node (should pop and reset offset)
	buffer.read(b, 2)
	testaux.asserteq(buffer.size(b), 5, "5 bytes remain")

	-- Read from second node (offset should be 0)
	local data = buffer.read(b, 5)
	testaux.asserteq(data, "67890", "second node read correctly")
end)

-- Test 24: Interleaved operations
testaux.case("Test 24: Interleaved operations", function()
	local b = buffer.new()

	buffer.append(b, "foo")
	testaux.asserteq(buffer.size(b), 3, "size 3")

	buffer.read(b, 1)
	testaux.asserteq(buffer.size(b), 2, "size 2 after read")

	buffer.append(b, "bar")
	testaux.asserteq(buffer.size(b), 5, "size 5 after append")

	buffer.read(b, 2)
	testaux.asserteq(buffer.size(b), 3, "size 3 after read")

	buffer.append(b, "baz")
	testaux.asserteq(buffer.size(b), 6, "size 6 after append")

	local data = buffer.read(b, 6)
	testaux.asserteq(data, "barbaz", "final data correct")
end)

-- Test 25: String reuse optimization
testaux.case("Test 25: String reuse optimization", function()
	local b = buffer.new()
	local testaux_c = require "test.aux.c"

	-- Test with short string (will be interned)
	local short_str = "test_string"
	buffer.append(b, short_str)

	-- Read exact size with no offset should reuse string
	local read_short = buffer.read(b, #short_str)
	testaux.asserteq(read_short, short_str, "short string data matches")
	testaux.asserteq(testaux_c.pointer(read_short), testaux_c.pointer(short_str),
		"short string reused (same pointer)")
end)

-- Test 25b: Long string reuse optimization
testaux.case("Test 25b: Long string reuse optimization (non-interned)", function()
	local b = buffer.new()
	local testaux_c = require "test.aux.c"

	-- Lua doesn't intern long strings (typically > 40 bytes)
	-- Create a long string that won't be interned
	local long_str = string.rep("abcdefghij", 100)  -- 1000 bytes
	testaux.asserteq(#long_str, 1000, "long string is 1000 bytes")

	buffer.append(b, long_str)

	-- Read exact size with no offset should reuse string via ref table
	local read_long = buffer.read(b, #long_str)
	testaux.asserteq(read_long, long_str, "long string data matches")
	testaux.asserteq(testaux_c.pointer(read_long), testaux_c.pointer(long_str),
		"long string reused (same pointer via ref)")
end)

-- Test 25c: Partial read doesn't reuse string
testaux.case("Test 25c: Partial read creates new string", function()
	local b = buffer.new()
	local testaux_c = require "test.aux.c"

	local long_str = string.rep("xyz", 100)  -- 300 bytes
	buffer.append(b, long_str)

	-- Partial read should create new string
	local partial = buffer.read(b, 100)
	testaux.asserteq(#partial, 100, "partial read size correct")
	testaux.assertneq(testaux_c.pointer(partial), testaux_c.pointer(long_str),
		"partial read creates new string (different pointer)")
end)

-- Test 26: Readline with partial read before
testaux.case("Test 26: Readline with partial read before", function()
	local b = buffer.new()
	buffer.append(b, "12345\n67890")

	-- Partial byte read
	buffer.read(b, 2)

	-- Readline should work from offset
	local line = buffer.read(b, "\n")
	testaux.asserteq(line, "345\n", "readline after partial read")

	local rest = buffer.read(b, 5)
	testaux.asserteq(rest, "67890", "rest correct")
end)

-- Test 27: Multiple delimiters in sequence
testaux.case("Test 27: Multiple delimiters in sequence", function()
	local b = buffer.new()
	buffer.append(b, "\n\n\n")

	local l1 = buffer.read(b, "\n")
	testaux.asserteq(l1, "\n", "first empty line")

	local l2 = buffer.read(b, "\n")
	testaux.asserteq(l2, "\n", "second empty line")

	local l3 = buffer.read(b, "\n")
	testaux.asserteq(l3, "\n", "third empty line")

	testaux.asserteq(buffer.size(b), 0, "buffer empty")
end)

-- Test 28: Readline delimiter caching
testaux.case("Test 28: Readline delimiter caching", function()
	local b = buffer.new()
	buffer.append(b, "line1\nline2\nline3\n")

	-- First readline should scan and cache
	local l1 = buffer.read(b, "\n")
	testaux.asserteq(l1, "line1\n", "first line")

	local state = buffer.dump(b)
	testaux.asserteq(state.delim, string.byte("\n"), "delimiter cached")
	testaux.asserteq(state.delim_last_checki >= state.readi, true, "delim_last_checki valid")

	-- Second readline should use cache (delim_last_checki)
	local l2 = buffer.read(b, "\n")
	testaux.asserteq(l2, "line2\n", "second line cached scan")

	local l3 = buffer.read(b, "\n")
	testaux.asserteq(l3, "line3\n", "third line")
end)

-- Test 29: Garbage collection - buffer cleanup
testaux.case("Test 29: Garbage collection - buffer cleanup", function()
	-- Create and discard many buffers
	for i = 1, 100 do
		local b = buffer.new()
		for j = 1, 10 do
			buffer.append(b, "data" .. j)
		end
		-- Buffer goes out of scope
	end

	collectgarbage("collect")

	-- Verify new buffer still works
	local b = buffer.new()
	buffer.append(b, "test")
	testaux.asserteq(buffer.read(b, 4), "test", "buffer works after GC")
end)

-- Test 30: Reference table cleanup verification
testaux.case("Test 30: Reference table cleanup verification", function()
	local b = buffer.new()

	-- Helper function to count refs for a specific string
	local function count_refs(refs, target_str)
		local count = 0
		for k, v in pairs(refs) do
			if v == target_str then
				count = count + 1
			end
		end
		return count
	end

	-- Append same string multiple times
	buffer.append(b, "string1")
	buffer.append(b, "string1")
	buffer.append(b, "string2")

	local state1 = buffer.dump(b)
	testaux.asserteq(count_refs(state1.refs, "string1"), 2, "string1 has 2 refs")
	testaux.asserteq(count_refs(state1.refs, "string2"), 1, "string2 has 1 ref")

	-- Read first "string1" (7 bytes)
	buffer.read(b, 7)

	local state2 = buffer.dump(b)
	testaux.asserteq(count_refs(state2.refs, "string1"), 1, "string1 has 1 ref after reading one")
	testaux.asserteq(count_refs(state2.refs, "string2"), 1, "string2 still has 1 ref")

	-- Read second "string1"
	buffer.read(b, 7)

	local state3 = buffer.dump(b)
	testaux.asserteq(count_refs(state3.refs, "string1"), 0, "string1 has 0 refs after reading both")
	testaux.asserteq(count_refs(state3.refs, "string2"), 1, "string2 still has 1 ref")

	-- Read "string2"
	buffer.read(b, 7)

	local state4 = buffer.dump(b)
	testaux.asserteq(count_refs(state4.refs, "string1"), 0, "string1 still 0 refs")
	testaux.asserteq(count_refs(state4.refs, "string2"), 0, "string2 now has 0 refs")

	-- Verify refs table is actually empty
	local total_refs = 0
	for k, v in pairs(state4.refs) do
		total_refs = total_refs + 1
	end
	testaux.asserteq(total_refs, 0, "refs table is completely empty")
end)

-- Test 30b: Reference ID recycling
testaux.case("Test 30b: Reference ID recycling", function()
	local b = buffer.new()

	-- Helper to get all ref ids from refs table
	local function get_ref_ids(refs)
		local ids = {}
		for k, v in pairs(refs) do
			table.insert(ids, k)
		end
		table.sort(ids)
		return ids
	end

	-- Append 3 strings, collect their ref ids
	buffer.append(b, "first")
	buffer.append(b, "second")
	buffer.append(b, "third")

	local state1 = buffer.dump(b)
	local ids1 = get_ref_ids(state1.refs)
	testaux.asserteq(#ids1, 3, "3 ref ids allocated")

	-- Ids should be 1, 2, 3 (allocated sequentially)
	testaux.asserteq(ids1[1], 1, "first ref id is 1")
	testaux.asserteq(ids1[2], 2, "second ref id is 2")
	testaux.asserteq(ids1[3], 3, "third ref id is 3")

	-- Read all strings (ids freed in order: 1, 2, 3)
	buffer.read(b, 5)   -- "first" - frees id 1
	buffer.read(b, 6)   -- "second" - frees id 2
	buffer.read(b, 5)   -- "third" - frees id 3

	local state2 = buffer.dump(b)
	testaux.asserteq(next(state2.refs), nil, "refs table empty after reading all")

	-- Append new strings - should reuse freed ids in LIFO order (stack)
	-- Free order was: 1, 2, 3 -> Stack: [3, 2, 1]
	-- So first alloc gets 3, second alloc gets 2
	buffer.append(b, "new1")
	buffer.append(b, "new2")

	local state3 = buffer.dump(b)
	local ids3 = get_ref_ids(state3.refs)
	testaux.asserteq(#ids3, 2, "2 ref ids allocated")

	-- Stack-based reuse: last freed (3) is used first, then 2
	testaux.asserteq(ids3[1], 2, "reused ref id 2 (second from stack)")
	testaux.asserteq(ids3[2], 3, "reused ref id 3 (top of stack)")

	-- Read one string (frees id 3), then append another
	buffer.read(b, 4)  -- "new1" - frees id 3

	buffer.append(b, "new3")

	local state4 = buffer.dump(b)
	local ids4 = get_ref_ids(state4.refs)
	testaux.asserteq(#ids4, 2, "2 ref ids after partial read")

	-- Should have id 2 (from "new2") and reused id 3 (from "new3")
	table.sort(ids4)
	testaux.asserteq(ids4[1], 2, "id 2 still held by new2")
	testaux.asserteq(ids4[2], 3, "id 3 was recycled for new3")
end)

-- Test 31: Reference cleanup with partial reads
testaux.case("Test 31: Reference cleanup with partial reads", function()
	local b = buffer.new()

	local function count_refs(refs, target_str)
		local count = 0
		for k, v in pairs(refs) do
			if v == target_str then
				count = count + 1
			end
		end
		return count
	end

	buffer.append(b, "abcdefgh")  -- 8 bytes
	buffer.append(b, "12345678")  -- 8 bytes
	buffer.append(b, "abcdefgh")  -- 8 bytes, same as first

	local state1 = buffer.dump(b)
	testaux.asserteq(count_refs(state1.refs, "abcdefgh"), 2, "abcdefgh has 2 refs initially")
	testaux.asserteq(count_refs(state1.refs, "12345678"), 1, "12345678 has 1 ref initially")

	-- Partial read from first node (3 bytes)
	buffer.read(b, 3)  -- Reads "abc" from "abcdefgh"

	local state2 = buffer.dump(b)
	-- First node still exists with offset, so ref should still be there
	testaux.asserteq(count_refs(state2.refs, "abcdefgh"), 2, "abcdefgh still has 2 refs after partial read")

	-- Read rest of first node (5 bytes) - this should pop the node
	buffer.read(b, 5)  -- Reads "defgh", completes first "abcdefgh"

	local state3 = buffer.dump(b)
	testaux.asserteq(count_refs(state3.refs, "abcdefgh"), 1, "abcdefgh has 1 ref after first node popped")
	testaux.asserteq(count_refs(state3.refs, "12345678"), 1, "12345678 still has 1 ref")

	-- Read all of second node
	buffer.read(b, 8)

	local state4 = buffer.dump(b)
	testaux.asserteq(count_refs(state4.refs, "abcdefgh"), 1, "abcdefgh still has 1 ref (third node)")
	testaux.asserteq(count_refs(state4.refs, "12345678"), 0, "12345678 now has 0 refs")

	-- Read all of third node
	buffer.read(b, 8)

	local state5 = buffer.dump(b)
	testaux.asserteq(count_refs(state5.refs, "abcdefgh"), 0, "abcdefgh now has 0 refs")

	local total_refs = 0
	for k, v in pairs(state5.refs) do
		total_refs = total_refs + 1
	end
	testaux.asserteq(total_refs, 0, "refs table is empty")
end)

-- Test 32: Reference cleanup across node boundaries
testaux.case("Test 32: Reference cleanup across node boundaries", function()
	local b = buffer.new()

	local function count_refs(refs, target_str)
		local count = 0
		for k, v in pairs(refs) do
			if v == target_str then
				count = count + 1
			end
		end
		return count
	end

	buffer.append(b, "AAA")  -- 3 bytes
	buffer.append(b, "BBB")  -- 3 bytes
	buffer.append(b, "CCC")  -- 3 bytes

	local state1 = buffer.dump(b)
	testaux.asserteq(count_refs(state1.refs, "AAA"), 1, "AAA has 1 ref")
	testaux.asserteq(count_refs(state1.refs, "BBB"), 1, "BBB has 1 ref")
	testaux.asserteq(count_refs(state1.refs, "CCC"), 1, "CCC has 1 ref")

	-- Read across boundaries: 3 bytes from AAA + 1 byte from BBB
	buffer.read(b, 4)

	local state2 = buffer.dump(b)
	testaux.asserteq(count_refs(state2.refs, "AAA"), 0, "AAA ref cleared (node popped)")
	testaux.asserteq(count_refs(state2.refs, "BBB"), 1, "BBB still has ref (partial, 2 bytes left)")
	testaux.asserteq(count_refs(state2.refs, "CCC"), 1, "CCC still has ref")

	-- Read rest: 2 bytes from BBB + 3 bytes from CCC = 5 bytes total
	buffer.read(b, 5)

	local state3 = buffer.dump(b)
	testaux.asserteq(count_refs(state3.refs, "AAA"), 0, "AAA still 0 refs")
	testaux.asserteq(count_refs(state3.refs, "BBB"), 0, "BBB ref cleared")
	testaux.asserteq(count_refs(state3.refs, "CCC"), 0, "CCC ref cleared")

	local total_refs = 0
	for k, v in pairs(state3.refs) do
		total_refs = total_refs + 1
	end
	testaux.asserteq(total_refs, 0, "all refs cleared")
	testaux.asserteq(buffer.size(b), 0, "buffer is empty")
end)

-- Test 33: Invalid argument type for read
testaux.case("Test 33: Invalid argument type for read", function()
	local b = buffer.new()
	buffer.append(b, "test")

	local ok, err = pcall(function() buffer.read(b, {}) end)
	testaux.asserteq(ok, false, "invalid read type throws")
	testaux.asserteq(not not err:find("bad argument #2 to 'read'"), true, "error message mentions invalid")
end)

-- Test 34: Invalid argument type for append
testaux.case("Test 34: Invalid argument type for append", function()
	local b = buffer.new()

	local ok, err = pcall(function() buffer.append(b, 123) end)
	testaux.asserteq(ok, false, "invalid append type throws")
	testaux.asserteq(not not err:find("invalid"), true, "error message mentions invalid")
end)

-- Test 35: Stress test - many nodes
testaux.case("Test 35: Stress test - many nodes", function()
	local b = buffer.new()
	local N = 1000

	-- Append many small chunks
	for i = 1, N do
		buffer.append(b, "x")
	end

	testaux.asserteq(buffer.size(b), N, "size matches")

	-- Read all at once
	local data = buffer.read(b, N)
	testaux.asserteq(#data, N, "read size correct")
	testaux.asserteq(data, string.rep("x", N), "data correct")
end)

-- Test 36: Stress test - interleaved push/pop
testaux.case("Test 36: Stress test - interleaved push/pop", function()
	local b = buffer.new()

	for round = 1, 100 do
		-- Push 5
		for i = 1, 5 do
			buffer.append(b, tostring(round * 10 + i))
		end

		-- Pop 3
		for i = 1, 3 do
			buffer.read(b, #tostring(round * 10 + i))
		end
	end

	-- Should have 100 * 2 = 200 items left
	local size = buffer.size(b)
	testaux.asserteq(size > 0, true, "buffer not empty")

	-- Drain
	buffer.read(b, size)
	testaux.asserteq(buffer.size(b), 0, "buffer drained")
end)

print("All buffer tests completed successfully!")
