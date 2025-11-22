local silly = require "silly"
local testaux = require "test.testaux"
local labels = require "silly.metrics.labels"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"
local histogram = require "silly.metrics.histogram"
local registry = require "silly.metrics.registry"

testaux.module("prometheus")

-- Test 1: labels.key with multiple labels - reproduce the bug
-- Bug: original code used index `i` instead of `values[i]` as cache key
-- This caused different first label values to return the same key
testaux.case("Test 1: labels.key multi-label caching", function()
	local lcache = {}
	local lnames = {"method", "status"}

	-- Test 1.1: First label combination
	local key1 = labels.key(lcache, lnames, {"GET", "200"})
	testaux.asserteq(key1, 'method="GET",status="200"', "Test 1.1: First key should be correct")

	-- Test 1.2: Same combination should return cached value
	local key1_cached = labels.key(lcache, lnames, {"GET", "200"})
	testaux.asserteq(key1_cached, key1, "Test 1.2: Cached key should match")

	-- Test 1.3: Different first label should produce different key
	-- This is the bug: old code used lcache[1] for all first labels
	local key2 = labels.key(lcache, lnames, {"POST", "200"})
	testaux.asserteq(key2, 'method="POST",status="200"', "Test 1.3: Different first label should produce different key")
	testaux.assertneq(key1, key2, "Test 1.4: Keys with different first labels must differ")

	-- Test 1.5: Different second label
	local key3 = labels.key(lcache, lnames, {"GET", "404"})
	testaux.asserteq(key3, 'method="GET",status="404"', "Test 1.5: Different second label should work")
	testaux.assertneq(key1, key3, "Test 1.6: Keys with different second labels must differ")

	-- Test 1.7: Three labels
	local lcache3 = {}
	local lnames3 = {"method", "status", "path"}
	local key3a = labels.key(lcache3, lnames3, {"GET", "200", "/api"})
	local key3b = labels.key(lcache3, lnames3, {"POST", "200", "/api"})
	local key3c = labels.key(lcache3, lnames3, {"GET", "404", "/api"})
	local key3d = labels.key(lcache3, lnames3, {"GET", "200", "/home"})

	testaux.asserteq(key3a, 'method="GET",status="200",path="/api"', "Test 1.7: Three label key correct")
	testaux.assertneq(key3a, key3b, "Test 1.8: Different first of three labels")
	testaux.assertneq(key3a, key3c, "Test 1.9: Different second of three labels")
	testaux.assertneq(key3a, key3d, "Test 1.10: Different third of three labels")
end)

-- Test 2: labels.key with single label
testaux.case("Test 2: labels.key single label", function()
	local lcache = {}
	local lnames = {"method"}

	local key1 = labels.key(lcache, lnames, {"GET"})
	testaux.asserteq(key1, 'method="GET"', "Test 2.1: Single label key correct")

	local key2 = labels.key(lcache, lnames, {"POST"})
	testaux.asserteq(key2, 'method="POST"', "Test 2.2: Different single label")
	testaux.assertneq(key1, key2, "Test 2.3: Different single labels must differ")

	-- Test caching
	local key1_cached = labels.key(lcache, lnames, {"GET"})
	testaux.asserteq(key1_cached, key1, "Test 2.4: Single label caching works")
end)

-- Test 3: labels.key with no labels
testaux.case("Test 3: labels.key no labels", function()
	local lcache = {}
	local lnames = {}

	local key = labels.key(lcache, lnames, {})
	testaux.asserteq(key, "", "Test 3.1: No labels should return empty string")
end)

-- Test 4: Counter without labels
testaux.case("Test 4: Counter without labels", function()
	local c = counter("test_counter", "A test counter")

	testaux.asserteq(c.value, 0, "Test 4.1: Initial value should be 0")
	testaux.asserteq(c.name, "test_counter", "Test 4.2: Name should match")
	testaux.asserteq(c.help, "A test counter", "Test 4.3: Help should match")
	testaux.asserteq(c.kind, "counter", "Test 4.4: Kind should be counter")

	c:inc()
	testaux.asserteq(c.value, 1, "Test 4.5: inc() should increment by 1")

	c:inc()
	c:inc()
	testaux.asserteq(c.value, 3, "Test 4.6: Multiple inc() calls")

	c:add(5)
	testaux.asserteq(c.value, 8, "Test 4.7: add(5) should add 5")

	c:add(0)
	testaux.asserteq(c.value, 8, "Test 4.8: add(0) should not change value")
end)

-- Test 5: Counter with labels
testaux.case("Test 5: Counter with labels", function()
	local c = counter("test_counter_labels", "A counter with labels", {"method", "status"})

	testaux.asserteq(c.name, "test_counter_labels", "Test 5.1: Name should match")
	testaux.asserteq(c.metrics ~= nil, true, "Test 5.2: Should have metrics table")

	-- Test different label combinations
	local c_get_200 = c:labels("GET", "200")
	c_get_200:inc()
	testaux.asserteq(c_get_200.value, 1, "Test 5.3: GET/200 counter should be 1")

	local c_post_200 = c:labels("POST", "200")
	c_post_200:inc()
	c_post_200:inc()
	testaux.asserteq(c_post_200.value, 2, "Test 5.4: POST/200 counter should be 2")

	-- Verify GET/200 unchanged
	testaux.asserteq(c_get_200.value, 1, "Test 5.5: GET/200 should still be 1")

	-- Same labels should return same instance
	local c_get_200_again = c:labels("GET", "200")
	testaux.asserteq(c_get_200_again.value, 1, "Test 5.6: Same labels should return cached instance")

	c_get_200_again:inc()
	testaux.asserteq(c_get_200.value, 2, "Test 5.7: Cached instance should share state")
end)

-- Test 6: Gauge without labels
testaux.case("Test 6: Gauge without labels", function()
	local g = gauge("test_gauge", "A test gauge")

	testaux.asserteq(g.value, 0, "Test 6.1: Initial value should be 0")
	testaux.asserteq(g.kind, "gauge", "Test 6.2: Kind should be gauge")

	g:set(10)
	testaux.asserteq(g.value, 10, "Test 6.3: set(10) should set to 10")

	g:set(5)
	testaux.asserteq(g.value, 5, "Test 6.4: set(5) should overwrite to 5")

	g:inc()
	testaux.asserteq(g.value, 6, "Test 6.5: inc() should increment by 1")

	g:dec()
	testaux.asserteq(g.value, 5, "Test 6.6: dec() should decrement by 1")

	g:sub(3)
	testaux.asserteq(g.value, 2, "Test 6.7: sub(3) should subtract 3")
end)

-- Test 7: Gauge with labels
testaux.case("Test 7: Gauge with labels", function()
	local g = gauge("test_gauge_labels", "A gauge with labels", {"host"})

	local g_host1 = g:labels("server1")
	g_host1:set(100)
	testaux.asserteq(g_host1.value, 100, "Test 7.1: server1 gauge should be 100")

	local g_host2 = g:labels("server2")
	g_host2:set(200)
	testaux.asserteq(g_host2.value, 200, "Test 7.2: server2 gauge should be 200")

	-- Verify isolation
	testaux.asserteq(g_host1.value, 100, "Test 7.3: server1 should still be 100")
end)

-- Test 8: Histogram without labels
testaux.case("Test 8: Histogram without labels", function()
	local h = histogram("test_histogram", "A test histogram", nil, {1, 5, 10})

	testaux.asserteq(h.sum, 0, "Test 8.1: Initial sum should be 0")
	testaux.asserteq(h.count, 0, "Test 8.2: Initial count should be 0")
	testaux.asserteq(h.kind, "histogram", "Test 8.3: Kind should be histogram")

	h:observe(0.5)
	testaux.asserteq(h.sum, 0.5, "Test 8.4: Sum should be 0.5")
	testaux.asserteq(h.count, 1, "Test 8.5: Count should be 1")
	testaux.asserteq(h.bucketcounts[1], 1, "Test 8.6: Bucket <=1 should have 1")
	testaux.asserteq(h.bucketcounts[2], 0, "Test 8.7: Bucket <=5 should have 0")
	testaux.asserteq(h.bucketcounts[3], 0, "Test 8.8: Bucket <=10 should have 0")

	h:observe(3)
	testaux.asserteq(h.sum, 3.5, "Test 8.9: Sum should be 3.5")
	testaux.asserteq(h.count, 2, "Test 8.10: Count should be 2")
	testaux.asserteq(h.bucketcounts[1], 1, "Test 8.11: Bucket <=1 still 1")
	testaux.asserteq(h.bucketcounts[2], 1, "Test 8.12: Bucket <=5 should have 1")

	h:observe(7)
	testaux.asserteq(h.bucketcounts[3], 1, "Test 8.13: Bucket <=10 should have 1")

	-- Value above all buckets
	h:observe(15)
	testaux.asserteq(h.count, 4, "Test 8.14: Count should be 4")
	testaux.asserteq(h.bucketcounts[1], 1, "Test 8.15: Bucket <=1 unchanged")
	testaux.asserteq(h.bucketcounts[2], 1, "Test 8.16: Bucket <=5 unchanged")
	testaux.asserteq(h.bucketcounts[3], 1, "Test 8.17: Bucket <=10 unchanged")
end)

-- Test 9: Histogram with labels
testaux.case("Test 9: Histogram with labels", function()
	local h = histogram("test_histogram_labels", "A histogram with labels", {"endpoint"}, {1, 5, 10})

	local h_api = h:labels("/api")
	h_api:observe(0.5)
	h_api:observe(3)
	testaux.asserteq(h_api.count, 2, "Test 9.1: /api histogram count should be 2")
	testaux.asserteq(h_api.sum, 3.5, "Test 9.2: /api histogram sum should be 3.5")

	local h_home = h:labels("/home")
	h_home:observe(7)
	testaux.asserteq(h_home.count, 1, "Test 9.3: /home histogram count should be 1")

	-- Verify isolation
	testaux.asserteq(h_api.count, 2, "Test 9.4: /api count should still be 2")
end)

-- Test 10: Multi-label stress test for caching bug
testaux.case("Test 10: Multi-label counter stress test", function()
	local c = counter("stress_counter", "Stress test counter", {"a", "b", "c"})

	-- Create many different label combinations
	local combinations = {
		{"x", "y", "z"},
		{"x", "y", "w"},
		{"x", "m", "z"},
		{"p", "y", "z"},
		{"p", "q", "r"},
	}

	for i, combo in ipairs(combinations) do
		local sub = c:labels(combo[1], combo[2], combo[3])
		sub:add(i)
	end

	-- Verify each combination has correct value
	for i, combo in ipairs(combinations) do
		local sub = c:labels(combo[1], combo[2], combo[3])
		testaux.asserteq(sub.value, i, string.format("Test 10.%d: Combination %d should have value %d", i, i, i))
	end

	-- Verify metrics table has correct number of entries
	local count = 0
	for _ in pairs(c.metrics) do
		count = count + 1
	end
	testaux.asserteq(count, 5, "Test 10.6: Should have 5 distinct metric entries")
end)

-- Test 11: Counter add() with negative value should fail
testaux.case("Test 11: Counter add negative value", function()
	local c = counter("test_counter_negative", "Counter negative test")
	c:inc()
	testaux.asserteq(c.value, 1, "Test 11.1: Initial inc works")

	-- add() with negative value should throw error
	testaux.assert_error(function()
		c:add(-1)
	end, "Test 11.2: add(-1) should throw error")

	-- Value should remain unchanged after failed add
	testaux.asserteq(c.value, 1, "Test 11.3: Value unchanged after failed add")
end)

-- Test 12: Gauge add(v) should add v (not just 1)
testaux.case("Test 12: Gauge add with value", function()
	local g = gauge("test_gauge_add", "Gauge add test")
	g:set(10)
	testaux.asserteq(g.value, 10, "Test 12.1: Initial value 10")

	g:add(5)
	-- Note: This test will fail if gauge.add() has bug (adds 1 instead of v)
	testaux.asserteq(g.value, 15, "Test 12.2: add(5) should result in 15")

	g:add(3)
	testaux.asserteq(g.value, 18, "Test 12.3: add(3) should result in 18")
end)

-- Test 13: Histogram bucket boundary values
testaux.case("Test 13: Histogram bucket boundaries", function()
	local h = histogram("test_histogram_boundary", "Boundary test", nil, {1, 5, 10})

	-- Value exactly at bucket boundary should go into that bucket
	h:observe(1)  -- Exactly at first bucket boundary
	testaux.asserteq(h.bucketcounts[1], 1, "Test 13.1: Value 1 goes to bucket <=1")
	testaux.asserteq(h.bucketcounts[2], 0, "Test 13.2: Bucket <=5 is 0")

	h:observe(5)  -- Exactly at second bucket boundary
	testaux.asserteq(h.bucketcounts[1], 1, "Test 13.3: Bucket <=1 unchanged")
	testaux.asserteq(h.bucketcounts[2], 1, "Test 13.4: Value 5 goes to bucket <=5")

	h:observe(10)  -- Exactly at third bucket boundary
	testaux.asserteq(h.bucketcounts[3], 1, "Test 13.5: Value 10 goes to bucket <=10")

	-- Sum and count
	testaux.asserteq(h.sum, 16, "Test 13.6: Sum should be 16")
	testaux.asserteq(h.count, 3, "Test 13.7: Count should be 3")
end)

-- Test 14: Histogram with default buckets
testaux.case("Test 14: Histogram default buckets", function()
	local h = histogram("test_histogram_default", "Default buckets test")

	-- Default buckets: {0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}
	testaux.asserteq(#h.buckets, 14, "Test 14.1: Should have 14 default buckets")
	testaux.asserteq(h.buckets[1], 0.005, "Test 14.2: First bucket is 0.005")
	testaux.asserteq(h.buckets[14], 10.0, "Test 14.3: Last bucket is 10.0")

	h:observe(0.001)
	testaux.asserteq(h.bucketcounts[1], 1, "Test 14.4: 0.001 goes to first bucket")

	h:observe(1.5)
	testaux.asserteq(h.bucketcounts[11], 1, "Test 14.5: 1.5 goes to bucket <=2.5")
end)

-- Test 15: Registry register/unregister/collect
testaux.case("Test 15: Registry operations", function()
	local r = registry.new()

	local c1 = counter("reg_counter1", "Counter 1")
	local c2 = counter("reg_counter2", "Counter 2")

	-- Register
	r:register(c1)
	r:register(c2)
	testaux.asserteq(#r, 2, "Test 15.1: Registry should have 2 collectors")

	-- Duplicate register should not add
	r:register(c1)
	testaux.asserteq(#r, 2, "Test 15.2: Duplicate register should not add")

	-- Collect
	local metrics = r:collect()
	testaux.asserteq(#metrics, 2, "Test 15.3: Collect should return 2 metrics")

	-- Unregister
	r:unregister(c1)
	testaux.asserteq(#r, 1, "Test 15.4: After unregister should have 1")

	metrics = r:collect()
	testaux.asserteq(#metrics, 1, "Test 15.5: Collect after unregister returns 1")

	-- Unregister non-existent should be no-op
	r:unregister(c1)
	testaux.asserteq(#r, 1, "Test 15.6: Unregister non-existent is no-op")
end)

-- Test 16: Histogram bucket sorting
testaux.case("Test 16: Histogram bucket sorting", function()
	-- Provide unsorted buckets
	local h = histogram("test_histogram_sort", "Sort test", nil, {10, 1, 5})

	-- Buckets should be sorted
	testaux.asserteq(h.buckets[1], 1, "Test 16.1: First bucket is 1")
	testaux.asserteq(h.buckets[2], 5, "Test 16.2: Second bucket is 5")
	testaux.asserteq(h.buckets[3], 10, "Test 16.3: Third bucket is 10")
end)

-- Test 17: Counter and Gauge collect method
testaux.case("Test 17: Collector collect method", function()
	local c = counter("collect_counter", "Collect test")
	local buf = {}
	c:collect(buf)
	testaux.asserteq(#buf, 1, "Test 17.1: Counter collect adds to buffer")
	testaux.asserteq(buf[1], c, "Test 17.2: Buffer contains the counter")

	local g = gauge("collect_gauge", "Gauge collect test")
	g:collect(buf)
	testaux.asserteq(#buf, 2, "Test 17.3: Gauge collect adds to buffer")
	testaux.asserteq(buf[2], g, "Test 17.4: Buffer contains the gauge")

	local h = histogram("collect_histogram", "Histogram collect test")
	h:collect(buf)
	testaux.asserteq(#buf, 3, "Test 17.5: Histogram collect adds to buffer")
end)

-- Test 18: Labels with special characters
testaux.case("Test 18: Labels with special values", function()
	local lcache = {}
	local lnames = {"path", "method"}

	-- Numbers as label values
	local key1 = labels.key(lcache, lnames, {"/api/v1", "GET"})
	testaux.asserteq(key1, 'path="/api/v1",method="GET"', "Test 18.1: Path with slash")

	-- Empty string as label value
	local key2 = labels.key(lcache, lnames, {"", "POST"})
	testaux.asserteq(key2, 'path="",method="POST"', "Test 18.2: Empty string label")

	-- Numeric label value (converted to string)
	local lcache2 = {}
	local lnames2 = {"code"}
	local key3 = labels.key(lcache2, lnames2, {200})
	testaux.asserteq(key3, 'code="200"', "Test 18.3: Numeric label value")
end)

-- Test 19: Process collector robustness (Reproduction)
testaux.case("Test 19: Process collector robustness", function()
	-- Mock silly.metrics.c
	local mock_c = {
		cpustat_sys = 10,
		cpustat_usr = 10,
		memstat_rss = 1000,
		memstat_heap = 500,
	}

	function mock_c.cpustat()
		return mock_c.cpustat_sys, mock_c.cpustat_usr
	end

	function mock_c.memstat()
		return mock_c.memstat_rss, mock_c.memstat_heap
	end

	-- Save original and inject mock
	local original_c = package.loaded["silly.metrics.c"]
	package.loaded["silly.metrics.c"] = mock_c

	-- Reload process collector to use mock
	package.loaded["silly.metrics.collector.process"] = nil
	local process_collector = require "silly.metrics.collector.process"

	local p = process_collector.new()
	local buf = {}

	-- First collect: Initial values
	p:collect(buf)
	-- Verify internal counters are set (we can't easily access locals, but we can check if it didn't crash)

	-- Scenario: CPU usage decreases (e.g. precision issue or wrap)
	mock_c.cpustat_usr = 9 -- Was 10, now 9. Delta is -1.

	-- This should NOT crash anymore
	local status, err = pcall(function()
		p:collect(buf)
	end)

	-- Restore original c module
	package.loaded["silly.metrics.c"] = original_c
	package.loaded["silly.metrics.collector.process"] = nil -- Reset for other tests if any

	testaux.asserteq(status, true, "Test 19.1: Should NOT crash when CPU usage decreases")
end)

-- Test 20: Prometheus output format verification (Regression test for trailing comma bug)
testaux.case("Test 20: Prometheus format_count trailing comma bug", function()
	-- This test reproduces the bug fixed in commit bf65ddd905c6ab3e4b2913f61370e2c3e0d06099
	-- Bug: Old code appended ',' after label in format_count, producing {label,}

	local prometheus = require "silly.metrics.prometheus"

	-- Create isolated registry for testing
	local r = registry.new()
	local c = counter("trailing_comma_test", "Test for trailing comma bug", {"method"})
	c:labels("GET"):add(100)
	r:register(c)

	-- Gather prometheus output using the custom registry
	local output = prometheus.gather(r)

	-- Split output into lines for verification
	local lines = {}
	for line in output:gmatch("[^\n]+") do
		table.insert(lines, line)
	end

	-- Test 20.1: Check for bug pattern {label,}
	local found_bug = false
	local bug_line = nil
	for _, line in ipairs(lines) do
		if line:match('%{[^}]+,%s*%}') then
			found_bug = true
			bug_line = line
			break
		end
	end

	if found_bug then
		print("BUG DETECTED: Line with trailing comma:", bug_line)
	end
	testaux.asserteq(found_bug, false, "Test 20.1: No trailing comma pattern {label,}")

	-- Test 20.2: Verify correct format exists
	local found_metric = false
	local metric_line = nil
	for _, line in ipairs(lines) do
		if line:match('trailing_comma_test%{method="GET"%}%s+%d+') then
			found_metric = true
			metric_line = line
			break
		end
	end

	testaux.asserteq(found_metric, true, "Test 20.2: Correct format {method=\"GET\"} exists")

	if metric_line then
		-- Test 20.3: Verify the line doesn't end with comma before }
		testaux.asserteq(metric_line:match(',%s*%}'), nil, "Test 20.3: No trailing comma in metric line")
	end
end)

silly.exit(0)

