local xor = require "silly.crypto.utils".xor
local testaux = require "test.testaux"

-- Test 1: Basic functionality
do
	local key = "key"
	local data = "hello"
	local result = xor(key, data)
	testaux.assertneq(result, data, "Case 1: XOR result should not be the same as the original data")
end

-- Test 2: Key longer than data
do
	local key = "longer_key"
	local data = "test"
	local result = xor(key, data)
	testaux.assertneq(result, data, "Case 2: XOR result should not be the same as the original data")
end

-- Test 3: Key shorter than data
do
	local key = "k"
	local data = "longerdata"
	local result = xor(key, data)
	testaux.assertneq(result, data, "Case 3: XOR result should not be the same as the original data")
end

-- Test 4: Key and data are identical
do
	local key = "abcdef"
	local result = xor(key, key)
	testaux.asserteq(result, string.rep("\0", #key), "Case 4: XOR of identical data should result in all zero bytes")
end

-- Test 5: Empty data
do
	local key = "key"
	local result = xor(key, "")
	testaux.asserteq(result, "", "Case 5: XOR with empty data should return an empty string")
end

-- Test 6: Empty key (should raise an error)
do
	local status, err = pcall(function() xor("", "test") end)
	testaux.asserteq(status, false, "Case 6: Empty key should trigger an error")
end

-- Test 7: Binary data
do
	local key = "\x0F\x0F\x0F\x0F\x0F"
	local data = "\x01\x02\x03\x04\x05"
	local expected = "\x0E\x0D\x0C\x0B\x0A"
	local result = xor(key, data)
	testaux.asserteq(result, expected, "Case 7: Incorrect XOR result for binary data")
end

-- Test 8: Data longer than key (key repeats)
do
	local key = "XY"
	local data = "ABCDEFGH"
	local expected = string.char(
		string.byte("A") ~ string.byte("X"),
		string.byte("B") ~ string.byte("Y"),
		string.byte("C") ~ string.byte("X"),
		string.byte("D") ~ string.byte("Y"),
		string.byte("E") ~ string.byte("X"),
		string.byte("F") ~ string.byte("Y"),
		string.byte("G") ~ string.byte("X"),
		string.byte("H") ~ string.byte("Y")
	)
	local result = xor(key, data)
	testaux.asserteq(result, expected, "Case 8: Incorrect XOR result for repeating key")
end

-- Test 9: Long data string
do
	local key = "longkey"
	local data = string.rep("A", 1024)
	local result = xor(key, data)
	testaux.asserteq(#result, 1024, "Case 9: XOR result length should match input data length")
end

-- Test 10: UTF-8 compatibility
do
	local key = "密"
	local data = "你好"
	local result = xor(key, data)
	testaux.assertneq(result, data, "Case 10: UTF-8 XOR result should not be the same as the original data")
end

print("All XOR unit tests passed!")