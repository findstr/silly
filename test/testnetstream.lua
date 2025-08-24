local ns = require "core.netstream"
local testaux = require "test.testaux"

local function build(n)
    local tbl = {}
    local char = string.char
    for i = 1, n do
        tbl[i] = char(i % 56 + 97)
    end
    return table.concat(tbl)
end

local fd = 42

-- Test 1: new/free/size/limit
do
    local sb = ns.new(fd)
    testaux.asserteq(type(sb), "userdata", "Case 1.1: new returns userdata")
    testaux.asserteq(ns.size(sb), 0, "Case 1.2: new buffer size == 0")
    testaux.asserteq(ns.limit(sb, 100), 2147483647, "Case 1.3: limit returns previous limit")
    testaux.asserteq(ns.limit(sb, 50), 100, "Case 1.4: limit returns previous limit again")
    ns.free(sb)
    -- free twice should not crash
    ns.free(sb)
end

-- Test 2: tpush/push/read/readall
do
    local sb = ns.new(fd)
    -- push empty string
    ns.tpush(sb, "")
    testaux.asserteq(ns.size(sb), 0, "Case 2.1: push empty string, size==0")
    -- push single char
    ns.tpush(sb, "A")
    testaux.asserteq(ns.size(sb), 1, "Case 2.2: push single char, size==1")
    testaux.asserteq(ns.read(sb, 1), "A", "Case 2.3: read single char")
    -- push multi-chunk, readall
    ns.tpush(sb, "foo")
    ns.tpush(sb, "bar")
    testaux.asserteq(ns.size(sb), 6, "Case 2.4: push two chunks, size==6")
    testaux.asserteq(ns.readall(sb), "foobar", "Case 2.5: readall returns all data")
    testaux.asserteq(ns.size(sb), 0, "Case 2.6: after readall, size==0")
    -- read from empty buffer
    testaux.asserteq(ns.read(sb, 1), nil, "Case 2.7: read from empty buffer returns empty string")
end

-- Test 3: read out of range/negative/zero
do
    local sb = ns.new(fd)
    ns.tpush(sb, "abc")
    testaux.asserteq(ns.read(sb, 0), "", "Case 3.1: read 0 returns empty string")
    testaux.asserteq(ns.read(sb, -1), "", "Case 3.2: read negative returns empty string")
    testaux.asserteq(ns.read(sb, 10), nil, "Case 3.3: read over size returns nil")
end

-- Test 4: readline edge cases
do
    local sb = ns.new(fd)
    ns.tpush(sb, "abc\ndef\r\nghi")
    testaux.asserteq(ns.readline(sb, "\n"), "abc\n", "Case 4.1: readline with \\n")
    testaux.asserteq(ns.readline(sb, "\r\n"), "def\r\n", "Case 4.2: readline with \\r\\n")
    testaux.asserteq(ns.readline(sb, "\n"), nil, "Case 4.3: readline not found returns nil")
    ns.tpush(sb, "\n")
    testaux.asserteq(ns.readline(sb, "\n"), "ghi\n", "Case 4.4: readline after append")
    -- empty delimiter
    local ok, err = pcall(function() ns.readline(sb, "") end)
    testaux.asserteq(not ok, true, "Case 4.5: readline with empty delim throws")
    testaux.asserteq(not not err:find("delim is empty"), true, "Case 4.5: readline with empty delim throws")
end

-- Test 5: readline across nodes
do
    local sb = ns.new(fd)
    ns.tpush(sb, "foo")
    ns.tpush(sb, "bar")
    ns.tpush(sb, "baz")
    testaux.asserteq(ns.readline(sb, "barb"), "foobarb", "Case 5.1: readline cross node")
    testaux.asserteq(ns.readline(sb, "az"), "az", "Case 5.2: readline cross node at end")
end

-- Test 6: readall on empty buffer
do
    local sb = ns.new(fd)
    testaux.asserteq(ns.readall(sb), "", "Case 6.1: readall on empty buffer returns empty string")
end

-- Test 7: tpush with large data
do
    local sb = ns.new(fd)
    local big = build(1024 * 128)
    ns.tpush(sb, big)
    testaux.asserteq(ns.read(sb, #big), big, "Case 7.1: tpush/read big data")
end

-- Test 8: limit/pause edge
do
    local sb = ns.new(fd)
    ns.limit(sb, 1)
    ns.tpush(sb, "a")
    -- can still read after pause triggered
    testaux.asserteq(ns.read(sb, 1), "a", "Case 8.1: read after pause")
end

-- Test 9: switch delim
do
    local sb = ns.new(fd)
    ns.tpush(sb, "a")
    ns.tpush(sb, "b")
    ns.tpush(sb, "cd")
    ns.tpush(sb, "e\rf")
    local x = ns.readline(sb, "\r\n")
    -- can't read \r\n line
    testaux.asserteq(x, nil, "Case 9.1: read non line")
    -- switch delim should invalid cache
    local y = ns.readline(sb, "\r")
    testaux.asserteq(y, "abcde\r", "Case 9.2: read switch delim")
    local z = ns.readall(sb)
    testaux.asserteq(z, "f", "Case 9.3 can't dop the last char")
end

-- Test 10: test node buffer expand
do
    local sb = ns.new(fd)
    for i = 1, 64 do
        ns.tpush(sb, "a")
    end
    local x = ns.read(sb, 64)
    testaux.asserteq(x, string.rep("a", 64), "Case 10.1: read 1 char")
    testaux.asserteq(ns.tcap(sb), 64, "Case 10.2: node buffer not expand")
    ns.tpush(sb, "a")
    ns.tpush(sb, "a")
    testaux.asserteq(ns.tcap(sb), 64, "Case 10.3: node buffer not expand")
    for i = 1, 62 do
        ns.tpush(sb, "a")
    end
    testaux.asserteq(ns.tcap(sb), 64, "Case 10.4: node buffer not expand")
    ns.tpush(sb, "a")
    testaux.asserteq(ns.tcap(sb), 128, "Case 10.5: node buffer expand")
end

print("All netstream edge tests passed!")

