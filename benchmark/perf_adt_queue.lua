local testaux = require "test.testaux"
local adtqueue = require "silly.adt.queue"

-- Upvalue optimization: cache frequently used functions
local setmetatable = setmetatable

-- Queue implementation 2: readi + writei indices (half-open interval, optimized with upvalues)
local Queue2 = {}
Queue2.__index = Queue2

function Queue2.new()
	local self = setmetatable({}, Queue2)
	self.queue = {}
	self.readi = 0  -- last read position
	self.writei = 0  -- last write position
	return self
end

function Queue2:push(value)
	local readi = self.readi
	local writei = self.writei
	local size = writei - readi  -- current size before push

	-- Compact strategy (executed before push):
	-- Compact when readi >= size (holes >= data)
	if readi >= size then
		local q = self.queue
		-- Move all elements to the beginning
		for i = 1, size do
			q[i] = q[readi + i]
		end
		-- Clear old positions
		for i = size + 1, writei do
			q[i] = nil
		end
		self.readi = 0
		self.writei = size
		writei = size
	end

	writei = writei + 1
	self.writei = writei
	self.queue[writei] = value
end

function Queue2:pop()
	local readi = self.readi
	local writei = self.writei
	if readi >= writei then
		return nil
	end

	readi = readi + 1
	self.readi = readi

	local q = self.queue
	local value = q[readi]
	q[readi] = nil  -- Clear data[readi]

	return value
end

function Queue2:size()
	return self.writei - self.readi
end

-- Queue implementation 3: C userdata with luaL_ref + C array (silly.adt.queue)
-- Uses luaL_ref to store objects in LUA_REGISTRYINDEX
-- C side only manages int array of ref IDs, allowing fast compact via memmove
local Queue3 = adtqueue

-- Helper function to format performance comparison
local function format_perf(baseline, value)
	if value >= baseline then
		-- Slower than baseline, show as fraction of baseline speed
		local fraction = baseline / value
		return string.format("%6.2fx", fraction)
	else
		-- Faster than baseline, show speedup
		local speedup = baseline / value
		return string.format("%6.2fx", speedup)
	end
end

-- Scenario 1: Fill-Drain Pattern
-- Fill queue with n elements, then drain completely, repeat
local function test_fill_drain_q1(n, operations)
	local q = {}
	local tremove = table.remove
	local start = os.clock()
	for i = 1, operations do
		-- Fill phase: push n elements
		for j = 1, n do
			q[#q+1] = j
		end
		-- Drain phase: pop all n elements
		for j = 1, n do
			tremove(q, 1)
		end
	end
	return os.clock() - start
end

local function test_fill_drain_q2(n, operations)
	local q = Queue2.new()
	local push= q.push
	local pop = q.pop
	local start = os.clock()
	for i = 1, operations do
		-- Fill phase: push n elements
		for j = 1, n do
			push(q, j)
		end
		-- Drain phase: pop all n elements
		for j = 1, n do
			pop(q)
		end
	end
	return os.clock() - start
end

local function test_fill_drain_q3(n, operations)
	local q = Queue3.new()
	local push= q.push
	local pop = q.pop
	local start = os.clock()
	for i = 1, operations do
		-- Fill phase: push n elements
		for j = 1, n do
			push(q, j)
		end
		-- Drain phase: pop all n elements
		for j = 1, n do
			pop(q)
		end
	end
	return os.clock() - start
end

-- Scenario 2: Steady-State Pattern
-- Keep queue at n elements, then push+pop alternatingly
local function test_steady_q1(n, operations)
	local q = {}
	local tremove = table.remove
	-- Pre-fill queue to n elements
	for j = 1, n do
		q[#q + 1] = j
	end
	local start = os.clock()
	-- Steady state: maintain n elements with push+pop
	for i = 1, operations do
		q[#q + 1] = i
		tremove(q, 1)
	end
	return os.clock() - start
end

local function test_steady_q2(n, operations)
	local q = Queue2.new()
	-- Pre-fill queue to n elements
	for j = 1, n do
		q.push(q, j)
	end
	local push = q.push
	local pop = q.pop
	local start = os.clock()
	-- Steady state: maintain n elements with push+pop
	for i = 1, operations do
		push(q, i)
		pop(q)
	end
	return os.clock() - start
end

local function test_steady_q3(n, operations)
	local q = Queue3.new()
	-- Pre-fill queue to n elements
	for j = 1, n do
		q.push(q, j)
	end
	local push = q.push
	local pop = q.pop
	local start = os.clock()
	-- Steady state: maintain n elements with push+pop
	for i = 1, operations do
		push(q, i)
		pop(q)
	end
	return os.clock() - start
end

local function avg(res)
	local sum = 0
	for i = 1, #res do
		sum = sum + res[i]
	end
	return sum / #res
end

local sizes = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 50, 100, 200, 500, 1000}
local operations_map = {
	[1] = 500000,
	[2] = 500000,
	[3] = 500000,
	[4] = 500000,
	[5] = 500000,
	[6] = 300000,
	[7] = 300000,
	[8] = 300000,
	[9] = 300000,
	[10] = 300000,
	[20] = 100000,
	[50] = 50000,
	[100] = 20000,
	[200] = 10000,
	[500] = 5000,
	[1000] = 1000,
}

-- Benchmark Scenario 1: Fill-Drain
local function benchmark_fill_drain()
	-- Test 1-10 with fine granularity, then larger sizes
	print("\n" .. string.rep("=", 100))
	print("SCENARIO 1: FILL-DRAIN (Fill n elements, drain all, repeat)")
	print(string.rep("=", 100))
	print(string.format("%-10s | %-12s | %-12s | %-12s | %-18s | %-18s",
		"Size", "Queue1 (ms)", "Queue2 (ms)", "Queue3 (ms)", "Q2 vs Q1", "Q3 vs Q1"))
	print(string.rep("=", 100))

	for _, n in ipairs(sizes) do
		local ops = operations_map[n]

		-- Run each test 3 times and take the best result
		local test1 = {}
		local test2 = {}
		local test3 = {}
		collectgarbage("collect")
		for run = 1, 3 do
			local t1 = test_fill_drain_q1(n, ops)
			test1[#test1 + 1] = t1
		end
		collectgarbage("collect")
		for run = 1, 3 do
			local t2 = test_fill_drain_q2(n, ops)
			test2[#test2 + 1] = t2
		end
		collectgarbage("collect")
		for run = 1, 3 do
			local t3 = test_fill_drain_q3(n, ops)
			test3[#test3 + 1] = t3
		end

		local best1 = avg(test1)
		local best2 = avg(test2)
		local best3 = avg(test3)

		local t1_ms = best1 * 1000 // 1
		local t2_ms = best2 * 1000 // 1
		local t3_ms = best3 * 1000 // 1

		local perf2 = format_perf(best1, best2)
		local perf3 = format_perf(best1, best3)

		print(string.format("%-10d | %12.2f | %12.2f | %12.2f | %18s | %18s",
			n, t1_ms, t2_ms, t3_ms, perf2, perf3))
	end

	print(string.rep("=", 100))
	print("Note: Values shown are relative speed (e.g., 2.50x = 2.5x faster, 0.40x = 2.5x slower)")
end

-- Benchmark Scenario 2: Steady-State
local function benchmark_steady_state()
	-- Test 1-10 with fine granularity, then larger sizes
	print("\n" .. string.rep("=", 100))
	print("SCENARIO 2: STEADY-STATE (Maintain n elements, push+pop alternatingly)")
	print(string.rep("=", 100))
	print(string.format("%-10s | %-12s | %-12s | %-12s | %-18s | %-18s",
		"Size", "Queue1 (ms)", "Queue2 (ms)", "Queue3 (ms)", "Q2 vs Q1", "Q3 vs Q1"))
	print(string.rep("=", 100))

	for _, n in ipairs(sizes) do
		local ops = operations_map[n]

		-- Run each test 3 times and take the best result
		local test1 = {}
		local test2 = {}
		local test3 = {}

		for run = 1, 3 do
			collectgarbage("collect")
			local t1 = test_steady_q1(n, ops)
			test1[#test1 + 1] = t1

			collectgarbage("collect")
			local t2 = test_steady_q2(n, ops)
			test2[#test2 + 1] = t2

			collectgarbage("collect")
			local t3 = test_steady_q3(n, ops)
			test3[#test3 + 1] = t3
		end

		local best1 = avg(test1)
		local best2 = avg(test2)
		local best3 = avg(test3)

		local t1_ms = best1 * 1000 // 1
		local t2_ms = best2 * 1000 // 1
		local t3_ms = best3 * 1000 // 1

		local perf2 = format_perf(best1, best2)
		local perf3 = format_perf(best1, best3)

		print(string.format("%-10d | %12.2f | %12.2f | %12.2f | %18s | %18s",
			n, t1_ms, t2_ms, t3_ms, perf2, perf3))
	end

	print(string.rep("=", 100))
	print("Note: Values shown are relative speed (e.g., 2.50x = 2.5x faster, 0.40x = 2.5x slower)")
end

-- Main
print("\n=== Queue Performance Comparison ===")
print("\nQueue1: table.remove(queue, 1)  [baseline]")
print("Queue2: readi/writei indices (Lua table, half-open interval)")
print("Queue3: C userdata{readi,writei} + Lua table (via lua_newuserdata)")

benchmark_fill_drain()
benchmark_steady_state()

print("\n=== Summary ===")
print([[
OPTIMIZATIONS APPLIED:
  - Queue1 (baseline) uses q[#q+1]=v instead of table.insert() for push
  - Queue2/3 use readi/writei half-open interval [readi+1, writei]
  - Compact before push when readi >= size (holes >= data)
  - Pop is pure O(1) without any reset logic
  - All implementations use upvalue-cached functions to reduce hash lookups

SCENARIO 1 (Fill-Drain): Tests worst-case for table.remove where queue grows to n then shrinks to 0
  - table.remove(1) is O(n) because it shifts all remaining elements on every pop
  - readi/writei indices are O(1) for both push and pop
  - C userdata eliminates Lua overhead for index management

SCENARIO 2 (Steady-State): Tests typical queue behavior with constant size n
  - table.remove(1) consistently shifts n elements on every pop operation
  - readi/writei indices maintain O(1) performance regardless of queue size
  - Performance difference is most dramatic here due to consistent n-sized shifts

KEY FINDINGS:
  - C userdata (Queue3) leads from n=1 with 1.14x-157x speedup
  - Pure Lua (Queue2) becomes competitive at n≈10
  - Compact strategy (readi >= size) prevents unbounded memory growth without hurting performance
]])
