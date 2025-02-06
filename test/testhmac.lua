local hmac = require "core.crypto.hmac"
local testaux = require "test.testaux"

-- Test 1: Normal HMAC operation with known test vectors
do
	-- Test vectors from RFC 4231
	local tests = {
		{
			key = "\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b",
			data = "Hi There",
			sha256 = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
		},
		{
			key = "Jefe",
			data = "what do ya want for nothing?",
			sha256 = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
		}
	}

	for _, test in ipairs(tests) do
		local result = hmac.digest("sha256", test.data, test.key)
		testaux.asserteq_hex(result, test.sha256, "Case 1: HMAC-SHA256 test vector")
	end
end

-- Test 2: Empty inputs
do
	local result1 = hmac.digest("sha256", "", "key")
	local result2 = hmac.digest("sha256", "message", "")
	local result3 = hmac.digest("sha256", "", "")

	testaux.assert(result1 ~= nil, "Case 2: Empty message should work")
	testaux.assert(result2 ~= nil, "Case 2: Empty key should work")
	testaux.assert(result3 ~= nil, "Case 2: Empty message and key should work")
end

-- Test 3: Binary safety
do
	local binary_key = string.char(0, 255, 128, 127)
	local binary_msg = string.char(1, 2, 3, 4)

	local result1 = hmac.digest("sha256", binary_msg, binary_key)
	local result2 = hmac.digest("sha256", binary_msg, binary_key)

	testaux.asserteq_hex(result1, result2, "Case 3: Binary data consistency")
end

-- Test 4: Long inputs
do
	local long_key = string.rep("a", 1000)
	local long_msg = string.rep("b", 1000)

	local result = hmac.digest("sha256", long_msg, long_key)
	testaux.assert(result ~= nil, "Case 4: Long inputs should work")
end

-- Test 5: Invalid inputs
do
	local success, err = pcall(function()
		hmac.digest("invalid_alg", "msg", "key")
	end)
	testaux.assert(not success, "Case 5: Invalid algorithm should fail")

	success, err = pcall(function()
		hmac.digest("sha256", nil, "key")
	end)
	testaux.assert(not success, "Case 5: Nil message should fail")

	success, err = pcall(function()
		hmac.digest("sha256", "msg", nil)
	end)
	testaux.assert(not success, "Case 5: Nil key should fail")
end