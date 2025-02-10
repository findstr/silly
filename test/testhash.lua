local P = require "test.print"
local hash = require "core.crypto.hash"
local testaux = require "test.testaux"

-- Predefine test vectors
local test_vectors = {
	sha256 = {
		input = "hello world",
		digest = "\xb9\x4d\x27\xb9\x93\x4d\x3e\x08\xa5\x2e\x52\xd7\xda\x7d\xab\xfa\xc4\x84\xef\xe3\x7a\x53\x80\xee\x90\x88\xf7\xac\xe2\xef\xcd\xe9",
		empty_digest = "\xe3\xb0\xc4\x42\x98\xfc\x1c\x14\x9a\xfb\xf4\xc8\x99\x6f\xb9\x24\x27\xae\x41\xe4\x64\x9b\x93\x4c\xa4\x95\x99\x1b\x78\x52\xb8\x55",
		large_digest = "\xcd\xc7\x6e\x5c\x99\x14\xfb\x92\x81\xa1\xc7\xe2\x84\xd7\x3e\x67\xf1\x80\x9a\x48\xa4\x97\x20\x0e\x04\x6d\x39\xcc\xc7\x11\x2c\xd0"
	},
	md5 = {
		input = "hello world",
		digest = "\x5e\xb6\x3b\xbb\xe0\x1e\xee\xd0\x93\xcb\x22\xbb\x8f\x5a\xcd\xc3"
	},
	sha1 = {
		input = "hello world",
		digest = "\x2a\xae\x6c\x35\xc9\x4f\xcf\xb4\x15\xdb\xe9\x5f\x40\x8b\x9c\xe9\x1e\xe8\x46\xed"
	}
}

-- Test 1: Basic hash creation and finalization
do
	local h = hash.new("sha256")
	h:update(test_vectors.sha256.input)
	local result = h:final()
	testaux.asserteq_hex(result, test_vectors.sha256.digest, "Case 1: SHA-256 basic test")
end

-- Test 2: Hash reset and reuse
do
	local h = hash.new("sha256")
	h:update("hello")
	h:reset()
	h:update(test_vectors.sha256.input)
	testaux.asserteq_hex(h:final(), test_vectors.sha256.digest, "Case 2: SHA-256 reset test")
end

-- Test 3: Different hash algorithms
do
	-- MD5 test
	local h = hash.new("md5")
	h:update(test_vectors.md5.input)
	testaux.asserteq_hex(h:final(), test_vectors.md5.digest, "Case 3: MD5 test")

	-- SHA-1 test
	local h = hash.new("sha1")
	h:update(test_vectors.sha1.input)
	testaux.asserteq_hex(h:final(), test_vectors.sha1.digest, "Case 3: SHA-1 test")
end

-- Test 4: Empty input
do
	local h = hash.new("sha256")
	testaux.asserteq_hex(h:final(), test_vectors.sha256.empty_digest, "Case 4: SHA-256 empty input")
end

-- Test 5: Large input
do
	local h = hash.new("sha256")
	h:update(string.rep("a", 1000000))
	testaux.asserteq_hex(h:final(), test_vectors.sha256.large_digest, "Case 5: SHA-256 large input")
end

-- Test 6: Test shortcut functions
do
	-- Test digest function
	local result = hash.hash("sha256", test_vectors.sha256.input)
	testaux.asserteq_hex(result, test_vectors.sha256.digest, "Case 6: SHA-256 digest shortcut function")

	-- Test algorithm-specific functions (if implemented)
	if hash.sha256 then
		local result2 = hash.sha256(test_vectors.sha256.input)
		testaux.asserteq_hex(result2, test_vectors.sha256.digest, "Case 6: SHA-256 dedicated function")
	end
end

-- Test 7: Chunked update test
do
	local h = hash.new("sha256")
	h:update("hello")
	h:update(" ")
	h:update("world")
	testaux.asserteq_hex(h:final(), test_vectors.sha256.digest, "Case 7: Chunked update test")
end

-- Test 8: Invalid algorithm test
do
	local status, err = pcall(hash.new, "invalid_algorithm")
	testaux.asserteq(not status, true, "Case 8: Should reject invalid algorithm")
end

-- Test 9: Empty input for shortcut function
do
	local result = hash.hash("sha256", "")
	testaux.asserteq_hex(result, test_vectors.sha256.empty_digest, "Case 9: SHA-256 empty input shortcut")
end

-- Test 10: Binary safety test
do
	local binary_data = "\x00\xff\x80\x7f"
	local h = hash.new("sha256")
	h:update(binary_data)
	local result1 = h:final()

	-- Test shortcut function
	local result2 = hash.hash("sha256", binary_data)
	testaux.asserteq_hex(result1, result2, "Case 10: Binary data consistency test")
end
