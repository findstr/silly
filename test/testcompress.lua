local gzip = require "silly.compress.gzip"
local testaux = require "test.testaux"

local ok, snappy = pcall(require, "silly.compress.snappy")

local algs = {
	gzip = gzip,
	snappy = ok and snappy or nil,
}

-- Test 1: Basic functionality - compress and decompress
do
	local test_strings = {
		"hello world",
		"",
		"a",
		string.rep("a", 1000),
		"你好世界",
		string.char(0, 1, 2, 3, 255),
	}

	for name, alg in pairs(algs) do
		for i, str in ipairs(test_strings) do
			local compressed = alg.compress(str)
			local decompressed = alg.decompress(compressed)
			testaux.asserteq(decompressed, str, string.format("Case 1: %s basic #%d", name, i))
		end
	end
end

-- Test 2: Large data compression (1MB)
do
	local data = string.rep("X", 1024 * 1024)

	for name, alg in pairs(algs) do
		local compressed = alg.compress(data)
		local decompressed = alg.decompress(compressed)
		testaux.asserteq(decompressed, data, string.format("Case 2: %s large data", name))
		testaux.assertlt(#compressed, #data, string.format("Case 2: %s compression ratio", name))
	end
end

-- Test 3: Invalid input for decompression
do
	for name, alg in pairs(algs) do
		local dat, err = alg.decompress("not a valid stream")
		testaux.asserteq(dat, nil, string.format("Case 3: %s invalid input", name))
	end
end

-- Test 4: Gzip format compliance
do
	-- 4.1 Magic header check
	local compressed = gzip.compress("test")
	local b1, b2 = string.byte(compressed, 1, 2)
	testaux.asserteq(b1, 0x1F, "Case 4.1: Gzip magic byte 1")
	testaux.asserteq(b2, 0x8B, "Case 4.2: Gzip magic byte 2")

	-- 4.2 Decompress data from external gzip tool (echo -n "hello world" | gzip)
	local gzip_data = string.char(
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48,
		0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
		0x2d, 0x3b, 0x08, 0xaf, 0x0c, 0x00, 0x00, 0x00
	)
	local output = gzip.decompress(gzip_data)
	testaux.asserteq(output, "hello world\n", "Case 4.3: Gzip external compatibility")
end

-- Test 5: Snappy format compliance (if available)
if snappy then
	-- Snappy data from Go: snappy.Encode(nil, []byte("hello"))
	-- Go's snappy uses framing format, raw snappy block for "hello" is:
	-- varint(5) + literal "hello"
	local snappy_data = string.char(0x05, 0x10, 0x68, 0x65, 0x6c, 0x6c, 0x6f)
	local output = snappy.decompress(snappy_data)
	testaux.asserteq(output, "hello", "Case 5: Snappy external compatibility")
end
