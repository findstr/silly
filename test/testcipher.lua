local cipher = require "core.crypto.cipher"
local testaux = require "test.testaux"

-- AES test vectors from NIST SP 800-38A
local test_vectors = {
	aes_128_cbc = {
		key = "\x2b\x7e\x15\x16\x28\xae\xd2\xa6\xab\xf7\x15\x88\x09\xcf\x4f\x3c",
		iv  = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
		-- Original 16-byte plaintext + 16-byte PKCS7 padding
		plaintext = "\x6b\xc1\xbe\xe2\x2e\x40\x9f\x96\xe9\x3d\x7e\x11\x73\x93\x17\x2a",
		-- Ciphertext should be 32 bytes (from NIST SP 800-38A F.2.5)
		ciphertext = "\x76\x49\xab\xac\x81\x19\xb2\x46\xce\xe9\x8e\x9b\x12\xe9\x19\x7d"..
			 "\x89\x64\xe0\xb1\x49\xc1\x0b\x7b\x68\x2e\x6e\x39\xaa\xeb\x73\x1c"
	},
	aes_256_gcm = {
		key = "\xfe\xff\xe9\x92\x86\x65\x73\x1c\x6d\x6a\x8f\x94\x67\x30\x83\x08"..
			  "\xfe\xff\xe9\x92\x86\x65\x73\x1c\x6d\x6a\x8f\x94\x67\x30\x83\x08",
		iv = "\xca\xfe\xba\xbe\xfa\xce\xdb\xad\xde\xca\xf8\x88",
		-- GCM uses no padding, maintains original length
		plaintext = "Hello AES-GCM!",
		-- Ciphertext length matches plaintext (14 bytes) + 16-byte TAG
		ciphertext = "\xc3\x79\x9f\xb9\x0e\xf2\x3a\xa7\x02\x0b\x79\x25\xc8\x50",
		tag = "\x7a\xb2\xcb\x98\xa9\xc0\xe6\xb8\x11\x74\x30\x96\xa2\x26\x09\xd2"
	},
	aes_256_cbc = {
		key = "\x60\x3d\xeb\x10\x15\xca\x71\xbe\x2b\x73\xae\xf0\x85\x7d\x77\x81"..
			  "\x1f\x35\x2c\x07\x3b\x61\x08\xd7\x2d\x98\x10\xa3\x09\x14\xdf\xf9",
		iv = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
		-- Original 16-byte plaintext + 16-byte PKCS7 padding
		plaintext = "\x6b\xc1\xbe\xe2\x2e\x40\x9f\x96\xe9\x3d\x7e\x11\x73\x93\x17\x2a",
		-- Ciphertext should be 32 bytes (from NIST SP 800-38A F.2.5)
		ciphertext = "\xc3\x87\xb8\x83\x43\xbb\xf4\x5c\xba\x97\x09\x1d\xb7\x52\x5a\xe7"..
			 "\xe0\x5b\x56\x60\x9b\xd1\x0d\xdb\xed\xb7\xeb\xa8\x03\x33\xea\xa3"
	},
}

-- Test 1: Basic encryption object creation
do
	local c = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c:update(test_vectors.aes_128_cbc.plaintext)
	local encrypted = c:final()
	testaux.asserteq_hex(encrypted, test_vectors.aes_128_cbc.ciphertext, "Case 1: AES-128-CBC encryption")

	c:reset(test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv)
	c:setpadding(0)
	c:update(test_vectors.aes_128_cbc.plaintext)
	local encrypted = c:final()
	testaux.asserteq_hex(encrypted, test_vectors.aes_128_cbc.ciphertext:sub(1,16), "Case 1: AES-128-CBC encryption without padding")
end

-- Test 2: Complete encryption/decryption workflow
do
	-- Encryption process
	local c_enc = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c_enc:update(test_vectors.aes_128_cbc.plaintext)
	local encrypted = c_enc:final()

	-- Decryption process
	local c_dec = cipher.decryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c_dec:update(encrypted)
	local decrypted = c_dec:final()
	testaux.asserteq_hex(decrypted, test_vectors.aes_128_cbc.plaintext, "Case 2: AES-128-CBC decryption")
end

-- Test 3: Shortcut encryption method
do
	local encrypted = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv):final(test_vectors.aes_128_cbc.plaintext)
	testaux.asserteq_hex(encrypted, test_vectors.aes_128_cbc.ciphertext, "Case 3: AES-128-CBC shortcut encryption")
end

-- Test 4: Different key lengths validation
do
	local c = cipher.encryptor("aes-256-cbc",
		test_vectors.aes_256_cbc.key,
		test_vectors.aes_256_cbc.iv
	)
	c:update(test_vectors.aes_256_cbc.plaintext)
	local encrypted = c:final()
	testaux.asserteq_hex(encrypted, test_vectors.aes_256_cbc.ciphertext, "Case 4: AES-256-CBC encryption")
end

-- Test 5: Chunked data processing
do
	local c = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c:update("hello")
	local encrypted = c:final(" world")

	-- Decryption verification
	local c_dec = cipher.decryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c_dec:update(encrypted)
	testaux.asserteq(c_dec:final(), "hello world", "Case 5: Chunked update verification")
end

-- Test 6: Context reuse with reset
do
	local c = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)

	-- First encryption
	c:update("part1")
	local enc1 = c:final()

	-- Reset and reuse
	c:reset(test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv)
	c:update("part2")
	local enc2 = c:final()

	testaux.asserteq(#enc1, #enc2, "Case 6: Context reuse consistency")
end

-- Test 7: Binary data integrity
do
	local binary_data = "\x00\xff\x7f\x80"
	local encrypted = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv):final(binary_data)

	-- Decryption verification
	local decrypted = cipher.decryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv):final(encrypted)
	testaux.asserteq_hex(decrypted, binary_data, "Case 7: Binary data consistency")
end

-- Test 8: Authenticated encryption (GCM)
do
	local gcm = cipher.encryptor("aes-256-gcm",
		test_vectors.aes_256_gcm.key,
		test_vectors.aes_256_gcm.iv
	)
	local ciphertext = gcm:final(test_vectors.aes_256_gcm.plaintext)
	local tag = gcm:tag()
	-- Extract ciphertext and authentication tag
	testaux.asserteq_hex(ciphertext, test_vectors.aes_256_gcm.ciphertext, "Case 8: AES-256-GCM ciphertext")
	testaux.asserteq_hex(tag, test_vectors.aes_256_gcm.tag, "Case 8: AES-256-GCM authentication tag")
end

-- Test 9: Empty input handling
do
	local encrypted = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv):final("")
	-- Verify ciphertext length matches block size (16 bytes)
	testaux.asserteq(#encrypted, 16, "Case 9: Empty input should produce 16-byte ciphertext")

	-- Verify through decryption roundtrip
	local decrypted = cipher.decryptor("aes-128-cbc", test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv):final(encrypted)
	testaux.asserteq(decrypted, "", "Case 9: Empty input decryption should return empty string")
end

-- Test 10: Key length validation
do
	local status, err = pcall(cipher.encryptor, "aes-128-cbc",
		"short_key",  -- Invalid key length
		test_vectors.aes_128_cbc.iv
	)
	testaux.asserteq(status, false, "Case 10: Key length validation")
end

-- Test 11: Algorithm compatibility
do
	local algorithms = {
		["aes-128-ecb"] = 0,
		["aes-128-cbc"] = 16,
		["aes-256-cbc"] = 32,
		["aes-192-cbc"] = 24,
		["aes-256-ctr"] = 32,
		["aes-128-gcm"] = 16,
		["aes-256-gcm"] = 32,
		["aes-256-ccm"] = 32
	}

	for alg, iv_len in ipairs(algorithms) do
		local key_len = tonumber(alg:match("%d+")) / 8
		local key = string.rep("x", key_len)
		local iv = string.rep("y", iv_len)
		print("Testing compatibility with "..alg, #iv)
		local encrypted = cipher.encryptor(alg, key, iv):final("data")
		testaux.assertgt(#encrypted, 0, "Case 11: "..alg.." compatibility")
	end
end

-- Test 12: API consistency check
do
	local data = "hello crypto world"

	-- Shortcut function
	local quick_enc = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv):final(data)

	-- Object method
	local c = cipher.encryptor("aes-128-cbc",
		test_vectors.aes_128_cbc.key,
		test_vectors.aes_128_cbc.iv
	)
	c:update(data)
	local obj_enc = c:final()

	testaux.asserteq_hex(quick_enc, obj_enc, "Case 12: API consistency")
end

-- Test 13: PKCS7 Padding Validation
do
	-- Case 1: Full block padding
	local data = string.rep("A", 16)
	local encrypted = cipher.encryptor("aes-128-cbc", test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv):final(data)
	testaux.asserteq(#encrypted, 32, "Case 13: Full block should add full padding")

	-- Case 2: Partial block
	local data = "short"
	local encrypted = cipher.encryptor("aes-128-cbc", test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv):final(data)
	testaux.asserteq(#encrypted, 16, "Case 13: Partial block should pad to full block")

	-- Case 3: Empty input
	local encrypted = cipher.encryptor("aes-128-cbc", test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv):final("")
	-- Verify ciphertext length matches block size (16 bytes)
	testaux.asserteq(#encrypted, 16, "Case 13: Empty input should produce 16-byte ciphertext")

	-- Verify through decryption roundtrip
	local decrypted = cipher.decryptor("aes-128-cbc", test_vectors.aes_128_cbc.key, test_vectors.aes_128_cbc.iv):final(encrypted)
	testaux.asserteq(decrypted, "", "Case 13: Empty input decryption should return empty string")
end
