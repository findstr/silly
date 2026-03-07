local json = require "silly.encoding.json"
local testaux = require "test.testaux"

testaux.case("Test 1: Basic type encoding/decoding", function()
	-- Strings
	testaux.asserteq(json.encode({foo="hello"}), [[{"foo":"hello"}]], "Test 1.1: String encoding")
	local obj = json.decode('{"foo":"hello\\""}')
	assert(obj)
	testaux.asserteq(obj.foo, 'hello"', "Test 1.2: Special characters decoding")
	local str = json.encode({foo= 'hello"'})
	testaux.asserteq(str, '{"foo":"hello\\""}', "Test 1.3: String encoding")

	-- Numbers
	testaux.asserteq(json.encode({foo=123}), [[{"foo":123}]], "Test 1.4: Integer encoding")
	testaux.asserteq(json.encode({foo=3.1415}), [[{"foo":3.1415}]], "Test 1.5: Float encoding")
	local obj = json.decode("[-1.23e5]")
	assert(obj)
	testaux.asserteq(obj[1], -123000, "Test 1.6: Scientific notation decoding")

	-- Booleans
	testaux.asserteq(json.encode({foo=true}), [[{"foo":true}]], "Test 1.7: true encoding")
	testaux.asserteq(json.encode({foo=false}), [[{"foo":false}]], "Test 1.8: false encoding")

	-- null
	local obj = json.decode('{"foo":null}')
	assert(obj)
	testaux.asserteq(obj.foo, json.null, "Test 1.9: null decoding to json.null")
end)

testaux.case("Test 2: Complex structures", function()
	-- Empty structures
	testaux.asserteq(json.encode({}), "[]", "Test 2.1: Empty array encoding")

	-- Nested structures
	local obj = {
		a = {1, 2, {3}},
		b = {c = {d = "test"}}
	}
	local encoded = json.encode(obj)
	local decoded = json.decode(encoded)
	assert(decoded)
	testaux.asserteq(decoded.a[3][1], 3, "Test 2.2: Nested array decoding")
	testaux.asserteq(decoded.b.c.d, "test", "Test 2.3: Nested object decoding")

	-- Mixed-type array
	local arr = {1, "a", true, {false}}
	local encoded_arr = json.encode(arr)
	testaux.asserteq(encoded_arr, '[1,"a",true,[false]]', "Test 2.4: Mixed array encoding")
end)

testaux.case("Test 3: Boundary conditions", function()
	-- Min/max numbers
	local obj = json.decode('{"foo":1.7976931348623157e308}')
	assert(obj)
	testaux.asserteq(obj.foo, 1.7976931348623157e308, "Test 3.1: Max double precision decoding")
	local obj = json.decode('{"foo":-1.7976931348623157e308}')
	assert(obj)
	testaux.asserteq(obj.foo, -1.7976931348623157e308, "Test 3.2: Min double precision decoding")

	-- Long string handling
	local long_str = string.rep("a", 10000)
	local obj = json.decode('["' .. long_str .. '"]')
	assert(obj)
	testaux.asserteq(obj[1], long_str, "Test 3.3: Long string handling")

	-- Deep nesting
	local deep = {}
	local current = deep
	for i=1,100 do
		current[1] = {}
		current = current[1]
	end
	local obj = json.decode(json.encode(deep))
	assert(obj)
	testaux.asserteq(type(obj), "table", "Test 3.4: Deeply nested structure")
end)

testaux.case("Test 4: Error handling", function()
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
		testaux.asserteq(obj, nil, "Test 4.1: "..case[2])
	end
end)

testaux.case("Test 4.5: NaN and Infinity rejection (encode)", function()
	-- NaN and Infinity should be rejected in encoding (RFC 8259)
	local result, err = json.encode({a=0/0})  -- NaN
	testaux.asserteq(result, nil, "Test 4.5.1: NaN encode returns nil")
	testaux.assertneq(err, nil, "Test 4.5.2: NaN encode returns error message")

	local result, err = json.encode({a=1/0})  -- Infinity
	testaux.asserteq(result, nil, "Test 4.5.3: Infinity encode returns nil")
	testaux.assertneq(err, nil, "Test 4.5.4: Infinity encode returns error message")

	local result, err = json.encode({a=-1/0})  -- -Infinity
	testaux.asserteq(result, nil, "Test 4.5.5: -Infinity encode returns nil")
	testaux.assertneq(err, nil, "Test 4.5.6: -Infinity encode returns error message")
end)

testaux.case("Test 5: Encoding specifications", function()
	-- Empty structures
	testaux.asserteq(json.encode({}), "[]", "Test 5.0: Empty table (no elements) encodes as empty array")
	testaux.asserteq(json.encode({x=0}), '{"x":0}', "Test 5.0a: Non-empty object encoding")

	-- Array/object detection
	testaux.asserteq(json.encode({1,2,3}), '[1,2,3]', "Test 5.1: Pure array encoding")
	testaux.asserteq(json.encode({a=1}), '{"a":1}', "Test 5.2: Pure object encoding")

	-- Sparse array
	local sparse = {[1]=1, [3]=3}
	testaux.asserteq(json.encode(sparse), '[1]', "Test 5.3: Sparse array encoding")

	-- Float-to-int optimization: floats that are actually integers
	-- should encode without decimal point (e.g., 42.0 -> "42" not "42.0")
	testaux.asserteq(json.encode({x=42.0}), '{"x":42}', "Test 5.4: Float 42.0 encodes as integer")
	testaux.asserteq(json.encode({x=0.0}), '{"x":0}', "Test 5.5: Float 0.0 encodes as integer")
	testaux.asserteq(json.encode({x=-1.0}), '{"x":-1}', "Test 5.6: Float -1.0 encodes as integer")
	testaux.asserteq(json.encode({x=1.0}), '{"x":1}', "Test 5.7: Float 1.0 encodes as integer")

	-- 2^63 as float should not crash (was UB: double->long long overflow)
	local s = json.encode({x=2^63})
	testaux.assertneq(s, nil, "Test 5.10: 2^63 float encodes without crash")

	-- Actual floats should keep decimal point
	local s = json.encode({x=3.14})
	local obj = json.decode(s)
	testaux.asserteq(obj.x, 3.14, "Test 5.8: Float 3.14 roundtrip")
	testaux.assertneq(s, '{"x":3}', "Test 5.9: Float 3.14 not encoded as integer")
end)

testaux.case("Test 6: Special characters", function()
	local special = {
		{foo="\n\t\r"},
		{foo="中文"},
		{foo="~!@#$%^&*()_+"}
	}

	for i, str in ipairs(special) do
		local encoded = json.encode(str)
		local decoded = json.decode(encoded)
		assert(decoded)
		testaux.asserteq(decoded.foo, str.foo, "Test 6."..i..": Special characters")
	end

	local escaped = {
		-- Basic escaping of backslash
		{obj = {foo = "\\"}, str = '{"foo":"\\\\"}'},
		-- Double quotes escaping
		{obj = {foo = "\""}, str = '{"foo":"\\""}'},
		-- Forward slash (not escaped in our encoder)
		{obj = {foo = "/"}, str = '{"foo":"/"}'},
		-- Control characters
		{obj = {foo = "\b"}, str = '{"foo":"\\b"}'},
		{obj = {foo = "\f"}, str = '{"foo":"\\f"}'},
		{obj = {foo = "\n"}, str = '{"foo":"\\n"}'},
		{obj = {foo = "\r"}, str = '{"foo":"\\r"}'},
		{obj = {foo = "\t"}, str = '{"foo":"\\t"}'},
		-- Multiple escape sequences in one string
		{obj = {foo = "line1\nline2\t\"quoted\""}, str = '{"foo":"line1\\nline2\\t\\"quoted\\""}'},
		-- Nested objects with escapes
		{obj = {foo = {bar = "a\\b"}}, str = '{"foo":{"bar":"a\\\\b"}}'},
		-- Arrays with escaped elements
		{obj = {foo = {"a\"", "b\\"}}, str = '{"foo":["a\\"","b\\\\"]}'},
		-- Empty string with surrounding escapes
		{obj = {foo = "\\test\\"}, str = '{"foo":"\\\\test\\\\"}'},
		-- Consecutive escapes
		{obj = {foo = "\\\\\\"}, str = '{"foo":"\\\\\\\\\\\\"}'},
		-- Mix of different escape types
		{obj = {foo = "\\\"\\n\\t"}, str = '{"foo":"\\\\\\"\\\\n\\\\t"}'},
		-- Testing keys with escapes
		{obj = {["key\\with\"escapes"] = "value"}, str = '{"key\\\\with\\"escapes":"value"}'}
	}
	for i, v in ipairs(escaped) do
		local str = json.encode(v.obj)
		assert(str)
		testaux.asserteq(str, v.str, "Test 6.10: Escaped encoding "..i)
	end
end)

testaux.case("Test 7: Boolean/null as last element (bug fix)", function()
	-- These crashed in the old Lua implementation
	local obj = json.decode('[true]')
	assert(obj)
	testaux.asserteq(obj[1], true, "Test 7.1: [true] decoding")

	local obj = json.decode('[false]')
	assert(obj)
	testaux.asserteq(obj[1], false, "Test 7.2: [false] decoding")

	local obj = json.decode('[null]')
	assert(obj)
	testaux.asserteq(obj[1], json.null, "Test 7.3: [null] decoding")

	local obj = json.decode('{"a":true}')
	assert(obj)
	testaux.asserteq(obj.a, true, "Test 7.4: {a:true} decoding")

	local obj = json.decode('{"a":null}')
	assert(obj)
	testaux.asserteq(obj.a, json.null, "Test 7.5: {a:null} decoding")
end)

testaux.case("Test 8: Unicode escape sequences", function()
	-- Basic \uXXXX
	local obj = json.decode('"\\u0041"')
	testaux.asserteq(obj, "A", "Test 8.1: \\u0041 = A")

	local obj = json.decode('"\\u4e2d\\u6587"')
	testaux.asserteq(obj, "中文", "Test 8.2: \\u4e2d\\u6587 = 中文")

	-- Euro sign (U+20AC) = 3-byte UTF-8
	local obj = json.decode('"\\u20ac"')
	testaux.asserteq(obj, "€", "Test 8.3: \\u20ac = €")

	-- Surrogate pair: U+1F600 (😀) = \uD83D\uDE00
	local obj = json.decode('"\\uD83D\\uDE00"')
	testaux.asserteq(obj, "\xF0\x9F\x98\x80", "Test 8.4: Surrogate pair U+1F600")

	-- Surrogate pair: U+1D11E (𝄞) = \uD834\uDD1E
	local obj = json.decode('"\\uD834\\uDD1E"')
	testaux.asserteq(obj, "\xF0\x9D\x84\x9E", "Test 8.5: Surrogate pair U+1D11E")

	-- Null character \u0000
	local obj = json.decode('"\\u0000"')
	testaux.asserteq(obj, "\0", "Test 8.6: \\u0000 = null byte")

	-- Invalid: lone high surrogate
	local obj, err = json.decode('"\\uD800"')
	testaux.asserteq(obj, nil, "Test 8.7: Lone high surrogate rejected")

	-- Invalid: lone low surrogate
	local obj, err = json.decode('"\\uDC00"')
	testaux.asserteq(obj, nil, "Test 8.8: Lone low surrogate rejected")

	-- Invalid: incomplete \uXXXX
	local obj, err = json.decode('"\\u00"')
	testaux.asserteq(obj, nil, "Test 8.9: Incomplete unicode escape rejected")
end)

testaux.case("Test 9: Control character encoding", function()
	-- Control characters 0x00-0x1F should be escaped in encode
	for i = 0, 0x1F do
		local ch = string.char(i)
		local encoded = json.encode({ch})
		-- verify it doesn't contain the raw control character
		local found_raw = false
		-- The encoded string should contain escape sequences, not raw bytes
		local decoded = json.decode(encoded)
		assert(decoded)
		testaux.asserteq(decoded[1], ch, "Test 9.1: Control char 0x"..string.format("%02x", i).." roundtrip")
	end
end)

testaux.case("Test 10: Forward slash decoding", function()
	-- \/ should decode to /
	local obj = json.decode('"hello\\/world"')
	testaux.asserteq(obj, "hello/world", "Test 10.1: \\/ unescaping")

	-- Roundtrip: / is not escaped by encoder (optional per RFC)
	local encoded = json.encode({"hello/world"})
	testaux.asserteq(encoded, '["hello/world"]', "Test 10.2: / not escaped in encoding")
end)

testaux.case("Test 11: json.null sentinel", function()
	-- json.null is a table
	testaux.asserteq(type(json.null), "table", "Test 11.1: json.null is a table")

	-- tostring returns "null"
	testaux.asserteq(tostring(json.null), "null", "Test 11.2: tostring(json.null) = 'null'")

	-- json.null encodes to null
	testaux.asserteq(json.encode({json.null}), "[null]", "Test 11.3: json.null encodes to null")

	-- json.null in object
	testaux.asserteq(json.encode({a=json.null}), '{"a":null}', "Test 11.4: json.null in object")

	-- Roundtrip: null in array preserved as json.null
	local obj = json.decode('[1,null,3]')
	assert(obj)
	testaux.asserteq(obj[1], 1, "Test 11.5: array elem 1")
	testaux.asserteq(obj[2], json.null, "Test 11.6: array elem 2 is json.null")
	testaux.asserteq(obj[3], 3, "Test 11.7: array elem 3")

	-- json.null is immutable
	testaux.assert_error(function() json.null.x = 1 end, "Test 11.8: json.null is immutable")

	-- metatable is protected
	testaux.asserteq(getmetatable(json.null), false, "Test 11.9: metatable is protected")
end)

testaux.case("Test 12: JSONTestSuite y_ (must accept)", function()
	local y_cases = {
		{'[[]   ]', "Test 12.1: array with trailing space"},
		{'[""]', "Test 12.2: array with empty string"},
		{'[]', "Test 12.3: empty array"},
		{'["a"]', "Test 12.4: array with string"},
		{'[false]', "Test 12.5: array with false"},
		{'[null]', "Test 12.6: array with null"},
		{'[1]', "Test 12.7: array with number"},
		{'[1,null,null,null,2]', "Test 12.8: array with several nulls"},
		{'[2e1]', "Test 12.9: number with exponent"},
		{'[2e+1]', "Test 12.10: number with positive exponent"},
		{'[2e-1]', "Test 12.11: number with negative exponent"},
		{'[2E1]', "Test 12.12: number with uppercase exponent"},
		{'[23456789012E66]', "Test 12.13: large number with exponent"},
		{'[0.1]', "Test 12.14: number with fraction"},
		{'[1E22]', "Test 12.15: 1E22"},
		{'[1E-2]', "Test 12.16: 1E-2"},
		{'[1E+2]', "Test 12.17: 1E+2"},
		{'[123e65]', "Test 12.18: 123e65"},
		{'[123456789]', "Test 12.19: 123456789"},
		{'[-0]', "Test 12.20: negative zero"},
		{'[-123]', "Test 12.21: negative integer"},
		{'[-1]', "Test 12.22: -1"},
		{'[-1.0]', "Test 12.23: -1.0"},
		{'[1.0]', "Test 12.24: 1.0"},
		{'[1.0e1]', "Test 12.25: 1.0e1"},
		{'[1.0e+1]', "Test 12.26: 1.0e+1"},
		{'[0]', "Test 12.27: zero"},
		{'[0e1]', "Test 12.28: 0e1"},
		{'[0e+1]', "Test 12.29: 0e+1"},
		{'{"a":"b"}', "Test 12.30: simple object"},
		{'{"a":{}}', "Test 12.31: nested empty object"},
		{'{"":0}', "Test 12.32: empty key"},
		{'{"a":"b","c":"d"}', "Test 12.33: two keys"},
		{'["\\u0060\\u012a\\u12AB"]', "Test 12.34: unicode escapes"},
		{'["\\uD801\\udc37"]', "Test 12.35: surrogate pair"},
		{'["\\ud83d\\ude39\\ud83d\\udc8d"]', "Test 12.36: two surrogate pairs"},
		{'["\\"\\\\\\/\\b\\f\\n\\r\\t"]', "Test 12.37: all escapes"},
		{'["\\\\a"]', "Test 12.38: escaped backslash"},
		{'["\\\\n"]', "Test 12.39: escaped backslash n"},
		{'["a/*b*/c/*d//e"]', "Test 12.40: string with comments-like content"},
		{'["\\\\"]', "Test 12.41: single backslash escape"},
		{'[" "]', "Test 12.42: space in string"},
		{'["asd"]', "Test 12.43: simple string"},
		{'["\\uDBFF\\uDFFE"]', "Test 12.44: max surrogate pair"},
		{'["new\\u000Aline"]', "Test 12.45: newline unicode"},
		{'[true]', "Test 12.46: true"},
		{' [] ', "Test 12.47: leading and trailing spaces"},
	}
	for _, tc in ipairs(y_cases) do
		local obj, err = json.decode(tc[1])
		testaux.assertneq(obj, nil, tc[2])
	end
end)

testaux.case("Test 13: JSONTestSuite n_ (must reject)", function()
	local n_cases = {
		{'[1 true]', "Test 13.1: missing comma"},
		{'["a",\n4\n,1,', "Test 13.2: trailing comma"},
		{'[1,,]', "Test 13.3: double comma"},
		{'["",]', "Test 13.4: trailing comma after string"},
		{'["a"', "Test 13.5: unclosed array"},
		{'[1:', "Test 13.6: colon in array"},
		{',[]', "Test 13.7: leading comma"},
		{'[,1]', "Test 13.8: leading comma in array"},
		{'[1,]', "Test 13.9: trailing comma"},
		{'["a\\a"]', "Test 13.10: invalid escape char"},
		{'["new\nline"]', "Test 13.11: raw newline in string"},
		{'["tab\there"]', "Test 13.12: raw tab in string"},
		{'[++1234]', "Test 13.13: double plus"},
		{'[+1]', "Test 13.14: plus sign"},
		{'[.123]', "Test 13.15: leading dot"},
		{'[1.]', "Test 13.16: trailing dot"},
		{'[2.e3]', "Test 13.17: dot then exponent"},
		{'[Inf]', "Test 13.18: Inf"},
		{'[-Inf]', "Test 13.19: negative Inf"},
		{'[NaN]', "Test 13.20: NaN"},
		{'[012]', "Test 13.21: leading zero"},
		{'[0e]', "Test 13.22: incomplete exponent"},
		{'[0e+]', "Test 13.23: incomplete positive exponent"},
		{'[0E+]', "Test 13.24: incomplete uppercase positive exponent"},
		{'[1eE2]', "Test 13.25: double exponent"},
		{'{"a":"b",}', "Test 13.26: trailing comma in object"},
		{'{"a"}', "Test 13.27: missing colon"},
		{'{"a":}', "Test 13.28: missing value"},
		{'{1:1}', "Test 13.29: non-string key"},
		{'{null:1}', "Test 13.30: null key"},
		{'{"a":"a" "b":"b"}', "Test 13.31: missing comma in object"},
		{'{"":":"colon"}', "Test 13.32: unexpected colon"},
		{'', "Test 13.33: empty input"},
		{'["\\uD800\\u"]', "Test 13.34: incomplete surrogate pair"},
		{'["\\uD800\\u1"]', "Test 13.35: invalid low surrogate"},
		{'["\\u00"]', "Test 13.36: incomplete unicode escape"},
		{'["\\uqqqq"]', "Test 13.37: invalid hex in unicode"},
	}
	for _, tc in ipairs(n_cases) do
		local obj, err = json.decode(tc[1])
		testaux.asserteq(obj, nil, tc[2])
	end
end)

testaux.case("Test 14: Integer preservation", function()
	-- Integers should be preserved as lua integers
	local obj = json.decode('[42]')
	assert(obj)
	testaux.asserteq(math.type(obj[1]), "integer", "Test 14.1: 42 is integer")

	local obj = json.decode('[0]')
	assert(obj)
	testaux.asserteq(math.type(obj[1]), "integer", "Test 14.2: 0 is integer")

	local obj = json.decode('[-1]')
	assert(obj)
	testaux.asserteq(math.type(obj[1]), "integer", "Test 14.3: -1 is integer")

	-- Floats should be floats
	local obj = json.decode('[1.5]')
	assert(obj)
	testaux.asserteq(math.type(obj[1]), "float", "Test 14.4: 1.5 is float")

	local obj = json.decode('[1e2]')
	assert(obj)
	testaux.asserteq(math.type(obj[1]), "float", "Test 14.5: 1e2 is float")
end)

testaux.case("Test 15: Circular reference detection", function()
	-- Self-referencing object
	local a = {}
	a.self = a
	local result, err = json.encode(a)
	testaux.asserteq(result, nil, "Test 15.1: Self-referencing object returns nil")
	testaux.assertneq(err, nil, "Test 15.2: Self-referencing object returns error")

	-- Circular reference between two objects
	local obj1 = {}
	local obj2 = {ref = obj1}
	obj1.ref = obj2
	local result, err = json.encode({obj1})
	testaux.asserteq(result, nil, "Test 15.3: Circular reference returns nil")
	testaux.assertneq(err, nil, "Test 15.4: Circular reference returns error")

	-- Valid deep nesting should work (within MAX_DEPTH)
	local deep = {}
	local current = deep
	for i = 1, 50 do
		current.child = {}
		current = current.child
	end
	local s = json.encode({root=deep})
	testaux.assertneq(s, nil, "Test 15.5: Deep nesting (50 levels) encodes successfully")
end)

testaux.case("Test 16: Repeated encode stress (luaL_Buffer stack bug)", function()
	-- This test catches the bug where luaL_Buffer on the Lua stack gets
	-- corrupted by lua_rawgeti/lua_next during encode_table traversal.
	-- The crash only manifests after many iterations (buffer realloc).
	local float_array = {}
	for i = 1, 100 do float_array[i] = i * 0.123456789 end
	for i = 1, 2000 do
		local s = json.encode(float_array)
		assert(s and #s > 0)
	end
	testaux.success("Test 16.1: float array encode x2000 no crash")

	local obj = {}
	for i = 1, 50 do obj["key_" .. i] = string.rep("abc", 10) end
	for i = 1, 2000 do
		local s = json.encode(obj)
		assert(s and #s > 0)
	end
	testaux.success("Test 16.2: large object encode x2000 no crash")

	local nested = {users={{id=1,tags={"a","b"},m={x=true}},{id=2,tags={"c"}}}}
	for i = 1, 2000 do
		local s = json.encode(nested)
		local d = json.decode(s)
		assert(d)
	end
	testaux.success("Test 16.3: encode/decode roundtrip x2000 no crash")
end)
