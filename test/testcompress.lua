local gzip = require "silly.compress.gzip"
local snappy = require "silly.compress.snappy"
local testaux = require "test.testaux"

-- Test 1: Basic functionality - compress and decompress
do
	local test_strings = {
		"hello world", -- 简单字符串
		"", -- 空字符串
		"a", -- 单个字符
		string.rep("a", 1000), -- 重复字符
		"你好世界", -- 非ASCII字符
		string.char(0, 1, 2, 3, 255) -- 二进制数据
	}

	for i, str in ipairs(test_strings) do
		local compressed = gzip.compress(str)
		local decompressed = gzip.decompress(compressed)
		testaux.asserteq(decompressed, str, string.format("Case 1.%d: Basic compress/decompress test", i))
	end
end

-- Test 2: Gzip magic header check
do
	local data = "header check"
	local compressed = gzip.compress(data)

	local b1, b2 = string.byte(compressed, 1, 2)
	testaux.asserteq(b1, 0x1F, "Case 2.1: Gzip header byte 1 should be 0x1F")
	testaux.asserteq(b2, 0x8B, "Case 2.2: Gzip header byte 2 should be 0x8B")
end

-- Test 3: Large data compression
do
	local data = string.rep("G", 1024 * 1024) -- 1MB
	local compressed = gzip.compress(data)
	local decompressed = gzip.decompress(compressed)

	testaux.asserteq(decompressed, data, "Case 3.1: Large data compress/decompress test")
end

-- Test 4: Invalid input for decompression (error handling)
do
	local dat, err = gzip.decompress("not a gzip stream")
	testaux.asserteq(dat, nil, "Case 4.1: Decompressing invalid data should raise error")
end

-- Test 5: Decompress standard gzip binary data from external tool
do
	local gzip_data = string.char(
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48,
		0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
		0x2d, 0x3b, 0x08, 0xaf, 0x0c, 0x00, 0x00, 0x00
	)
	local output = gzip.decompress(gzip_data)
	testaux.asserteq(output, "hello world\n", "Case 5.1: Decompress standard gzip binary data")
end

-- Test 6: Snappy basic functionality - compress and decompress
do
	local test_strings = {
		"hello world", -- 简单字符串
		"", -- 空字符串
		"a", -- 单个字符
		string.rep("a", 1000), -- 重复字符
		"你好世界", -- 非ASCII字符
		string.char(0, 1, 2, 3, 255) -- 二进制数据
	}

	for i, str in ipairs(test_strings) do
		local compressed = snappy.compress(str)
		local decompressed = snappy.decompress(compressed)
		testaux.asserteq(decompressed, str, string.format("Case 6.%d: Snappy basic compress/decompress test", i))
	end
end

-- Test 7: Snappy large data compression
do
	local data = string.rep("S", 1024 * 1024) -- 1MB
	local compressed = snappy.compress(data)
	local decompressed = snappy.decompress(compressed)

	testaux.asserteq(decompressed, data, "Case 7.1: Snappy large data compress/decompress test")
	testaux.assertlt(#compressed, #data, "Case 7.2: Snappy compressed size should be smaller than original")
end

-- Test 8: Snappy invalid input for decompression (error handling)
do
	local dat, err = snappy.decompress("not a snappy stream")
	testaux.asserteq(dat, nil, "Case 8.1: Snappy decompressing invalid data should raise error")
end

-- Test 9: Snappy compression efficiency test
do
	local data = "aaaaaabbbbbbccccccdddddd" -- 重复数据，应该压缩效果好
	local compressed = snappy.compress(data)
	local decompressed = snappy.decompress(compressed)

	testaux.asserteq(decompressed, data, "Case 9.1: Snappy compress/decompress repeated data")
	testaux.assertlt(#compressed, #data, "Case 9.2: Snappy should compress repeated data efficiently")
end
