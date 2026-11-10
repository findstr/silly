local silly = require "silly"
local random = require "silly.crypto.random"
local testaux = require "test.testaux"
local pcall = silly.pcall

testaux.case("Test 1: Cryptographic random bytes preserve the requested length", function()
	for _, size in ipairs({0, 1, 4, 16, 32, 257, 4096}) do
		local bytes = random.bytes(size)
		testaux.asserteq(type(bytes), "string", "Test 1.1: Random bytes return a string")
		testaux.asserteq(#bytes, size, "Test 1.2: Random output has the requested byte length")
	end
end)

testaux.case("Test 2: Cryptographic random bytes reject invalid lengths before allocation", function()
	for _, size in ipairs({-1, 0x80000000, 1.5}) do
		local ok = pcall(random.bytes, size)
		testaux.asserteq(ok, false, "Test 2.1: Invalid lengths cannot reach the random generator")
	end
end)

testaux.case("Test 3: Random text contains exactly the requested number of lowercase letters", function()
	for _, size in ipairs({0, 1, 4, 16, 32, 257, 4096}) do
		local text = random.text(size)
		testaux.asserteq(#text, size, "Test 3.1: Random text has the requested length")
		testaux.asserteq(text:find("[^a-z]"), nil, "Test 3.2: Random text contains only lowercase ASCII letters")
	end
end)

testaux.case("Test 4: Random text rejects invalid lengths before allocation", function()
	for _, size in ipairs({-1, 0x80000000, 1.5}) do
		local ok = pcall(random.text, size)
		testaux.asserteq(ok, false, "Test 4.1: Invalid text lengths are rejected")
	end
end)
