local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

collectgarbage("stop")
testaux.case("Test 1: Basic fork", function()
	local executed = false

	task.fork(function()
		executed = true
	end)
	while not executed do
		time.sleep(10)
	end
end)

testaux.case("Test 2: lifecycle", function()
	collectgarbage("collect")
	collectgarbage("collect")
	local dump = task._dump()
	testaux.asserteq(next(dump.copool), nil, "Test 2.1: task pool is empty")
	local co1
	co1 = task.fork(function()
		task.traceset(9)
		testaux.asserteq(dump.task_traceid[co1], 9, "Test 2.2: task traceid is set")
	end)
	testaux.asserteq(task.status(co1), "READY", "Test 2.3: initial status is READY")
	time.sleep(0)
	testaux.asserteq(#dump.copool, 1, "Test 2.4: coroutine pool is cached")
	testaux.asserteq(dump.task_status[co1], nil, "Test 2.5: task status is clear")
	testaux.asserteq(dump.task_traceid[co1], nil, "Test 2.6: task status is clear")
	local co2 = task.fork(function()end)
	testaux.asserteq(task.status(co2), "READY", "Test 2.7: initial status is READY")
	testaux.asserteq(co1, co2, "Test 2.8: coroutine pool reuse")
	time.sleep(0)
	testaux.asserteq(dump.task_status[co2], nil, "Test 2.9: task status is clear")
	testaux.asserteq(dump.task_traceid[co2], nil, "Test 2.10: task status is clear")
end)

testaux.case("Test 3: wait and wakeup", function()
	local co
	local ok = false
	co = task.fork(function()
		testaux.asserteq(task.status(co), "RUN", "Test 3.1: run status is RUN")
		local value = task.wait()
		testaux.asserteq(task.status(co), "RUN", "Test 3.2: run status is RUN")
		testaux.asserteq(value, "test_value", "Test 3.3: wait hasn't returned")
		ok = true
	end)
	testaux.asserteq(task.status(co), "READY", "Test 3.4: fork status is READY")
	time.sleep(0)
	testaux.asserteq(task.status(co), "WAIT", "Test 3.5: wait status is WAIT")
	task.wakeup(co, "test_value")
	while not ok do
		time.sleep(100)
	end
	testaux.asserteq(task.status(co), nil, "Test 3.6: status cleaned after completion")
end)

testaux.case("Test 4: error handling", function()
	local dump = task._dump()
	local co = task.fork(function()
		error("crash simulate")
	end)
	testaux.asserteq(task.status(co), "READY", "Test 4.1: status before execution")
	time.sleep(0)  -- Execute and error out
	-- Should be cleaned up after error
	testaux.asserteq(dump.task_status[co], nil, "Test 4.2: status cleaned after error")
	testaux.asserteq(dump.task_traceid[co], nil, "Test 4.3: traceid cleaned after error")
end)

testaux.case("Test 5: multiple wait/wakeup", function()
	local results = {}
	local co
	co = task.fork(function()
		results[1] = task.wait()
		results[2] = task.wait()
		results[3] = task.wait()
	end)

	time.sleep(0)  -- Enter first wait
	testaux.asserteq(task.status(co), "WAIT", "Test 5.1: first wait")
	task.wakeup(co, "a")

	time.sleep(0)  -- Enter second wait
	testaux.asserteq(task.status(co), "WAIT", "Test 5.2: second wait")
	task.wakeup(co, "b")

	time.sleep(0)  -- Enter third wait
	testaux.asserteq(task.status(co), "WAIT", "Test 5.3: third wait")
	task.wakeup(co, "c")

	time.sleep(0)  -- Complete execution
	testaux.asserteq(results[1], "a", "Test 5.4: first value")
	testaux.asserteq(results[2], "b", "Test 5.5: second value")
	testaux.asserteq(results[3], "c", "Test 5.6: third value")
	testaux.asserteq(task.status(co), nil, "Test 5.7: status cleaned after completion")
end)

testaux.case("Test 6: invalid operations", function()
	-- Wakeup coroutine in non-WAIT state
	local co = task.fork(function() end)
	time.sleep(0)  -- co completed, status = nil

	local ok, err = pcall(task.wakeup, co, nil)
	print("ok, err", ok, err)
	testaux.asserteq(ok, false, "Test 6.1: wakeup on nil status should fail")

	-- Wakeup coroutine in READY state
	local co2 = task.fork(function() task.wait() end)
	-- co2 is READY, not yet executed
	ok, err = pcall(task.wakeup, co2, nil)
	testaux.asserteq(ok, false, "Test 6.3: wakeup on READY should fail")
	testaux.assertneq(err:find("BUG"), nil, "Test 6.4: error contains 'BUG'")

	-- Cleanup co2
	time.sleep(0)  -- Enter WAIT
	task.wakeup(co2, nil)
	-- Wakeup coroutine in RUN state
	local co3
	co3 = task.fork(function()
		ok, err = pcall(task.wakeup, co2, nil)
		testaux.asserteq(ok, false, "Test 6.5: wakeup on RUN should fail")
		testaux.assertneq(err:find("BUG"), nil, "Test 6.6: error contains 'BUG'")
	end)
	time.sleep(0)
end)

testaux.case("Test 7: concurrent wait tasks", function()
	local dump = task._dump()
	local tasks = {}
	local count = 0

	-- Create 10 waiting tasks
	for i = 1, 10 do
		tasks[i] = task.fork(function()
			local v = task.wait()
			count = count + v
		end)
	end

	time.sleep(0)  -- All enter WAIT

	-- Verify all in WAIT state (strong reference keeps them alive)
	for i = 1, 10 do
		testaux.asserteq(dump.task_status[tasks[i]], "WAIT",
			"Test 7.1." .. i .. ": task in WAIT")
	end

	-- Wakeup all
	for i = 1, 10 do
		task.wakeup(tasks[i], 1)
	end

	time.sleep(0)  -- All complete

	testaux.asserteq(count, 10, "Test 7.2: all tasks completed")

	-- Verify all cleaned up
	for i = 1, 10 do
		testaux.asserteq(dump.task_status[tasks[i]], nil,
			"Test 7.3." .. i .. ": task cleaned")
	end
end)

testaux.case("Test 8: orphaned WAIT tasks (strong reference)", function()
	local dump = task._dump()
	local orphans = setmetatable({}, {__mode = "v"})

	-- Create 5 tasks that will never be woken up (simulating forgotten conn:close())
	for i = 1, 5 do
		orphans[i] = task.fork(function()
			task.wait()  -- Wait forever
		end)
	end

	time.sleep(0)  -- Enter WAIT
	collectgarbage("collect")
	collectgarbage("collect")
	-- Verify they remain in task_status (strong reference prevents GC)
	for i = 1, 5 do
		testaux.asserteq(dump.task_status[orphans[i]], "WAIT",
			"Test 8.1." .. i .. ": orphaned task still tracked")
	end

	-- Manual cleanup (simulating conn:close() behavior)
	for i = 1, 5 do
		task.wakeup(orphans[i], "cleanup")
	end

	time.sleep(0)  -- Complete execution

	-- Now they should be cleaned up
	for i = 1, 5 do
		testaux.asserteq(dump.task_status[orphans[i]], nil,
			"Test 8.2." .. i .. ": cleaned after wakeup")
	end
end)

testaux.case("Test 9: value types through wait/wakeup", function()
	-- Test passing different value types
	local test_cases = {
		{"string", "hello"},
		{"number", 42},
		{"boolean", true},
		{"nil", nil},
		{"table", {a = 1, b = 2}},
	}

	for _, tc in ipairs(test_cases) do
		local name, value = tc[1], tc[2]
		local result
		local co = task.fork(function()
			result = task.wait()
		end)
		time.sleep(0)  -- Enter WAIT
		task.wakeup(co, value)
		time.sleep(0)  -- Complete execution

		if type(value) == "table" then
			testaux.asserteq(type(result), "table", "Test 9." .. name .. ": type")
		else
			testaux.asserteq(result, value, "Test 9." .. name .. ": value")
		end
	end
end)

collectgarbage("restart")