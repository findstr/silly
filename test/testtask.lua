local silly = require "silly"
local task = require "silly.task"
local trace = require "silly.trace"
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
		trace.attach(9)
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
	collectgarbage("stop")
	-- Wakeup coroutine in non-WAIT state
	local co = task.fork(function() end)
	time.sleep(0)  -- co completed, status = nil

	local ok, err = pcall(task.wakeup, co, nil)
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
	collectgarbage("restart")
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

--[==[
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
]==]
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

testaux.case("Test 10: trace.setnode", function()
	-- Test setnode sets the node ID correctly
	trace.setnode(0x1234)

	-- Spawn a new trace and check if node ID is embedded
	trace.spawn()
	local new_traceid = trace.propagate()
	local node_mask = 0xffff
	local node_id = new_traceid & node_mask

	testaux.asserteq(node_id, 0x1234, "Test 10.1: node ID embedded in trace ID")

	-- Change node ID
	trace.setnode(0x5678)
	local new_traceid2 = trace.propagate()
	local node_id2 = new_traceid2 & node_mask

	testaux.asserteq(node_id2, 0x5678, "Test 10.2: node ID updated correctly")

	-- Reset to 0 for other tests
	trace.setnode(0)
end)

testaux.case("Test 11: trace.spawn", function()
	local dump = task._dump()

	-- Get initial trace ID (should be 0 in tests)
	local co = task.running()
	local initial_traceid = dump.task_traceid[co] or 0

	-- Spawn creates new trace ID and returns old one
	local old_traceid = trace.spawn()
	testaux.asserteq(old_traceid, initial_traceid, "Test 11.1: spawn returns old trace ID")

	-- New trace ID should be different and non-zero
	local new_traceid = dump.task_traceid[co]
	testaux.assertneq(new_traceid, 0, "Test 11.2: new trace ID is non-zero")
	testaux.assertneq(new_traceid, old_traceid, "Test 11.3: new trace ID differs from old")

	-- Spawn again should create yet another different ID
	local old_traceid2 = trace.spawn()
	testaux.asserteq(old_traceid2, new_traceid, "Test 11.4: second spawn returns previous ID")

	local new_traceid2 = dump.task_traceid[co]
	testaux.assertneq(new_traceid2, new_traceid, "Test 11.5: each spawn creates unique ID")
end)

testaux.case("Test 12: trace.attach", function()
	local dump = task._dump()
	local co = task.running()

	-- Test attaching specific trace ID
	local old_traceid = trace.attach(0x123456789abcdef0)
	testaux.asserteq(dump.task_traceid[co], 0x123456789abcdef0, "Test 12.1: trace ID attached")

	-- Test returning previous trace ID
	local old_traceid2 = trace.attach(0xfedcba9876543210)
	testaux.asserteq(old_traceid2, 0x123456789abcdef0, "Test 12.2: attach returns old trace ID")
	testaux.asserteq(dump.task_traceid[co], 0xfedcba9876543210, "Test 12.3: new trace ID set")

	-- Test attach(0) clears trace ID
	trace.attach(0)
	local final_traceid = dump.task_traceid[co] or 0
	testaux.asserteq(final_traceid, 0, "Test 12.4: attach(0) clears trace ID")
end)

testaux.case("Test 13: trace.propagate", function()
	-- Set node ID
	trace.setnode(0x1111)

	-- Create a trace ID with different node
	local traceid_with_node2 = 0xabcdef0000002222  -- node ID = 0x2222
	trace.attach(traceid_with_node2)

	-- Propagate should preserve root trace but replace node ID
	local propagated = trace.propagate()

	-- Extract node ID (low 16 bits)
	local node_mask = 0xffff
	local propagated_node = propagated & node_mask
	testaux.asserteq(propagated_node, 0x1111, "Test 13.1: propagate replaces node ID")

	-- Extract root trace (high 48 bits)
	local root_mask = ~node_mask
	local original_root = traceid_with_node2 & root_mask
	local propagated_root = propagated & root_mask
	testaux.asserteq(propagated_root, original_root, "Test 13.2: propagate preserves root trace")

	-- Test propagate with zero trace ID
	trace.attach(0)
	local propagated_zero = trace.propagate()
	local zero_node = propagated_zero & node_mask
	testaux.asserteq(zero_node, 0x1111, "Test 13.3: propagate on zero trace still has node ID")

	-- Reset node ID
	trace.setnode(0)
	trace.attach(0)
end)

testaux.case("Test 14: trace across fork", function()
	local dump = task._dump()

	-- Set parent trace ID
	trace.attach(0x1234567890abcdef)

	local child_traceid
	local co = task.fork(function()
		-- Child should NOT inherit parent's trace ID automatically
		child_traceid = dump.task_traceid[task.running()] or 0
	end)

	time.sleep(0)

	-- Child starts with zero trace (no automatic inheritance)
	testaux.asserteq(child_traceid, 0, "Test 14.1: forked task has no trace by default")

	-- Test manual trace propagation in fork
	trace.attach(0xfedcba0987654321)
	local parent_propagated = trace.propagate()

	local child_received_traceid
	task.fork(function()
		trace.attach(parent_propagated)
		child_received_traceid = dump.task_traceid[task.running()]
	end)

	time.sleep(0)
	testaux.asserteq(child_received_traceid, parent_propagated,
		"Test 14.2: manual trace propagation works")

	trace.attach(0)
end)

testaux.case("Test 15: task.readycount", function()
	-- Initially no ready tasks (we're running)
	local initial_count = task.readycount()
	testaux.asserteq(initial_count, 0, "Test 15.1: initial ready count is 0")

	-- Fork 5 tasks
	for i = 1, 5 do
		task.fork(function()
			task.wait()
		end)
	end

	-- All 5 should be in ready queue
	local count_after_fork = task.readycount()
	testaux.asserteq(count_after_fork, 5, "Test 15.2: ready count is 5 after forking")

	-- Let them run and enter WAIT
	time.sleep(0)
	local count_after_wait = task.readycount()
	testaux.asserteq(count_after_wait, 0, "Test 15.3: ready count is 0 after tasks wait")
end)

testaux.case("Test 16: task.inspect", function()
	local co1, co2

	co1 = task.fork(function()
		task.wait()
	end)

	co2 = task.fork(function()
		task.wait()
	end)

	time.sleep(0)  -- Let tasks enter WAIT

	-- Inspect should return all active tasks
	local tasks = task.inspect()

	-- Should have at least our 2 tasks plus current running task
	local count = 0
	for _ in pairs(tasks) do
		count = count + 1
	end
	testaux.assertgt(count, 2, "Test 16.1: inspect returns multiple tasks")

	-- Check our tasks are in the result
	testaux.assertneq(tasks[co1], nil, "Test 16.2: co1 in inspect result")
	testaux.assertneq(tasks[co2], nil, "Test 16.3: co2 in inspect result")

	-- Check structure
	testaux.asserteq(tasks[co1].status, "WAIT", "Test 16.4: co1 status is WAIT")
	testaux.asserteq(tasks[co2].status, "WAIT", "Test 16.5: co2 status is WAIT")
	testaux.asserteq(type(tasks[co1].traceback), "string", "Test 16.6: traceback is string")
	testaux.assertgt(#tasks[co1].traceback, 0, "Test 16.7: traceback is non-empty")

	-- Cleanup
	task.wakeup(co1, nil)
	task.wakeup(co2, nil)
	time.sleep(0)
end)

testaux.case("Test 17: task.hook", function()
	collectgarbage("collect")
	collectgarbage("collect")
	local created_tasks = {}
	local terminated_tasks = {}

	-- Set hooks
	local old_resume, old_yield = task.hook(
		function(t)
			table.insert(created_tasks, t)
		end,
		function(t)
			table.insert(terminated_tasks, t)
		end
	)

	testaux.asserteq(type(old_resume), "function", "Test 17.1: hook returns resume function")
	testaux.asserteq(type(old_yield), "function", "Test 17.2: hook returns yield function")

	-- Fork some tasks
	local co1 = task.fork(function() end)
	local co2 = task.fork(function() end)

	-- Check creation hook was called
	testaux.asserteq(#created_tasks, 2, "Test 17.3: creation hook called twice")
	testaux.asserteq(created_tasks[1], co1, "Test 17.4: first created task is co1")
	testaux.asserteq(created_tasks[2], co2, "Test 17.5: second created task is co2")

	-- Let tasks complete
	time.sleep(0)

	-- Check termination hook was called
	testaux.asserteq(#terminated_tasks, 2, "Test 17.6: termination hook called twice")
	testaux.asserteq(terminated_tasks[1], co1, "Test 17.7: first terminated task is co1")
	testaux.asserteq(terminated_tasks[2], co2, "Test 17.8: second terminated task is co2")

	-- Clear hooks
	task.hook()

	-- Fork another task - should not trigger hooks
	local before_count = #created_tasks
	task.fork(function() end)
	time.sleep(0)
	testaux.asserteq(#created_tasks, before_count, "Test 17.9: hook cleared successfully")
end)

collectgarbage("restart")