local list = require "silly.adt.list"
local testaux = require "test.testaux"

-- Helper function to verify list internal consistency
local function verify_list_integrity(l, expected_values, test_prefix)
	-- Check size
	testaux.asserteq(l:size(), #expected_values, test_prefix .. ": size should match expected")

	if #expected_values == 0 then
		-- Empty list checks
		testaux.asserteq(l.head, nil, test_prefix .. ": head should be nil for empty list")
		testaux.asserteq(l.tail, nil, test_prefix .. ": tail should be nil for empty list")
		testaux.asserteq(l.count, 0, test_prefix .. ": count should be 0 for empty list")

		-- All internal tables should be empty
		for k, _ in pairs(l.next) do
			testaux.asserteq(true, false, test_prefix .. ": next table should be empty but has key " .. tostring(k))
		end
		for k, _ in pairs(l.prev) do
			testaux.asserteq(true, false, test_prefix .. ": prev table should be empty but has key " .. tostring(k))
		end
		for k, _ in pairs(l.present) do
			testaux.asserteq(true, false, test_prefix .. ": present table should be empty but has key " .. tostring(k))
		end
	else
		-- Non-empty list checks
		testaux.asserteq(l.head, expected_values[1], test_prefix .. ": head should be first element")
		testaux.asserteq(l.tail, expected_values[#expected_values], test_prefix .. ": tail should be last element")
		testaux.asserteq(l.count, #expected_values, test_prefix .. ": count should match")

		-- Verify forward links
		for i = 1, #expected_values do
			local v = expected_values[i]
			testaux.asserteq(l.present[v], true, test_prefix .. ": present[" .. tostring(v) .. "] should be true")

			if i < #expected_values then
				testaux.asserteq(l.next[v], expected_values[i+1], test_prefix .. ": next[" .. tostring(v) .. "] should be " .. tostring(expected_values[i+1]))
			else
				testaux.asserteq(l.next[v], nil, test_prefix .. ": next[" .. tostring(v) .. "] should be nil (tail)")
			end

			if i > 1 then
				testaux.asserteq(l.prev[v], expected_values[i-1], test_prefix .. ": prev[" .. tostring(v) .. "] should be " .. tostring(expected_values[i-1]))
			else
				testaux.asserteq(l.prev[v], nil, test_prefix .. ": prev[" .. tostring(v) .. "] should be nil (head)")
			end
		end

		-- Verify values() iterator matches expected
		local actual = {}
		for v in l:values() do
			table.insert(actual, v)
		end
		testaux.asserteq(#actual, #expected_values, test_prefix .. ": iterator should yield correct count")
		for i = 1, #expected_values do
			testaux.asserteq(actual[i], expected_values[i], test_prefix .. ": iterator value[" .. i .. "] should match")
		end
	end
end

testaux.case("Test 1: Basic pushback operations", function()
	local l = list.new()
	verify_list_integrity(l, {}, "Test 1.1")

	l:pushback(1)
	verify_list_integrity(l, {1}, "Test 1.2")

	l:pushback(2)
	verify_list_integrity(l, {1, 2}, "Test 1.3")

	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 1.4")
end)

testaux.case("Test 2: Basic pushfront operations", function()
	local l = list.new()

	l:pushfront(1)
	verify_list_integrity(l, {1}, "Test 2.1")

	l:pushfront(2)
	verify_list_integrity(l, {2, 1}, "Test 2.2")

	l:pushfront(3)
	verify_list_integrity(l, {3, 2, 1}, "Test 2.3")
end)

testaux.case("Test 3: Popfront operations with internal state verification", function()
	local l = list.new()

	-- Pop from empty list
	local v = l:popfront()
	testaux.asserteq(v, nil, "Test 3.1: Popfront from empty list should return nil")
	verify_list_integrity(l, {}, "Test 3.2")

	-- Build list [1, 2, 3]
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 3.3")

	-- Pop 1
	v = l:popfront()
	testaux.asserteq(v, 1, "Test 3.4: Should pop 1")
	testaux.asserteq(l.head, 2, "Test 3.5: head should now be 2")
	testaux.asserteq(l.next[1], nil, "Test 3.6: next[1] should be nil")
	testaux.asserteq(l.prev[1], nil, "Test 3.7: prev[1] should be nil")
	testaux.asserteq(l.present[1], nil, "Test 3.8: present[1] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 3.9: prev[2] should be nil (new head)")
	verify_list_integrity(l, {2, 3}, "Test 3.10")

	-- Pop 2
	v = l:popfront()
	testaux.asserteq(v, 2, "Test 3.11: Should pop 2")
	testaux.asserteq(l.head, 3, "Test 3.12: head should now be 3")
	testaux.asserteq(l.next[2], nil, "Test 3.13: next[2] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 3.14: prev[2] should be nil")
	testaux.asserteq(l.present[2], nil, "Test 3.15: present[2] should be nil")
	verify_list_integrity(l, {3}, "Test 3.16")

	-- Pop 3 (last element)
	v = l:popfront()
	testaux.asserteq(v, 3, "Test 3.17: Should pop 3")
	testaux.asserteq(l.head, nil, "Test 3.18: head should be nil")
	testaux.asserteq(l.tail, nil, "Test 3.19: tail should be nil")
	testaux.asserteq(l.next[3], nil, "Test 3.20: next[3] should be nil")
	testaux.asserteq(l.prev[3], nil, "Test 3.21: prev[3] should be nil")
	testaux.asserteq(l.present[3], nil, "Test 3.22: present[3] should be nil")
	verify_list_integrity(l, {}, "Test 3.23")
end)

testaux.case("Test 4: Popback operations with internal state verification", function()
	local l = list.new()

	-- Pop from empty list
	local v = l:popback()
	testaux.asserteq(v, nil, "Test 4.1: Popback from empty list should return nil")
	verify_list_integrity(l, {}, "Test 4.2")

	-- Build list [1, 2, 3]
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 4.3")

	-- Pop 3
	v = l:popback()
	testaux.asserteq(v, 3, "Test 4.4: Should pop 3")
	testaux.asserteq(l.tail, 2, "Test 4.5: tail should now be 2")
	testaux.asserteq(l.next[3], nil, "Test 4.6: next[3] should be nil")
	testaux.asserteq(l.prev[3], nil, "Test 4.7: prev[3] should be nil")
	testaux.asserteq(l.present[3], nil, "Test 4.8: present[3] should be nil")
	testaux.asserteq(l.next[2], nil, "Test 4.9: next[2] should be nil (new tail)")
	verify_list_integrity(l, {1, 2}, "Test 4.10")

	-- Pop 2
	v = l:popback()
	testaux.asserteq(v, 2, "Test 4.11: Should pop 2")
	testaux.asserteq(l.tail, 1, "Test 4.12: tail should now be 1")
	testaux.asserteq(l.next[2], nil, "Test 4.13: next[2] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 4.14: prev[2] should be nil")
	testaux.asserteq(l.present[2], nil, "Test 4.15: present[2] should be nil")
	verify_list_integrity(l, {1}, "Test 4.16")

	-- Pop 1 (last element)
	v = l:popback()
	testaux.asserteq(v, 1, "Test 4.17: Should pop 1")
	testaux.asserteq(l.head, nil, "Test 4.18: head should be nil")
	testaux.asserteq(l.tail, nil, "Test 4.19: tail should be nil")
	testaux.asserteq(l.next[1], nil, "Test 4.20: next[1] should be nil")
	testaux.asserteq(l.prev[1], nil, "Test 4.21: prev[1] should be nil")
	testaux.asserteq(l.present[1], nil, "Test 4.22: present[1] should be nil")
	verify_list_integrity(l, {}, "Test 4.23")
end)

testaux.case("Test 5: Remove middle element with link verification", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	l:pushback(4)
	l:pushback(5)
	verify_list_integrity(l, {1, 2, 3, 4, 5}, "Test 5.1")

	-- Remove 3 from middle
	l:remove(3)
	testaux.asserteq(l.next[3], nil, "Test 5.2: next[3] should be nil")
	testaux.asserteq(l.prev[3], nil, "Test 5.3: prev[3] should be nil")
	testaux.asserteq(l.present[3], nil, "Test 5.4: present[3] should be nil")
	testaux.asserteq(l.next[2], 4, "Test 5.5: next[2] should now be 4")
	testaux.asserteq(l.prev[4], 2, "Test 5.6: prev[4] should now be 2")
	testaux.asserteq(l.head, 1, "Test 5.7: head should still be 1")
	testaux.asserteq(l.tail, 5, "Test 5.8: tail should still be 5")
	verify_list_integrity(l, {1, 2, 4, 5}, "Test 5.9")

	-- Remove 2 from new middle
	l:remove(2)
	testaux.asserteq(l.next[2], nil, "Test 5.10: next[2] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 5.11: prev[2] should be nil")
	testaux.asserteq(l.present[2], nil, "Test 5.12: present[2] should be nil")
	testaux.asserteq(l.next[1], 4, "Test 5.13: next[1] should now be 4")
	testaux.asserteq(l.prev[4], 1, "Test 5.14: prev[4] should now be 1")
	verify_list_integrity(l, {1, 4, 5}, "Test 5.15")
end)

testaux.case("Test 6: Remove head element with head update", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 6.1")

	-- Remove head (1)
	l:remove(1)
	testaux.asserteq(l.head, 2, "Test 6.2: head should now be 2")
	testaux.asserteq(l.next[1], nil, "Test 6.3: next[1] should be nil")
	testaux.asserteq(l.prev[1], nil, "Test 6.4: prev[1] should be nil")
	testaux.asserteq(l.present[1], nil, "Test 6.5: present[1] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 6.6: prev[2] should be nil (new head)")
	verify_list_integrity(l, {2, 3}, "Test 6.7")

	-- Remove new head (2)
	l:remove(2)
	testaux.asserteq(l.head, 3, "Test 6.8: head should now be 3")
	testaux.asserteq(l.tail, 3, "Test 6.9: tail should still be 3")
	testaux.asserteq(l.next[2], nil, "Test 6.10: next[2] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 6.11: prev[2] should be nil")
	testaux.asserteq(l.present[2], nil, "Test 6.12: present[2] should be nil")
	verify_list_integrity(l, {3}, "Test 6.13")
end)

testaux.case("Test 7: Remove tail element with tail update", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 7.1")

	-- Remove tail (3)
	l:remove(3)
	testaux.asserteq(l.tail, 2, "Test 7.2: tail should now be 2")
	testaux.asserteq(l.next[3], nil, "Test 7.3: next[3] should be nil")
	testaux.asserteq(l.prev[3], nil, "Test 7.4: prev[3] should be nil")
	testaux.asserteq(l.present[3], nil, "Test 7.5: present[3] should be nil")
	testaux.asserteq(l.next[2], nil, "Test 7.6: next[2] should be nil (new tail)")
	verify_list_integrity(l, {1, 2}, "Test 7.7")

	-- Remove new tail (2)
	l:remove(2)
	testaux.asserteq(l.tail, 1, "Test 7.8: tail should now be 1")
	testaux.asserteq(l.head, 1, "Test 7.9: head should still be 1")
	testaux.asserteq(l.next[2], nil, "Test 7.10: next[2] should be nil")
	testaux.asserteq(l.prev[2], nil, "Test 7.11: prev[2] should be nil")
	testaux.asserteq(l.present[2], nil, "Test 7.12: present[2] should be nil")
	verify_list_integrity(l, {1}, "Test 7.13")
end)

testaux.case("Test 8: Clear should clean all internal structures", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)
	l:pushback(4)
	l:pushback(5)

	-- Verify elements exist before clear
	testaux.asserteq(l.present[1], true, "Test 8.1: present[1] should be true before clear")
	testaux.asserteq(l.present[3], true, "Test 8.2: present[3] should be true before clear")
	testaux.assertneq(l.next[1], nil, "Test 8.3: next[1] should not be nil before clear")
	testaux.assertneq(l.prev[5], nil, "Test 8.4: prev[5] should not be nil before clear")

	l:clear()

	-- Verify complete cleanup
	verify_list_integrity(l, {}, "Test 8.5")

	-- Should be able to reuse the list
	l:pushback(1)
	l:pushback(2)
	verify_list_integrity(l, {1, 2}, "Test 8.6")
end)

testaux.case("Test 9: Duplicate value error handling", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)

	-- Try to push duplicate with pushback
	local ok, err = pcall(function() l:pushback(1) end)
	testaux.asserteq(ok, false, "Test 9.1: Pushing duplicate should error")
	testaux.assertneq(err:find("duplicated"), nil, "Test 9.2: Error should mention 'duplicated'")
	verify_list_integrity(l, {1, 2}, "Test 9.3")

	-- Try to push duplicate with pushfront
	ok, err = pcall(function() l:pushfront(2) end)
	testaux.asserteq(ok, false, "Test 9.4: Pushfront duplicate should error")
	verify_list_integrity(l, {1, 2}, "Test 9.5")
end)

testaux.case("Test 10: Nil value error handling", function()
	local l = list.new()

	-- Try to push nil with pushback
	local ok, err = pcall(function() l:pushback(nil) end)
	testaux.asserteq(ok, false, "Test 10.1: Pushing nil should error")
	testaux.assertneq(err:find("cannot be nil"), nil, "Test 10.2: Error should mention 'cannot be nil'")

	-- Try to push nil with pushfront
	ok, err = pcall(function() l:pushfront(nil) end)
	testaux.asserteq(ok, false, "Test 10.3: Pushfront nil should error")

	verify_list_integrity(l, {}, "Test 10.4")
end)

testaux.case("Test 11: Mixed push operations", function()
	local l = list.new()

	l:pushback(2)
	verify_list_integrity(l, {2}, "Test 11.1")

	l:pushfront(1)
	verify_list_integrity(l, {1, 2}, "Test 11.2")

	l:pushback(3)
	verify_list_integrity(l, {1, 2, 3}, "Test 11.3")

	l:pushfront(0)
	verify_list_integrity(l, {0, 1, 2, 3}, "Test 11.4")
end)

testaux.case("Test 12: Complex alternating operations", function()
	local l = list.new()

	-- Build [1, 2, 3, 4, 5]
	for i = 1, 5 do
		l:pushback(i)
	end
	verify_list_integrity(l, {1, 2, 3, 4, 5}, "Test 12.1")

	-- Pop from both ends -> [2, 3, 4]
	l:popfront()
	l:popback()
	verify_list_integrity(l, {2, 3, 4}, "Test 12.2")

	-- Add to both ends -> [0, 2, 3, 4, 6]
	l:pushfront(0)
	l:pushback(6)
	verify_list_integrity(l, {0, 2, 3, 4, 6}, "Test 12.3")

	-- Remove middle -> [0, 2, 4, 6]
	l:remove(3)
	testaux.asserteq(l.next[2], 4, "Test 12.4: next[2] should be 4 after removing 3")
	testaux.asserteq(l.prev[4], 2, "Test 12.5: prev[4] should be 2 after removing 3")
	verify_list_integrity(l, {0, 2, 4, 6}, "Test 12.6")
end)

testaux.case("Test 13: Re-add after removal", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)
	l:pushback(3)

	-- Remove 2
	l:remove(2)
	testaux.asserteq(l.present[2], nil, "Test 13.1: present[2] should be nil")
	verify_list_integrity(l, {1, 3}, "Test 13.2")

	-- Should be able to add 2 again
	l:pushback(2)
	testaux.asserteq(l.present[2], true, "Test 13.3: present[2] should be true again")
	verify_list_integrity(l, {1, 3, 2}, "Test 13.4")

	-- Pop and re-add
	local v = l:popfront()
	testaux.asserteq(v, 1, "Test 13.5: Should pop 1")
	testaux.asserteq(l.present[1], nil, "Test 13.6: present[1] should be nil after pop")
	verify_list_integrity(l, {3, 2}, "Test 13.7")

	l:pushfront(1)
	verify_list_integrity(l, {1, 3, 2}, "Test 13.8")
end)

testaux.case("Test 14: Double remove should return error", function()
	local l = list.new()
	l:pushback(1)
	l:pushback(2)

	l:remove(1)
	verify_list_integrity(l, {2}, "Test 14.1")

	-- Try to remove again
	local _, err = l:remove(1)
	testaux.asserteq(err, "removed", "Test 14.2: Should return 'removed' error")
	verify_list_integrity(l, {2}, "Test 14.3")
end)

testaux.case("Test 15: String and table values", function()
	local l = list.new()

	l:pushback("hello")
	l:pushback("world")
	l:pushfront("foo")
	verify_list_integrity(l, {"foo", "hello", "world"}, "Test 15.1")

	-- Test with table values
	local t1 = {a = 1}
	local t2 = {b = 2}
	local l2 = list.new()
	l2:pushback(t1)
	l2:pushback(t2)
	verify_list_integrity(l2, {t1, t2}, "Test 15.2")

	l2:remove(t1)
	testaux.asserteq(l2.present[t1], nil, "Test 15.3: present[t1] should be nil after remove")
	verify_list_integrity(l2, {t2}, "Test 15.4")
end)

testaux.case("Test 16: Large list stress test", function()
	local l = list.new()
	local n = 100

	-- Push many elements
	local expected = {}
	for i = 1, n do
		l:pushback(i)
		table.insert(expected, i)
	end
	verify_list_integrity(l, expected, "Test 16.1")

	-- Pop half from front
	for i = 1, n/2 do
		local v = l:popfront()
		testaux.asserteq(v, i, "Test 16.2." .. i .. ": Should pop " .. i)
		testaux.asserteq(l.present[v], nil, "Test 16.3." .. i .. ": present[" .. v .. "] should be nil")
		testaux.asserteq(l.next[v], nil, "Test 16.4." .. i .. ": next[" .. v .. "] should be nil")
		testaux.asserteq(l.prev[v], nil, "Test 16.5." .. i .. ": prev[" .. v .. "] should be nil")
	end

	expected = {}
	for i = n/2 + 1, n do
		table.insert(expected, i)
	end
	verify_list_integrity(l, expected, "Test 16.6")

	-- Clear and verify
	l:clear()
	verify_list_integrity(l, {}, "Test 16.7")
end)

testaux.case("Test 17: Single element list operations", function()
	local l = list.new()

	l:pushback(42)
	testaux.asserteq(l.head, 42, "Test 17.1: head should be 42")
	testaux.asserteq(l.tail, 42, "Test 17.2: tail should be 42")
	testaux.asserteq(l.prev[42], nil, "Test 17.3: prev[42] should be nil")
	testaux.asserteq(l.next[42], nil, "Test 17.4: next[42] should be nil")
	testaux.asserteq(l.present[42], true, "Test 17.5: present[42] should be true")
	verify_list_integrity(l, {42}, "Test 17.6")

	-- Pop the only element
	local v = l:popback()
	testaux.asserteq(v, 42, "Test 17.7: Should pop 42")
	testaux.asserteq(l.head, nil, "Test 17.8: head should be nil")
	testaux.asserteq(l.tail, nil, "Test 17.9: tail should be nil")
	testaux.asserteq(l.next[42], nil, "Test 17.10: next[42] should be nil")
	testaux.asserteq(l.prev[42], nil, "Test 17.11: prev[42] should be nil")
	testaux.asserteq(l.present[42], nil, "Test 17.12: present[42] should be nil")
	verify_list_integrity(l, {}, "Test 17.13")

	-- Should be able to add again
	l:pushfront(42)
	verify_list_integrity(l, {42}, "Test 17.14")
end)

testaux.case("Test 18: Remove all elements one by one", function()
	local l = list.new()
	l:pushback(10)
	l:pushback(20)
	l:pushback(30)
	l:pushback(40)

	-- Remove in arbitrary order
	l:remove(20)
	verify_list_integrity(l, {10, 30, 40}, "Test 18.1")
	testaux.asserteq(l.next[10], 30, "Test 18.2: next[10] should be 30")
	testaux.asserteq(l.prev[30], 10, "Test 18.3: prev[30] should be 10")

	l:remove(40)
	verify_list_integrity(l, {10, 30}, "Test 18.4")
	testaux.asserteq(l.tail, 30, "Test 18.5: tail should be 30")
	testaux.asserteq(l.next[30], nil, "Test 18.6: next[30] should be nil")

	l:remove(10)
	verify_list_integrity(l, {30}, "Test 18.7")
	testaux.asserteq(l.head, 30, "Test 18.8: head should be 30")
	testaux.asserteq(l.prev[30], nil, "Test 18.9: prev[30] should be nil")

	l:remove(30)
	verify_list_integrity(l, {}, "Test 18.10")
end)
