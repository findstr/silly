local task = require "silly.task"
local time = require "silly.time"
local channel = require "silly.sync.channel"
local singleflight = require "silly.sync.singleflight"
local testaux = require "test.testaux"

-----------------------------------------------------------------
testaux.case("Test 1: Basic call", function()
	local sf = singleflight.new(function(key)
		return "result-" .. key
	end)
	local result = sf:call("hello")
	testaux.asserteq(result, "result-hello",
		"Test 1.1: Single call returns correct result")
end)

-----------------------------------------------------------------
testaux.case("Test 2: Deduplication", function()
	local call_count = 0
	local sf = singleflight.new(function(key)
		call_count = call_count + 1
		-- Simulate async work so other coroutines can queue up
		time.sleep(100)
		return "shared-" .. key
	end)
	local results = {}
	local done_ch = channel.new()
	-- Launch 5 concurrent calls with the same key
	for i = 1, 5 do
		task.fork(function()
			results[i] = sf:call("dup-key")
			done_ch:push(i)
		end)
	end
	-- Wait for all 5 to complete
	for _ = 1, 5 do
		done_ch:pop()
	end
	testaux.asserteq(call_count, 1,
		"Test 2.1: Function should execute only once")
	for i = 1, 5 do
		testaux.asserteq(results[i], "shared-dup-key",
			"Test 2." .. (i + 1) .. ": Caller " .. i .. " gets shared result")
	end
end)

-----------------------------------------------------------------
testaux.case("Test 3: Different keys", function()
	local call_count = 0
	local sf = singleflight.new(function(key)
		call_count = call_count + 1
		time.sleep(50)
		return "val-" .. key
	end)
	local results = {}
	local done_ch = channel.new()
	-- Launch concurrent calls with DIFFERENT keys
	for i = 1, 3 do
		local k = "key-" .. i
		task.fork(function()
			results[k] = sf:call(k)
			done_ch:push(k)
		end)
	end
	for _ = 1, 3 do
		done_ch:pop()
	end
	testaux.asserteq(call_count, 3,
		"Test 3.1: Different keys execute independently")
	testaux.asserteq(results["key-1"], "val-key-1",
		"Test 3.2: Key 1 result")
	testaux.asserteq(results["key-2"], "val-key-2",
		"Test 3.3: Key 2 result")
	testaux.asserteq(results["key-3"], "val-key-3",
		"Test 3.4: Key 3 result")
end)

-----------------------------------------------------------------
testaux.case("Test 4: Error propagation", function()
	local sf = singleflight.new(function(key)
		time.sleep(50)
		error("boom: " .. key)
	end)
	local errors = {}
	local done_ch = channel.new()
	-- Launch 3 concurrent calls, all should get the error
	for i = 1, 3 do
		task.fork(function()
			local ok, err = pcall(sf.call, sf, "err-key")
			errors[i] = {ok = ok, err = err}
			done_ch:push(i)
		end)
	end
	for _ = 1, 3 do
		done_ch:pop()
	end
	for i = 1, 3 do
		testaux.asserteq(errors[i].ok, false,
			"Test 4." .. i .. ": Caller " .. i .. " should get error")
	end
end)

-----------------------------------------------------------------
testaux.case("Test 5: Sequential reuse", function()
	local call_count = 0
	local sf = singleflight.new(function(key)
		call_count = call_count + 1
		return "run-" .. call_count
	end)
	local r1 = sf:call("reuse-key")
	testaux.asserteq(r1, "run-1",
		"Test 5.1: First call returns first result")
	local r2 = sf:call("reuse-key")
	testaux.asserteq(r2, "run-2",
		"Test 5.2: Second call re-executes (not cached)")
	testaux.asserteq(call_count, 2,
		"Test 5.3: Function executed twice for sequential calls")
end)

-----------------------------------------------------------------
testaux.case("Test 6: Table key", function()
	local my_table = {name = "test"}
	local sf = singleflight.new(function(key)
		time.sleep(50)
		return key.name .. "-resolved"
	end)
	local results = {}
	local done_ch = channel.new()
	-- Launch concurrent calls with same table reference
	for i = 1, 3 do
		task.fork(function()
			results[i] = sf:call(my_table)
			done_ch:push(i)
		end)
	end
	for _ = 1, 3 do
		done_ch:pop()
	end
	for i = 1, 3 do
		testaux.asserteq(results[i], "test-resolved",
			"Test 6." .. i .. ": Table key caller " .. i .. " gets result")
	end
end)
