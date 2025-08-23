local time = require "core.time"
local hc = require "core.hive.c"
local hive = require "core.hive"
local waitgroup = require "core.sync.waitgroup"
local testaux = require "test.testaux"

local prune = hc.prune
hc.prune = function() end

-- Test 1: Cocurrent invoke
do
	local worker = hive.spawn([[
		local init = ...
		return function(a, b)
			return a+init, a+b, a*b
		end
	]], 6)
	local wg = waitgroup.new()
	wg:fork(function()
		local a, b, c = hive.invoke(worker, 2, 3)
		testaux.asserteq(a, 8, "Case 1: result[1]")
		testaux.asserteq(b, 5, "Case 1: result[2]")
		testaux.asserteq(c, 6, "Case 1: result[3]")
	end)
	wg:fork(function()
		local a, b, c = hive.invoke(worker, 3, 5)
		testaux.asserteq(a, 9, "Case 1: result[1]")
		testaux.asserteq(b, 8, "Case 1: result[2]")
		testaux.asserteq(c, 15, "Case 1: result[3]")
	end)
	wg:wait()
end

-- Test 2: Broken code snippet
do
	testaux.assert_error(function()
		hive.spawn([[
			return funcion(a, b)
				return a+1, a+b, a*b
			end
		]])
	end, "Case 2: broken code snippet")
end

-- Test 3: Exception propagation
do
	local worker = hive.spawn([[
		return function(a, b)
			error("$foo$")
		end
	]])
	local ok, err = pcall(hive.invoke, worker, 2, 3)
	testaux.asserteq(ok, false, "Case 3: exception propagation")
	testaux.asserteq(not not err:find("$foo$", 1, true), true, "Case 3: error message")
end

-- Test 4: Table argument
do
	local worker = hive.spawn([[
		local t = ...
		return function(b)
			return t.a+b.a, t.b+b.b, t.c+b.c
		end
	]], {a=1, b=2, c=3})
	local a, b, c = hive.invoke(worker, {a=4, b=5, c=6})
	testaux.asserteq(a, 5, "Case 4: result[1]")
	testaux.asserteq(b, 7, "Case 4: result[2]")
	testaux.asserteq(c, 9, "Case 4: result[3]")
end

-- Test 5: Thread Pool Expansion
do
	hive.limit(2, 4)
	-- After previous tests, threads might be at min. Let's run one task to ensure the pool is active.
	local pre_worker = hive.spawn([[
		return function() return true end
	]])
	hive.invoke(pre_worker)

	local initial_threads = hive.threads()
	testaux.asserteq(initial_threads, 1, "Case 5: initial threads")

	local wg = waitgroup.new()
	for i = 1, 10 do
		wg:fork(function()
			-- Create a new worker for each concurrent task to ensure parallel execution
			local worker = hive.spawn([[
				return function()
					os.execute ('sleep 1')
					return true
				end
			]])
			local ok = hive.invoke(worker)
			testaux.asserteq(ok, true, "Case 5: task result for i="..i)
		end)
	end
	wg:wait()
	testaux.asserteq(hive.threads(), 4, "Case 5: threads scaled up")
end


-- Test 6: Thread Pool Pruning
do
	-- Ensure pool is scaled up first from previous test
	testaux.asserteq(hive.threads(), 4, "Case 6: threads before prune")
	print("sleep 6 seconds for idle threads")
	time.sleep(6000)
	prune()
	local threads = hive.threads()
	testaux.asserteq(threads, 2, "Case 6: threads scaled down")
end
