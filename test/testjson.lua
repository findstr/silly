local json = require "core.json"
local testaux = require "test.testaux"

-- Test 1: Basic type encoding/decoding
do
	-- Strings
	testaux.asserteq(json.encode({foo="hello"}), [[{"foo":"hello"}]], "Case1: String encoding")
	local obj = json.decode('{"foo":"hello\\""}')
	assert(obj)
	testaux.asserteq(obj.foo, 'hello"', "Case1: Special characters decoding")
	local str = json.encode({foo= 'hello"'})
	testaux.asserteq(str, '{"foo":"hello\\""}', "Case1: String encoding")

	-- Numbers
	testaux.asserteq(json.encode({foo=123}), [[{"foo":123}]], "Case1: Integer encoding")
	testaux.asserteq(json.encode({foo=3.1415}), [[{"foo":3.1415}]], "Case1: Float encoding")
	local obj = json.decode("[-1.23e5]")
	assert(obj)
	testaux.asserteq(obj[1], -123000, "Case1: Scientific notation decoding")

	-- Booleans
	testaux.asserteq(json.encode({foo=true}), [[{"foo":true}]], "Case1: true encoding")
	testaux.asserteq(json.encode({foo=false}), [[{"foo":false}]], "Case1: false encoding")

	-- null
	local obj = json.decode('{"foo":null}')
	assert(obj)
	testaux.asserteq(obj.foo, nil, "Case1: null decoding")
end

-- Test 2: Complex structures
do
	-- Empty structures
	testaux.asserteq(json.encode({}), "[]", "Case2: Empty array encoding")

	-- Nested structures
	local obj = {
		a = {1, 2, {3}},
		b = {c = {d = "test"}}
	}
	local encoded = json.encode(obj)
	local decoded = json.decode(encoded)
	assert(decoded)
	testaux.asserteq(decoded.a[3][1], 3, "Case2: Nested array decoding")
	testaux.asserteq(decoded.b.c.d, "test", "Case2: Nested object decoding")

	-- Mixed-type array
	local arr = {1, "a", true, {false}}
	local encoded_arr = json.encode(arr)
	testaux.asserteq(encoded_arr, '[1,"a",true,[false]]', "Case2: Mixed array encoding")
end

-- Test 3: Boundary conditions
do
	-- Min/max numbers
	local obj = json.decode('{"foo":1.7976931348623157e308}')
	assert(obj)
	testaux.asserteq(obj.foo, 1.7976931348623157e308, "Case3: Max double precision decoding")
	local obj = json.decode('{"foo":-1.7976931348623157e308}')
	assert(obj)
	testaux.asserteq(obj.foo, -1.7976931348623157e308, "Case3: Min double precision decoding")

	-- Long string handling
	local long_str = string.rep("a", 10000)
	local obj = json.decode('["' .. long_str .. '"]')
	assert(obj)
	testaux.asserteq(obj[1], long_str, "Case3: Long string handling")

	-- Deep nesting
	local deep = {}
	local current = deep
	for i=1,100 do
		current[1] = {}
		current = current[1]
	end
	local obj = json.decode(json.encode(deep))
	assert(obj)
	testaux.asserteq(type(obj), "table", "Case3: Deeply nested structure")
end

-- Test 4: Error handling
do
	-- Invalid formats
	local cases = {
		{'{"a":1', "missing closing brace"},
		{'[1,,2]', "invalid comma"},
		{'{"a":}', "empty value error"},
		{'{"a":tru}', "invalid boolean"},
		{"'string'", "invalid quotes"}
	}

	for _, case in ipairs(cases) do
		local obj, err = json.decode(case[1])
		testaux.asserteq(obj, nil, "Case4: "..case[2])
	end
end

-- Test 5: Encoding specifications
do
	-- Array/object detection
	testaux.asserteq(json.encode({1,2,3}), '[1,2,3]', "Case5: Pure array encoding")
	testaux.asserteq(json.encode({a=1}), '{"a":1}', "Case5: Pure object encoding")

	-- Sparse array
	local sparse = {[1]=1, [3]=3}
	testaux.asserteq(json.encode(sparse), '[1]', "Case5: Sparse array encoding")
end

-- Test 6: Special characters
do
	local special = {
		{foo="\n\t\r"},
		{foo="中文"},
		{foo="~!@#$%^&*()_+"}
	}

	for _, str in ipairs(special) do
		local encoded = json.encode(str)
		local decoded = json.decode(encoded)
		assert(decoded)
		testaux.asserteq(decoded.foo, str.foo, "Case6: Special characters - "..str.foo)
	end
end
