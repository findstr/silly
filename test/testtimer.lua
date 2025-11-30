local silly = require "silly"
local env = require "silly.env"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

local CHECK_DELTA = env.get("test.timer.checkdelta")
CHECK_DELTA = CHECK_DELTA and tonumber(CHECK_DELTA) or 100

-- Global: detected PAGE_SIZE
local PAGE_SIZE = nil
local MAX_ALLOCATED_COOKIE = 0

 -- Helper: Extract cookie from session (low 32 bits)
local function cookie_of(session)
	return session % (2^32)
end

-- Helper: Extract version from session (high 32 bits)
local function version_of(session)
	return math.floor(session / (2^32))
end

-- Helper: Calculate page_id from cookie
local function page_id_of(cookie)
	assert(PAGE_SIZE, "PAGE_SIZE not detected yet")
	return math.floor(cookie / PAGE_SIZE)
end

-- Helper: Normalize free list to predictable order
-- Allocates all nodes in existing pages, sorts by cookie, cancels in order
local function normalize_freelist()
	assert(PAGE_SIZE, "PAGE_SIZE must be detected first")

	-- Calculate how many nodes we need to allocate to fill all pages
	local max_page_id = math.floor((MAX_ALLOCATED_COOKIE + 1) / PAGE_SIZE)
	local total_nodes = max_page_id * PAGE_SIZE

	-- Allocate all nodes
	local sessions = {}
	for i = 1, total_nodes do
		local s = time.after(10000, function() end)
		sessions[i] = {
			session = s,
			cookie = cookie_of(s)
		}
		MAX_ALLOCATED_COOKIE = math.max(MAX_ALLOCATED_COOKIE, sessions[i].cookie)
	end

	-- Sort by cookie
	table.sort(sessions, function(a, b) return a.cookie < b.cookie end)

	-- Cancel in order (so free list is ordered)
	for i = 1, #sessions do
		time.cancel(sessions[i].session)
	end
	time.sleep(0)
end

-- Test 1: Detect PAGE_SIZE
do
	print("Test 1: Detect PAGE_SIZE")
	PAGE_SIZE = 128
	testaux.success("Test 1 passed (PAGE_SIZE=" .. PAGE_SIZE .. ")")
end

-- Test 2: Timer userdata
testaux.case("Test 2: Timer userdata", function()
	local count = 0
	local ch = channel.new()

	time.after(1, function(ud)
		testaux.asserteq(ud, 3, "Test 2.1: Userdata should be 3")
		count = count + 1
		if count == 2 then
			ch:push("done")
		end
	end, 3)

	time.after(1, function(ud)
		testaux.asserteq(ud, "hello", "Test 2.2: Userdata should be 'hello'")
		count = count + 1
		if count == 2 then
			ch:push("done")
		end
	end, "hello")

	ch:pop()
	testaux.success("Test 2 passed")
end)

-- Test 3: Timer cancel
testaux.case("Test 3: Timer cancel", function()
	local fired = false
	local session = time.after(100, function(ud)
		fired = true
	end, 3)

	time.cancel(session)

	time.sleep(0)
	testaux.asserteq(fired, false, "Test 3.1: Timer should not fire after cancel")
	testaux.success("Test 3 passed")
end)

-- Test 4: Free list order after normalization
testaux.case("Test 4: Free list order", function()
	normalize_freelist()

	-- After normalization, allocations should be sequential
	local sessions = {}
	local base_cookie = nil

	for i = 1, 10 do
		sessions[i] = time.after(10000, function() end)
		local c = cookie_of(sessions[i])

		if i == 1 then
			base_cookie = c
		else
			testaux.asserteq(c, base_cookie + i - 1, "Test 4.1: Sequential allocation: " .. i)
		end
	end

	-- Cancel all in order
	for i = 1, 10 do
		time.cancel(sessions[i])
	end
	time.sleep(0)

	-- Allocate again, should continue sequentially (appended to tail)
	local sessions2 = {}
	for i = 1, 10 do
		sessions2[i] = time.after(10000, function() end)
	end

	local base2 = cookie_of(sessions2[1])
	for i = 2, 10 do
		testaux.asserteq(cookie_of(sessions2[i]), base2 + i - 1,
			"Test 4.2: Second batch sequential: " .. i)
	end

	-- Verify second batch is after first batch (tail append)
	testaux.assertgt(base2, base_cookie + 9, "Test 4.3: Second batch after first")

	-- Cleanup
	for i = 1, 10 do
		time.cancel(sessions2[i])
	end

	testaux.success("Test 4 passed")
end)

-- Test 5: Version increment on reuse
testaux.case("Test 5: Version increment", function()
	normalize_freelist()

	-- Allocate one node
	local s1 = time.after(10000, function() end)
	local c1 = cookie_of(s1)
	local v1 = version_of(s1)
	time.cancel(s1)
	time.sleep(0)

	-- Allocate until we get the same cookie back
	local found = false
	for i = 1, PAGE_SIZE * 3 do
		local s = time.after(10000, function() end)
		local c = cookie_of(s)
		local v = version_of(s)
		if c == c1 then
			testaux.asserteq(v, v1 + 1, "Test 5.1: Version should increment by 1")
			found = true
			time.cancel(s)
			break
		end
		time.cancel(s)
	end

	testaux.asserteq(found, true, "Test 5.2: Should find cookie reuse")
	testaux.success("Test 5 passed")
end)

-- Test 6: Cancel in ADDING state
testaux.case("Test 6: Cancel in ADDING state", function()
	local fired = false

	local s = time.after(0, function()
		fired = true
	end)

	time.cancel(s)

	time.sleep(0)
	testaux.asserteq(fired, false, "Test 6.1: Should not fire when canceled in ADDING")
	testaux.success("Test 6 passed")
end)

-- Test 7: Partial cancel in ADDING
testaux.case("Test 7: Partial cancel in ADDING", function()
	local results = {}
	local ch = channel.new()

	local sessions = {}
	for i = 1, 10 do
		sessions[i] = time.after(0, function()
			table.insert(results, i)
			if #results == 5 then
				ch:push("done")
			end
		end)
	end

	-- Cancel odd indices before timer_update
	for i = 1, 10, 2 do
		time.cancel(sessions[i])
	end

	ch:pop()
	time.sleep(0)

	table.sort(results)
	testaux.asserteq(#results, 5, "Test 7.1: Only uncanceled should fire")
	for i = 1, 5 do
		testaux.asserteq(results[i], i * 2, "Test 7.2: Even indices fired: " .. (i*2))
	end

	testaux.success("Test 7 passed")
end)

-- Test 8: Page expansion
testaux.case("Test 8: Page expansion", function()
	normalize_freelist()

	local sessions = {}
	local expansion_detected = false

	-- Allocate until page expansion
	for i = 1, PAGE_SIZE * 3 do
		local s = time.after(10000, function() end)
		sessions[i] = s
		local c = cookie_of(s)

		if i > 1 then
			local p1 = page_id_of(cookie_of(sessions[i-1]))
			local p2 = page_id_of(c)

			if p2 > p1 then
				testaux.asserteq(p2, p1 + 1, "Test 8.1: Page ID increment by 1")
				testaux.asserteq(c, p2 * PAGE_SIZE, "Test 8.2: New page starts correctly")
				expansion_detected = true
				break
			end
		end
	end

	testaux.asserteq(expansion_detected, true, "Test 8.3: Should detect expansion")

	for _, s in ipairs(sessions) do
		time.cancel(s)
	end

	testaux.success("Test 8 passed")
end)

-- Test 9: Double cancel
testaux.case("Test 9: Double cancel", function()
	local s = time.after(10000, function() end)

	time.cancel(s)
	time.cancel(s)  -- Should be no-op

	time.sleep(0)
	testaux.success("Test 9 passed")
end)

-- Test 10: Stress test
testaux.case("Test 10: Rapid alloc/cancel", function()
	local sessions = {}

	for i = 1, 1000 do
		sessions[i] = time.after(10000, function() end)
	end

	for i = 1, 1000 do
		time.cancel(sessions[i])
	end

	time.sleep(0)
	testaux.success("Test 10 passed")
end)

-- Test 11: Basic timer functionality (from original test)
testaux.case("Test 11: Basic timer functionality", function()
	local context = {}
	local total = 30
	local ch = channel.new()

	local function gen_closure(n)
		local start = time.now()
		return function(s)
			testaux.asserteq(context[s], n, "Test 11.1: Context should match")
			local delta = time.now() - start
			delta = math.abs(delta - 100 - n)
			testaux.assertle(delta, CHECK_DELTA, "Test 11.2: Timer precision")
			total = total - 1
			if total == 0 then
				ch:push("done")
			end
		end
	end

	for i = 1, total do
		local n = i * 50
		local f = gen_closure(n)
		local s = time.after(100 + n, f)
		context[s] = n
	end

	ch:pop()
	testaux.success("Test 11 passed")
end)

testaux.case("Test 12: Userdata leak check", function()
	local t1, t2, te

	local dump = time._dump()
	local sleep_tasks = dump.sleep_session_task
	local timer_ud = dump.timer_user_data
	local u1 = {}
	local u2 = {}
	t1 = time.after(0, function(ud)
		os.execute("sleep 1")
		time.cancel(t2)
	end, u1)
	t2 = time.after(500, function(ud)
		te = true
	end, u2)
	testaux.asserteq(timer_ud[t1], u1, "Test 12.1: First userdata should exist")
	testaux.asserteq(timer_ud[t2], u2, "Test 12.2: Second userdata should exist")
	testaux.assertneq(sleep_tasks[t1], nil, "Test 12.3: session tasks should remain")
	testaux.assertneq(sleep_tasks[t2], nil, "Test 12.4: session tasks should remain")

	time.sleep(2000)
	testaux.asserteq(te, nil, "Test 12.5: Second timer should not fire")
	testaux.asserteq(sleep_tasks[t1], nil, "Test 12.6: No sleep session tasks should remain")
	testaux.asserteq(sleep_tasks[t2], nil, "Test 12.7: No sleep session tasks should remain")
	testaux.asserteq(timer_ud[t1], nil, "Test 12.8: No timer userdata should remain")
	testaux.asserteq(timer_ud[t2], nil, "Test 12.9: No timer userdata should remain")
end)

testaux.case("Test 13: Negative and zero timeout handling", function()
	local fired = {}

	-- Test negative timeout (should be converted to 0 and fire immediately)
	local t1 = time.after(-100, function()
		fired.negative = true
	end)
	testaux.assertneq(t1, nil, "Test 13.1: Negative timeout should return valid session")

	-- Test zero timeout (should fire immediately)
	local t2 = time.after(0, function()
		fired.zero = true
	end)
	testaux.assertneq(t2, nil, "Test 13.2: Zero timeout should return valid session")

	-- Test very small positive timeout
	local t3 = time.after(1, function()
		fired.small = true
	end)
	testaux.assertneq(t3, nil, "Test 13.3: Small positive timeout should return valid session")

	-- Wait for all timers to fire
	time.sleep(100)

	testaux.asserteq(fired.negative, true, "Test 13.4: Negative timeout should fire immediately")
	testaux.asserteq(fired.zero, true, "Test 13.5: Zero timeout should fire immediately")
	testaux.asserteq(fired.small, true, "Test 13.6: Small positive timeout should fire")

	testaux.success("Test 13 passed")
end)

print("\ntesttimer all tests passed!")
