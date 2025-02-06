local base64 = require "core.base64"
local testaux = require "test.testaux"

-- Test 1: Basic encoding
do
	testaux.asserteq(base64.encode("hello world"), "aGVsbG8gd29ybGQ=", "Case 1: Test encode normal string")
	testaux.asserteq(base64.encode(""), "", "Case 1: Test encode empty string")
	testaux.asserteq(base64.encode("f"), "Zg==", "Case 1: Test encode single character")
	testaux.asserteq(base64.encode("fo"), "Zm8=", "Case 1: Test encode two characters")
	testaux.asserteq(base64.encode("foo"), "Zm9v", "Case 1: Test encode three characters")
	testaux.asserteq(base64.encode("你好"), "5L2g5aW9", "Case 1: Test encode non-ASCII characters")
end

-- Test 2: Basic decoding
do
	testaux.asserteq(base64.decode("aGVsbG8gd29ybGQ="), "hello world", "Case 2: Test decode normal string")
	testaux.asserteq(base64.decode(""), "", "Case 2: Test decode empty string")
	testaux.asserteq(base64.decode("Zg=="), "f", "Case 2: Test decode single character")
	testaux.asserteq(base64.decode("Zm8="), "fo", "Case 2: Test decode two characters")
	testaux.asserteq(base64.decode("Zm9v"), "foo", "Case 2: Test decode three characters")
	testaux.asserteq(base64.decode("5L2g5aW9"), "你好", "Case 2: Test decode non-ASCII characters")
end

-- Test 3: URL-safe encoding
do
	testaux.asserteq(base64.urlsafe_encode("hello world"), "aGVsbG8gd29ybGQ=", "Case 3: Test urlsafe_encode normal string")
	testaux.asserteq(base64.urlsafe_encode(""), "", "Case 3: Test urlsafe_encode empty string")
	testaux.asserteq(base64.urlsafe_encode("f"), "Zg==", "Case 3: Test urlsafe_encode single character")
	testaux.asserteq(base64.urlsafe_encode("fo"), "Zm8=", "Case 3: Test urlsafe_encode two characters")
	testaux.asserteq(base64.urlsafe_encode("foo"), "Zm9v", "Case 3: Test urlsafe_encode three characters")
	testaux.asserteq(base64.urlsafe_encode("你好"), "5L2g5aW9", "Case 3: Test urlsafe_encode non-ASCII characters")
end

-- Test 4: URL-safe decoding
do
	testaux.asserteq(base64.urlsafe_decode("aGVsbG8gd29ybGQ="), "hello world", "Case 4: Test urlsafe_decode normal string")
	testaux.asserteq(base64.urlsafe_decode(""), "", "Case 4: Test urlsafe_decode empty string")
	testaux.asserteq(base64.urlsafe_decode("Zg=="), "f", "Case 4: Test urlsafe_decode single character")
	testaux.asserteq(base64.urlsafe_decode("Zm8="), "fo", "Case 4: Test urlsafe_decode two characters")
	testaux.asserteq(base64.urlsafe_decode("Zm9v"), "foo", "Case 4: Test urlsafe_decode three characters")
	testaux.asserteq(base64.urlsafe_decode("5L2g5aW9"), "你好", "Case 4: Test urlsafe_decode non-ASCII characters")
end
