local silly = require "silly"
local task = require "silly.task"
local waitgroup = require "silly.sync.waitgroup"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

-- Helper function to create a coroutine that pushes a value and returns result
---@param ch silly.sync.channel
local function push_coroutine(prompt, ch, value, expect_result)
	task.fork(function()
		local success, err = ch:push(value)
		testaux.asserteq(success, expect_result, prompt)
	end)
end

-- Helper function to create a coroutine that pops a value
---@param ch silly.sync.channel
local function pop_coroutine(prompt, ch, expect_result, expect_err)
	local co = task.fork(function()
		local value, err = ch:pop()
		testaux.asserteq(value, expect_result, prompt)
		testaux.asserteq(err, expect_err, prompt)
	end)
	return co
end


-- Test 1: Basic push/pop functionality
do
	local ch = channel.new()

	-- Test push and pop
	local success, err = ch:push("test message")
	testaux.asserteq(success, true, "Case1: Push succeeded")
	testaux.asserteq(err, nil, "Case1: No error on push")

	local value, err = ch:pop()
	testaux.asserteq(value, "test message", "Case1: Pop returns correct value")
	testaux.asserteq(err, nil, "Case1: No error on pop")

	-- Test push and pop with multiple values
	ch:push(1)
	ch:push(2)
	ch:push(3)

	testaux.asserteq(ch:pop(), 1, "Case1: Pop returns first value")
	testaux.asserteq(ch:pop(), 2, "Case1: Pop returns second value")
	testaux.asserteq(ch:pop(), 3, "Case1: Pop returns third value")
end

-- Test 2: Channel queue management
do
	local ch = channel.new()

	-- Fill queue with 100 items
	for i = 1, 100 do
		ch:push(i)
	end

	-- Pop 50 items
	for i = 1, 50 do
		local value = ch:pop()
		testaux.asserteq(value, i, "Case2: Pop returns correct value " .. i)
	end

	-- Pop remaining 50 items
	for i = 51, 100 do
		local value = ch:pop()
		testaux.asserteq(value, i, "Case2: Pop returns correct value " .. i)
	end
end

-- Test 3: Channel wait and wakeup mechanics
do
	local ch = channel.new()

	-- Create a coroutine that will wait for a value
	pop_coroutine("Case3: Waiting coroutine", ch, "wake up", nil)

	-- Push a value which should wake up the waiting coroutine
	ch:push("wake up")

	-- Test multiple waiting coroutines
	pop_coroutine("Case3: Waiting coroutine 2", ch, "for co1", nil)
	pop_coroutine("Case3: Waiting coroutine 3", ch, "for co2", nil)

	ch:push("for co1")
	ch:push("for co2")
end

-- Test 4: Closed channel behavior
do
	local ch = channel.new()

	-- Push to open channel
	local success, err = ch:push("message")
	testaux.asserteq(success, true, "Case4: Push to open channel succeeded")

	-- Close the channel
	ch:close("abcdefg")
	testaux.asserteq(ch.reason, "abcdefg", "Case4: Channel marked as closed")

	-- Try to push to closed channel
	success, err = ch:push("another message")
	testaux.asserteq(success, false, "Case4: Push to closed channel fails")
	testaux.asserteq(err, "abcdefg", "Case4: Push to closed channel returns error")

	-- Pop existing message from closed channel
	local value, err = ch:pop()
	testaux.asserteq(value, "message", "Case4: Pop existing message from closed channel")
	testaux.asserteq(err, nil, "Case4: No error when popping existing message")

	-- Try to pop from empty closed channel
	value, err = ch:pop()
	testaux.asserteq(value, nil, "Case4: Pop from empty closed channel returns nil")
	testaux.asserteq(err, "abcdefg", "Case4: Pop from empty closed channel returns error")

	-- Test closing a channel with waiting coroutine
	ch = channel.new()
	task.fork(function()
		ch:close()
	end)

	local value, err = ch:pop()
	testaux.asserteq(value, nil, "Case4: Pop from closed channel returns nil")
	testaux.asserteq(err, "channel closed", "Case4: Pop from closed channel returns error")
end

-- Test 5: Various data types
do
	local ch = channel.new()

	-- Test with different data types
	local test_values = {
		123,					-- number
		"string",				-- string
		true,				-- boolean
		{1, 2, 3},				-- table
		function() return "func" end, 	-- function
		nil,					-- nil
	}

	for _, val in ipairs(test_values) do
		ch:push(val)
		local popped, err = ch:pop()
		assert(popped, err)
		if type(val) == "function" then
			-- For functions, check that they return the same value
			testaux.asserteq(popped(), val(), "Case5: Function value preserved")
		elseif type(val) == "table" then
			-- For tables, check equality of contents
			testaux.asserteq(#popped, #val, "Case5: Table size preserved")
			for i = 1, #val do
				testaux.asserteq(popped[i], val[i], "Case5: Table contents preserved")
			end
		else
			-- For other types, direct comparison
			testaux.asserteq(popped, val, "Case5: Value preserved for type " .. type(val))
		end
	end
end

-- Test 6: Large batch operations
do
	local ch = channel.new()

	-- Push many items
	for i = 1, 1000 do
		ch:push(i)
	end

	-- Pop all items
	for i = 1, 1000 do
		local value = ch:pop()
		testaux.asserteq(value, i, "Case6: Pop returns correct value " .. i)
	end

	-- Test wait/wakeup after emptying
	pop_coroutine("Case6: Waiting coroutine after empty", ch, "after empty", nil)
	ch:push("after empty")
end

-- Test 7: Concurrent operations
do
	local ch = channel.new()

	-- Start 10 producers and 10 consumers
	local producers = {}
	local wg = waitgroup.new()
	local consumer = wg:fork(function()
		for i = 1, 10 do
			local value, err = ch:pop()
			testaux.asserteq(value, "value" .. i, "Case7: Consumer " .. i .. " received value")
			testaux.asserteq(err, nil, "Case7: Consumer " .. i .. " received value")
		end
	end)

	for i = 1, 10 do
		producers[i] = wg:fork(function()
			local success, err = ch:push("value" .. i)
			testaux.asserteq(success, true, "Case7: Producer " .. i .. " pushed value")
			testaux.asserteq(err, nil, "Case7: Producer " .. i .. " pushed value")
		end)
	end
	wg:wait()

	-- All consumers should receive a value
	local status = task.status(consumer)
	local success = not (status and status ~= "EXIT")
	testaux.asserteq(success, true, "Case7: All consumers received values")

	-- All producers should succeed
	for i = 1, 10 do
		local status = task.status(producers[i])
		if status and status ~= "EXIT" then
			success = false
			break
		end
	end
	testaux.asserteq(success, true, "Case7: All producers succeeded")
end

-- Test 8: Channel close
do
	local ch = channel.new()
	task.fork(function()
		ch:push("test1")
		ch:push("test2")
		ch:close()
	end)
	local value1, err = ch:pop()
	testaux.asserteq(value1, "test1", "Case8: Pop from closed channel returns correct value")
	testaux.asserteq(err, nil, "Case8: Pop from closed channel returns nil error")
	local value2, err = ch:pop()
	testaux.asserteq(value2, "test2", "Case8: Pop from closed channel returns correct value")
	testaux.asserteq(err, nil, "Case8: Pop from closed channel returns nil error")
	local value3, err = ch:pop()
	testaux.asserteq(value3, nil, "Case8: Pop from closed channel returns nil")
	testaux.asserteq(err, "channel closed", "Case8: Pop from closed channel returns error")

	local ch2 = channel.new()
	task.fork(function()
		ch2:push("test1")
		ch2:push("test2")
		ch2:clear()
		ch2:close()
	end)
	local value, err = ch2:pop()
	testaux.asserteq(value, "test1", "Case8: Pop from closed channel returns value")
	testaux.asserteq(err, nil, "Case8: Pop from closed channel returns nil error")

	local value, err = ch2:pop()
	testaux.asserteq(value, nil, "Case8: Pop from closed channel returns nil")
	testaux.asserteq(err, "channel closed", "Case8: Pop from closed channel returns error")

	local ch3 = channel.new()
	task.fork(function()
		ch3:push("test1")
		ch3:clear()
	end)
	local value, err = ch3:pop()
	testaux.asserteq(value, "test1", "Case8: Pop from clear channel returns correct value")
	testaux.asserteq(err, nil, "Case8: Pop from closed channel returns nil error")
end

print("All channel tests passed!")
