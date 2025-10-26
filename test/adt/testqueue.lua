local queue = require "silly.adt.queue"
local testaux = require "test.testaux"

-- Test 1: Basic push/pop operations
do
	local q = queue.new()
	testaux.asserteq(q:size(), 0, "Case 1.1: new queue should be empty")

	q:push(1)
	testaux.asserteq(q:size(), 1, "Case 1.2: size should be 1 after one push")

	local val = q:pop()
	testaux.asserteq(val, 1, "Case 1.3: popped value should be 1")
	testaux.asserteq(q:size(), 0, "Case 1.4: queue should be empty after pop")
end

-- Test 2: Pop from empty queue
do
	local q = queue.new()
	local val = q:pop()
	testaux.asserteq(val, nil, "Case 2.1: pop from empty queue should return nil")
	testaux.asserteq(q:size(), 0, "Case 2.2: size should remain 0")
end

-- Test 3: Multiple push/pop operations
do
	local q = queue.new()
	for i = 1, 10 do
		q:push(i)
	end
	testaux.asserteq(q:size(), 10, "Case 3.1: size should be 10")

	for i = 1, 10 do
		local val = q:pop()
		testaux.asserteq(val, i, "Case 3.2." .. i .. ": popped value should be " .. i)
	end
	testaux.asserteq(q:size(), 0, "Case 3.3: queue should be empty")
end

-- Test 4: FIFO order verification
do
	local q = queue.new()
	local values = {42, "hello", nil, true, false, 3.14}
	for i = 1, 6 do
		local v = values[i]
		q:push(v)
	end

	for i = 1, 6 do
		local expected = values[i]
		local val = q:pop()
		testaux.asserteq(val, expected, "Case 4." .. i .. ": FIFO order check")
	end
end

-- Test 5: Stress test - large number of elements
do
	local q = queue.new()
	local N = 10000

	-- Fill queue
	for i = 1, N do
		q:push(i)
	end
	testaux.asserteq(q:size(), N, "Case 5.1: size should be " .. N)

	-- Drain queue
	for i = 1, N do
		local val = q:pop()
		if i % 1000 == 0 then  -- Sample check to avoid too many assertions
			testaux.asserteq(val, i, "Case 5.2." .. i .. ": value check at " .. i)
		end
	end
	testaux.asserteq(q:size(), 0, "Case 5.3: queue should be empty")
end

-- Test 6: Interleaved push/pop
do
	local q = queue.new()

	q:push(1)
	q:push(2)
	testaux.asserteq(q:pop(), 1, "Case 6.1: first pop should be 1")

	q:push(3)
	testaux.asserteq(q:pop(), 2, "Case 6.2: second pop should be 2")
	testaux.asserteq(q:pop(), 3, "Case 6.3: third pop should be 3")
	testaux.asserteq(q:size(), 0, "Case 6.4: queue should be empty")
end

-- Test 7: Steady-state operation (tests compact functionality)
do
	local q = queue.new()

	-- Fill to trigger initial expansion
	for i = 1, 20 do
		q:push(i)
	end

	-- Drain partially
	for i = 1, 15 do
		q:pop()
	end
	testaux.asserteq(q:size(), 5, "Case 7.1: size should be 5")

	-- Continue pushing/popping (should trigger compact)
	for i = 21, 100 do
		q:push(i)
	end

	-- Verify all values in correct order
	for i = 16, 20 do
		testaux.asserteq(q:pop(), i, "Case 7.2." .. i .. ": value should be " .. i)
	end
	for i = 21, 100 do
		if i % 10 == 0 then  -- Sample check
			testaux.asserteq(q:pop(), i, "Case 7.3." .. i .. ": value should be " .. i)
		else
			q:pop()
		end
	end
	testaux.asserteq(q:size(), 0, "Case 7.4: queue should be empty")
end

-- Test 8: Different Lua types
do
	local q = queue.new()

	local values = {
		nil,
		true,
		false,
		42,
		3.14,
		"string",
		{a = 1, b = 2},
	}

	for i = 1, #values do
		q:push(values[i])
	end

	for i = 1, #values do
		local val = q:pop()
		testaux.asserteq(val, values[i], "Case 8." .. i .. ": type check")
	end
end

-- Test 9: Queue with tables (object identity)
do
	local q = queue.new()

	local t1 = {x = 1}
	local t2 = {x = 2}
	local t3 = {x = 3}

	q:push(t1)
	q:push(t2)
	q:push(t3)

	local r1 = q:pop()
	local r2 = q:pop()
	local r3 = q:pop()

	testaux.asserteq(r1, t1, "Case 9.1: object identity for t1")
	testaux.asserteq(r2, t2, "Case 9.2: object identity for t2")
	testaux.asserteq(r3, t3, "Case 9.3: object identity for t3")
	testaux.asserteq(r1.x, 1, "Case 9.4: object content check t1")
	testaux.asserteq(r2.x, 2, "Case 9.5: object content check t2")
	testaux.asserteq(r3.x, 3, "Case 9.6: object content check t3")
end

-- Test 10: Boundary test - single element operations
do
	local q = queue.new()

	for i = 1, 100 do
		q:push(i)
		local val = q:pop()
		if i % 25 == 0 then  -- Sample check
			testaux.asserteq(val, i, "Case 10." .. i .. ": single element check")
			testaux.asserteq(q:size(), 0, "Case 10." .. i .. ".b: empty after pop")
		end
	end
end

-- Test 11: Capacity expansion test
do
	local q = queue.new()

	-- Push beyond initial capacity (8)
	for i = 1, 100 do
		q:push(i)
	end
	testaux.asserteq(q:size(), 100, "Case 11.1: size should be 100")

	-- Verify all values
	for i = 1, 100 do
		if i % 20 == 0 then  -- Sample check
			testaux.asserteq(q:pop(), i, "Case 11.2." .. i .. ": value check")
		else
			q:pop()
		end
	end
end

-- Test 12: Empty queue operations
do
	local q = queue.new()

	for i = 1, 10 do
		local val = q:pop()
		testaux.asserteq(val, nil, "Case 12." .. i .. ": pop should return nil")
		testaux.asserteq(q:size(), 0, "Case 12." .. i .. ".b: size should be 0")
	end
end

-- Test 13: Fill-drain-refill pattern
do
	local q = queue.new()

	-- First fill
	for i = 1, 50 do
		q:push(i)
	end

	-- Drain
	for i = 1, 50 do
		q:pop()
	end
	testaux.asserteq(q:size(), 0, "Case 13.1: queue should be empty")

	-- Refill with different values
	for i = 100, 149 do
		q:push(i)
	end

	-- Verify new values
	for i = 100, 149 do
		if i % 10 == 0 then  -- Sample check
			testaux.asserteq(q:pop(), i, "Case 13.2." .. i .. ": refilled value check")
		else
			q:pop()
		end
	end
end

-- Test 14: Alternating fill/drain (compact stress test)
do
	local q = queue.new()

	for round = 1, 10 do
		-- Fill
		local start = (round - 1) * 10 + 1
		for i = start, start + 9 do
			q:push(i)
		end

		-- Partial drain (leave some elements)
		for i = 1, 5 do
			q:pop()
		end
	end

	-- Should have 10 * 5 = 50 elements remaining
	testaux.asserteq(q:size(), 50, "Case 14.1: size should be 50")

	-- Drain all
	local count = 0
	while q:size() > 0 do
		q:pop()
		count = count + 1
	end
	testaux.asserteq(count, 50, "Case 14.2: should have drained 50 elements")
end

-- Test 15: Large values
do
	local q = queue.new()

	local large = string.rep("x", 100000)  -- 100KB string
	q:push(large)

	local val = q:pop()
	testaux.asserteq(val, large, "Case 15.1: large string preserved")
	testaux.asserteq(#val, 100000, "Case 15.2: large string length correct")
end

-- Test 16: Duplicate values
do
	local q = queue.new()

	for i = 1, 10 do
		q:push(42)
	end

	for i = 1, 10 do
		local val = q:pop()
		testaux.asserteq(val, 42, "Case 16." .. i .. ": duplicate value check")
	end
end

-- Test 17: Queue with functions
do
	local q = queue.new()

	local f1 = function() return 1 end
	local f2 = function() return 2 end
	local f3 = function() return 3 end

	q:push(f1)
	q:push(f2)
	q:push(f3)

	local r1 = q:pop()
	local r2 = q:pop()
	local r3 = q:pop()

	testaux.asserteq(r1(), 1, "Case 17.1: function 1 identity")
	testaux.asserteq(r2(), 2, "Case 17.2: function 2 identity")
	testaux.asserteq(r3(), 3, "Case 17.3: function 3 identity")
end

-- Test 18: Mixed operations pattern
do
	local q = queue.new()

	-- Pattern: push 3, pop 1, repeat
	local pushed = {}
	local popped = {}

	for round = 1, 20 do
		for i = 1, 3 do
			local val = (round - 1) * 3 + i
			q:push(val)
			table.insert(pushed, val)
		end

		local val = q:pop()
		table.insert(popped, val)
	end

	-- Final drain
	while q:size() > 0 do
		table.insert(popped, q:pop())
	end

	-- Verify all values accounted for
	testaux.asserteq(#pushed, 60, "Case 18.1: should have pushed 60 elements")
	testaux.asserteq(#popped, 60, "Case 18.2: should have popped 60 elements")

	-- Verify FIFO order (sample check)
	for i = 1, 60, 10 do
		testaux.asserteq(popped[i], i, "Case 18.3." .. i .. ": FIFO order check")
	end
end

-- Test 19: Size tracking accuracy
do
	local q = queue.new()

	local expected_size = 0
	for i = 1, 50 do
		q:push(i)
		expected_size = expected_size + 1
		if i % 10 == 0 then
			testaux.asserteq(q:size(), expected_size, "Case 19.1." .. i .. ": size after push")
		end
	end

	for i = 1, 50 do
		q:pop()
		expected_size = expected_size - 1
		if i % 10 == 0 then
			testaux.asserteq(q:size(), expected_size, "Case 19.2." .. i .. ": size after pop")
		end
	end
end

-- Test 20: Garbage collection stress - basic
do
	-- Create and discard many queues
	for i = 1, 100 do
		local q = queue.new()
		for j = 1, 100 do
			q:push({data = j})
		end
		-- Queue goes out of scope, should be GC'd
	end

	collectgarbage("collect")

	-- Verify we can still create new queues
	local q = queue.new()
	q:push(1)
	testaux.asserteq(q:pop(), 1, "Case 20.1: queue works after GC")
end

-- Test 20b: GC with table references - ensure tables are not collected while in queue
do
	local q = queue.new()
	local weak_refs = {}
	setmetatable(weak_refs, {__mode = "v"})  -- Weak value table

	-- Push tables and keep weak references
	do
		for i = 1, 10 do
			local t = {value = i}
			q:push(t)
			weak_refs[i] = t
		end
	end

	-- Force GC - tables should NOT be collected (queue holds strong refs)
	collectgarbage("collect")

	-- Verify all tables are still alive via weak references
	for i = 1, 10 do
		testaux.asserteq(weak_refs[i] ~= nil, true, "Case 20b.1." .. i .. ": table still alive in queue")
	end

	-- Pop all tables and verify
	for i = 1, 10 do
		local t = q:pop()
		testaux.asserteq(t.value, i, "Case 20b.2." .. i .. ": table value correct")
	end

	-- Queue should now be empty and all strong references are gone
	testaux.asserteq(q:size(), 0, "Case 20b.3: queue empty after pop")

	-- CRITICAL TEST: After pop, uservalue table should NOT hold strong refs
	-- Force multiple GC cycles to ensure cleanup
	collectgarbage("collect")
	collectgarbage("collect")

	-- Count how many tables were collected
	local collected = 0
	for i = 1, 10 do
		if weak_refs[i] == nil then
			collected = collected + 1
		end
	end

	-- Without proper cleanup in lpop(), collected will be 0 (memory leak!)
	-- With proper cleanup (lua_rawseti(L, -2, ref, nil)), collected should be 10
	testaux.asserteq(collected, 10, "Case 20b.4: all tables collected after pop (uservalue cleanup)")
end

-- Test 20c: Queue GC should free C memory (buf and id_pool)
do
	local function create_large_queue()
		local q = queue.new()
		-- Fill with many elements to trigger capacity expansion
		for i = 1, 1000 do
			q:push({index = i})
		end
		return q
	end

	-- Create and discard many large queues
	for i = 1, 50 do
		local q = create_large_queue()
		-- Queue with large buffer goes out of scope
	end

	collectgarbage("collect")

	-- If __gc doesn't free memory properly, this would cause memory leak
	-- We can't directly test memory leak, but we verify functionality
	local q = queue.new()
	q:push({test = "after_gc"})
	local val = q:pop()
	testaux.asserteq(val.test, "after_gc", "Case 20c.1: queue works after GC cleanup")
end

-- Test 20d: GC during queue operations - interleaved
do
	local q = queue.new()

	-- Push some tables
	for i = 1, 50 do
		q:push({id = i})
	end

	-- Pop some
	for i = 1, 25 do
		q:pop()
	end

	-- Force GC while queue has elements
	collectgarbage("collect")

	-- Continue operations
	for i = 51, 100 do
		q:push({id = i})
	end

	-- Verify correct order: 26-50, then 51-100
	for i = 26, 50 do
		local val = q:pop()
		testaux.asserteq(val.id, i, "Case 20d.1." .. i .. ": value after mid-GC")
	end
	for i = 51, 100 do
		local val = q:pop()
		testaux.asserteq(val.id, i, "Case 20d.2." .. i .. ": value after mid-GC")
	end
end

-- Test 20e: Circular references - queue holding tables with references back
do
	local q = queue.new()

	-- Create tables with circular references
	for i = 1, 10 do
		local t = {value = i}
		t.self = t  -- Self reference
		t.queue = q  -- Reference to queue
		q:push(t)
	end

	collectgarbage("collect")

	-- Verify all tables are intact
	for i = 1, 10 do
		local t = q:pop()
		testaux.asserteq(t.value, i, "Case 20e.1." .. i .. ": circular ref value")
		testaux.asserteq(t.self, t, "Case 20e.2." .. i .. ": self reference intact")
		testaux.asserteq(t.queue, q, "Case 20e.3." .. i .. ": queue reference intact")
	end
end

-- Test 20f: Multiple queues sharing same table objects
do
	local q1 = queue.new()
	local q2 = queue.new()
	local shared_tables = {}

	-- Create shared tables
	for i = 1, 5 do
		shared_tables[i] = {shared = i}
	end

	-- Push same tables to both queues
	for i = 1, 5 do
		q1:push(shared_tables[i])
		q2:push(shared_tables[i])
	end

	collectgarbage("collect")

	-- Pop from q1
	for i = 1, 5 do
		local t1 = q1:pop()
		testaux.asserteq(t1.shared, i, "Case 20f.1." .. i .. ": q1 shared table")
	end

	-- Tables should still be alive in q2
	for i = 1, 5 do
		local t2 = q2:pop()
		testaux.asserteq(t2.shared, i, "Case 20f.2." .. i .. ": q2 shared table")
		testaux.asserteq(t2, shared_tables[i], "Case 20f.3." .. i .. ": same object identity")
	end
end

-- Test 21: Edge case - push same table multiple times
do
	local q = queue.new()
	local t = {x = 42}

	for i = 1, 10 do
		q:push(t)
	end

	for i = 1, 10 do
		local val = q:pop()
		testaux.asserteq(val, t, "Case 21." .. i .. ".a: table identity")
		testaux.asserteq(val.x, 42, "Case 21." .. i .. ".b: table content")
	end
end

-- Test 22: Zero-element boundary after operations
do
	local q = queue.new()

	-- Multiple rounds of fill-drain
	for round = 1, 10 do
		for i = 1, round do
			q:push(i)
		end

		for i = 1, round do
			q:pop()
		end

		testaux.asserteq(q:size(), 0, "Case 22." .. round .. ".a: empty after round")
		testaux.asserteq(q:pop(), nil, "Case 22." .. round .. ".b: pop nil after round")
	end
end

-- Test 23: Compact trigger test (internal state verification)
do
	local q = queue.new()

	-- Fill to capacity
	for i = 1, 100 do
		q:push(i)
	end

	-- Drain most elements
	for i = 1, 90 do
		q:pop()
	end

	-- Now push more (should trigger compact when writei >= bufcap)
	for i = 101, 200 do
		q:push(i)
	end

	-- Verify correct order: remaining original (91-100) + new (101-200)
	for i = 91, 100 do
		testaux.asserteq(q:pop(), i, "Case 23.1." .. i .. ": remaining value")
	end
	for i = 101, 200 do
		if i % 20 == 0 then  -- Sample check
			testaux.asserteq(q:pop(), i, "Case 23.2." .. i .. ": new value")
		else
			q:pop()
		end
	end
	testaux.asserteq(q:size(), 0, "Case 23.3: queue should be empty")
end

-- Test 24: Extremely small values
do
	local q = queue.new()

	q:push(0)
	q:push(-1)
	q:push(-1000000)

	testaux.asserteq(q:pop(), 0, "Case 24.1: zero value")
	testaux.asserteq(q:pop(), -1, "Case 24.2: negative one")
	testaux.asserteq(q:pop(), -1000000, "Case 24.3: large negative")
end

-- Test 25: Boolean edge cases
do
	local q = queue.new()

	for i = 1, 10 do
		q:push(true)
		q:push(false)
	end

	for i = 1, 10 do
		testaux.asserteq(q:pop(), true, "Case 25." .. i .. ".a: true value")
		testaux.asserteq(q:pop(), false, "Case 25." .. i .. ".b: false value")
	end
end

-- Test 26: clear() basic functionality
do
	local q = queue.new()

	-- Push some elements
	for i = 1, 10 do
		q:push(i)
	end
	testaux.asserteq(q:size(), 10, "Case 26.1: size should be 10 before clear")

	-- Clear the queue
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 26.2: size should be 0 after clear")

	-- Verify pop returns nil
	local val = q:pop()
	testaux.asserteq(val, nil, "Case 26.3: pop should return nil after clear")

	-- Verify queue is still usable
	q:push(100)
	testaux.asserteq(q:size(), 1, "Case 26.4: can push after clear")
	val = q:pop()
	testaux.asserteq(val, 100, "Case 26.5: pop returns correct value after clear")
end

-- Test 27: clear() with GC verification - ensure tables are collected
do
	local q = queue.new()
	local weak_refs = {}
	setmetatable(weak_refs, {__mode = "v"})  -- Weak value table

	-- Push tables and keep weak references
	do
		for i = 1, 10 do
			local t = {value = i}
			q:push(t)
			weak_refs[i] = t
		end
	end

	testaux.asserteq(q:size(), 10, "Case 27.1: size should be 10 before clear")

	-- Force GC - tables should NOT be collected (queue holds strong refs)
	collectgarbage("collect")
	for i = 1, 10 do
		testaux.asserteq(weak_refs[i] ~= nil, true, "Case 27.2." .. i .. ": table alive before clear")
	end

	-- Clear the queue
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 27.3: size should be 0 after clear")

	-- Force multiple GC cycles
	collectgarbage("collect")
	collectgarbage("collect")

	-- Count how many tables were collected
	local collected = 0
	for i = 1, 10 do
		if weak_refs[i] == nil then
			collected = collected + 1
		end
	end

	-- With proper clear() implementation, all tables should be collected
	testaux.asserteq(collected, 10, "Case 27.4: all tables collected after clear")
end

-- Test 28: clear() on empty queue
do
	local q = queue.new()

	-- Clear empty queue (should be no-op)
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 28.1: size should remain 0")

	-- Verify queue is still usable
	q:push(42)
	testaux.asserteq(q:pop(), 42, "Case 28.2: queue usable after clearing empty queue")
end

-- Test 29: clear() after partial pop
do
	local q = queue.new()

	-- Push 10 elements
	for i = 1, 10 do
		q:push(i)
	end

	-- Pop 5 elements
	for i = 1, 5 do
		q:pop()
	end
	testaux.asserteq(q:size(), 5, "Case 29.1: size should be 5 after partial pop")

	-- Clear remaining elements
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 29.2: size should be 0 after clear")
	testaux.asserteq(q:pop(), nil, "Case 29.3: pop should return nil after clear")

	-- Verify queue is still usable
	q:push(100)
	testaux.asserteq(q:pop(), 100, "Case 29.4: queue usable after clear")
end

-- Test 30: Multiple clear() operations
do
	local q = queue.new()

	-- Round 1
	for i = 1, 10 do
		q:push(i)
	end
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 30.1: round 1 clear")

	-- Round 2
	for i = 11, 20 do
		q:push(i)
	end
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 30.2: round 2 clear")

	-- Round 3
	for i = 21, 30 do
		q:push(i)
	end
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 30.3: round 3 clear")

	-- Verify queue still works correctly
	q:push(999)
	testaux.asserteq(q:pop(), 999, "Case 30.4: queue usable after multiple clears")
end

-- Test 31: Large queue clear() stress test
do
	local q = queue.new()

	-- Push 1000 elements
	for i = 1, 1000 do
		q:push({index = i, data = "item" .. i})
	end
	testaux.asserteq(q:size(), 1000, "Case 31.1: size should be 1000")

	-- Clear all
	q:clear()
	testaux.asserteq(q:size(), 0, "Case 31.2: size should be 0 after clear")

	-- Verify queue is still usable
	q:push("after_clear")
	testaux.asserteq(q:pop(), "after_clear", "Case 31.3: queue usable after clearing 1000 items")

	-- Push many more and verify
	for i = 1, 100 do
		q:push(i)
	end
	testaux.asserteq(q:size(), 100, "Case 31.4: can push 100 items after clear")

	for i = 1, 100 do
		local val = q:pop()
		if i % 25 == 0 then
			testaux.asserteq(val, i, "Case 31.5." .. i .. ": value check after clear+refill")
		end
	end
end

print("All queue tests completed successfully!")
