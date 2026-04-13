local testaux = require "test.testaux"

testaux.module("errno")

local errno = require "silly.errno"

-- Custom EX* error codes (strings defined in new_error_table, cross-platform)

testaux.case("Test 1: EX* custom error codes", function()
	testaux.asserteq(errno.EOF, "End of file (10004)", "Test 1.1: EOF")
	testaux.assertneq(errno.TIMEDOUT:find("timed out", 1, true), nil, "Test 1.2: TIMEDOUT")
	testaux.asserteq(errno.TLS, "TLS error (10005)", "Test 1.3: TLS")
	testaux.asserteq(errno.CLOSED, "Socket is closed (10003)", "Test 1.4: CLOSED")
	testaux.asserteq(errno.CLOSING, "Socket is closing (10002)", "Test 1.5: CLOSING")
	testaux.asserteq(errno.NOSOCKET, "No free socket available (10001)", "Test 1.6: NOSOCKET")
	testaux.asserteq(errno.RESOLVE, "Address resolution failed (10000)", "Test 1.7: RESOLVE")
	testaux.success("Test 1 passed")
end)

-- Standard errno codes exist and are non-nil strings (but don't test specific strerror values)

testaux.case("Test 2: Standard errno codes exist", function()
	testaux.assertneq(errno.INTR, nil, "Test 2.1: INTR exists")
	testaux.assertneq(errno.ACCES, nil, "Test 2.2: ACCES exists")
	testaux.assertneq(errno.BADF, nil, "Test 2.3: BADF exists")
	testaux.assertneq(errno.PIPE, nil, "Test 2.4: PIPE exists")
	testaux.assertneq(errno.CONNREFUSED, nil, "Test 2.5: CONNREFUSED exists")
	testaux.assertneq(errno.CONNRESET, nil, "Test 2.6: CONNRESET exists")
	testaux.assertneq(errno.TIMEDOUT:find("%(%d+%)"), nil, "Test 2.7: TIMEDOUT has errno suffix")
	testaux.assertneq(errno.AGAIN, nil, "Test 2.8: AGAIN exists")
	testaux.success("Test 2 passed")
end)

-- __index mechanism: unknown keys produce unique "Unknown error" strings

testaux.case("Test 3: __index fallback for unknown keys", function()
	local v = errno.THIS_KEY_DOES_NOT_EXIST
	testaux.asserteq(v, "Unknown error 'THIS_KEY_DOES_NOT_EXIST'",
		"Test 3.1: undefined key format")
	testaux.success("Test 3 passed")
end)

testaux.case("Test 4: Different unknown keys produce different strings", function()
	local a = errno.FOO_UNKNOWN
	local b = errno.BAR_UNKNOWN
	testaux.assertneq(a, b, "Test 4.1: FOO_UNKNOWN != BAR_UNKNOWN")
	testaux.asserteq(a, "Unknown error 'FOO_UNKNOWN'", "Test 4.2: FOO_UNKNOWN format")
	testaux.asserteq(b, "Unknown error 'BAR_UNKNOWN'", "Test 4.3: BAR_UNKNOWN format")
	testaux.success("Test 4 passed")
end)

testaux.case("Test 5: __index caches values", function()
	local a = errno.CACHE_TEST
	local b = errno.CACHE_TEST
	testaux.asserteq(a, b, "Test 5.1: cached value equality")
	testaux.asserteq(rawget(errno, "CACHE_TEST"), b,
		"Test 5.2: rawget matches cached value")
	testaux.success("Test 5 passed")
end)

testaux.case("Test 6: Predefined keys bypass __index", function()
	testaux.asserteq(rawget(errno, "EOF"), "End of file (10004)",
		"Test 6.1: rawget EOF returns value directly")
	testaux.assertneq(rawget(errno, "TIMEDOUT"):find("%(%d+%)"), nil,
		"Test 6.2: rawget TIMEDOUT has errno suffix")
	testaux.asserteq(rawget(errno, "INTR") ~= nil, true,
		"Test 6.3: rawget INTR returns value directly")
	testaux.success("Test 6 passed")
end)

-- TIMEDOUT numeric code is platform-dependent (Linux=110, macOS=60, Windows=EXBASE+6).
-- We only assert the suffix is present and is a positive integer.

testaux.case("Test 7: TIMEDOUT numeric code is platform-dependent", function()
	local code = errno.TIMEDOUT:match("%((%d+)%)")
	testaux.assertneq(code, nil, "Test 7.1: TIMEDOUT carries numeric suffix")
	local n = tonumber(code)
	testaux.assertneq(n, nil, "Test 7.2: suffix is numeric")
	testaux.assertgt(n, 0, "Test 7.3: suffix is positive")
	testaux.success("Test 7 passed")
end)
