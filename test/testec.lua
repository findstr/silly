local ec = require "silly.crypto.ec"
local testaux = require "test.testaux"

-- Generated EC keys (secp256k1 curve)
local privkey = [[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]]

local pubkey = [[
-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf
/c+hOGwHalqi6V1wAiC1Hcx/T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END PUBLIC KEY-----
]]

-- Test vectors
local test_vectors = {
	{
		alg = "sha256",
		message = "Hello ECDSA!",
	},
	{
		alg = "sha384",
		message = string.rep("B", 1024),  -- Long message
	},
	{
		alg = "sha512",
		message = "",  -- Empty message
	}
}

-- Test 1: Basic sign/verify workflow
do
	local priv = ec.new(privkey)
	local pub = ec.new(pubkey)

	for _, vec in ipairs(test_vectors) do
		local sig = priv:sign(vec.message, vec.alg)
		local verify = pub:verify(vec.message, sig, vec.alg)
		testaux.asserteq(verify, true, "Case1: "..vec.alg.." verification passed")
	end
end

-- Test 2: Signature tampering detection
do
	local priv = ec.new(privkey)
	local pub = ec.new(pubkey)
	local sig = priv:sign("original message", "sha256")

	-- Tamper with signature
	local bad_sig = sig:sub(1, -2) .. string.char(sig:byte(-1) ~ 0x01)
	testaux.asserteq(pub:verify("original message", bad_sig, "sha256"), false,
		"Case2: Detect signature tampering")

	-- Tamper with message
	testaux.asserteq(pub:verify("modified message", sig, "sha256"), false,
		"Case2: Detect message tampering")
end

-- Test 3: Error handling
do
	-- Invalid key format
	local status = pcall(ec.new, "invalid key")
	testaux.asserteq(status, false, "Case3: Detect invalid key format")

	-- Unsupported algorithm
	local priv = ec.new(privkey)
	local status = pcall(priv.sign, priv, "invalid_alg", "data")
	testaux.asserteq(status, false, "Case3: Detect unsupported algorithm")

	-- Non-EC key
	local status = pcall(ec.new, [[-----BEGIN RSA PRIVATE KEY-----...]])
	testaux.asserteq(status, false, "Case3: Detect non-EC key")
end

-- Test 4: Object reuse
do
	local priv = ec.new(privkey)
	local pub = ec.new(pubkey)

	-- First use
	local sig1 = priv:sign("message1", "sha256")
	testaux.asserteq(pub:verify("message1", sig1, "sha256"), true,
		"Case4: First verification")

	-- Second use
	local sig2 = priv:sign("message2", "sha384")
	testaux.asserteq(pub:verify("message2", sig2, "sha384"), true,
		"Case4: Second verification")
end

-- Test 5: Boundary conditions
do
	local priv = ec.new(privkey)
	local pub = ec.new(pubkey)

	-- Very long message (1MB)
	local long_msg = string.rep("A", 1024*1024)
	local sig = priv:sign(long_msg, "sha256")
	testaux.asserteq(pub:verify(long_msg, sig, "sha256"), true,
		"Case5: 1MB long message")

	-- Empty message
	local sig_empty = priv:sign("", "sha256")
	testaux.asserteq(pub:verify("", sig_empty, "sha256"), true,
		"Case5: Empty message")
end
