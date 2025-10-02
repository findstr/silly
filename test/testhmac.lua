local hmac = require "silly.crypto.hmac"
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
	local P = require "test.print"
	for _, test in ipairs(tests) do
		local result = testaux.hextostr(hmac.digest(test.key, test.data, "sha256"))
		testaux.asserteq(result, test.sha256, "Case 1: HMAC-SHA256 test vector")
	end
end

-- Test 2: Empty inputs
do
	local result1 = hmac.digest("", "key", "sha256")
	local result2 = hmac.digest("message", "", "sha256")
	local result3 = hmac.digest("", "", "sha256")

	testaux.assertneq(result1, nil, "Case 2: Empty message should work")
	testaux.assertneq(result2, nil, "Case 2: Empty key should work")
	testaux.assertneq(result3, nil, "Case 2: Empty message and key should work")
end

-- Test 3: Binary safety
do
	local binary_key = string.char(0, 255, 128, 127)
	local binary_msg = string.char(1, 2, 3, 4)

	local result1 = hmac.digest(binary_key, binary_msg, "sha256")
	local result2 = hmac.digest(binary_key, binary_msg, "sha256")

	testaux.asserteq_hex(result1, result2, "Case 3: Binary data consistency")
end

-- Test 4: Long inputs
do
	local long_key = string.rep("a", 1000)
	local long_msg = string.rep("b", 1000)

	local result = hmac.digest(long_key, long_msg, "sha256")
	testaux.assertneq(result, nil, "Case 4: Long inputs should work")
end

-- Test 5: Invalid inputs
do
	local success, err = pcall(function()
		hmac.digest("msg", "key", "invalid_alg")
	end)
	testaux.asserteq(success, false, "Case 5: Invalid algorithm should fail")

	success, err = pcall(function()
		hmac.digest("msg", nil, "sha256")
	end)
	testaux.asserteq(success, false, "Case 5: Nil message should fail")

	success, err = pcall(function()
		hmac.digest("msg", nil, "sha256")
	end)
	testaux.asserteq(success, false, "Case 5: Nil key should fail")
end
