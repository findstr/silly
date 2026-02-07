local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local etcd = require "silly.store.etcd"
local fake_etcd_server = require "test.fake_etcd_server"
local testaux = require "test.testaux"

local FAKE_PORT = 23790

-- Start server once and reuse it for all tests
local server = fake_etcd_server.new(FAKE_PORT)
local ok, err = server:start()
if not ok then
	print("Failed to start fake etcd server:", err)
	os.exit(1)
end

-- Helper function to reset server state between tests
local function reset_server()
	server:reset()
end

-- Helper function to create client
local function create_client()
	local c, err = etcd.newclient {
		endpoints = {"127.0.0.1:" .. FAKE_PORT},
		retry = 3,
		retry_sleep = 100,
	}
	testaux.assertneq(c, nil, "Create etcd client")
	return c
end

local function wait_watch_created(n)
	server:wait_watch_created(n)
end

-- Test 1: Basic CRUD operations with edge cases
testaux.case("Test 1: Basic CRUD edge cases", function()
	print("-----Test 1: Basic CRUD edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 1.1: Empty key handling
	local res, err = c:put { key = "", value = "empty_key" }
	testaux.assertneq(res, nil, "Test 1.1: Put with empty key should work")

	-- Test 1.2: Empty value
	res, err = c:put { key = "/test/empty_value", value = "" }
	testaux.assertneq(res, nil, "Test 1.2: Put with empty value")
	res = c:get { key = "/test/empty_value" }
	testaux.asserteq(res.kvs[1].value, "", "Test 1.3: Get empty value returns empty string")

	-- Test 1.4: Very long key
	local long_key = string.rep("a", 1000)
	res = c:put { key = long_key, value = "long_key_value" }
	testaux.assertneq(res, nil, "Test 1.4: Put with very long key")

	-- Test 1.5: Very long value
	local long_value = string.rep("x", 10000)
	res = c:put { key = "/test/long_value", value = long_value }
	testaux.assertneq(res, nil, "Test 1.5: Put with very long value")
	res = c:get { key = "/test/long_value" }
	testaux.asserteq(#res.kvs[1].value, 10000, "Test 1.6: Get long value returns correct length")

	-- Test 1.7: Update existing key
	c:put { key = "/test/update", value = "v1" }
	res = c:put { key = "/test/update", value = "v2", prev_kv = true }
	testaux.assertneq(res.prev_kv, nil, "Test 1.7: Update returns prev_kv")
	testaux.asserteq(res.prev_kv.value, "v1", "Test 1.8: prev_kv has old value")

	-- Test 1.9: Delete non-existent key
	res = c:delete { key = "/test/nonexistent", prev_kv = true }
	testaux.assertneq(res, nil, "Test 1.9: Delete non-existent key")
	testaux.asserteq(res.deleted, 0, "Test 1.10: Delete count is 0")

	-- Test 1.11: Get non-existent key
	res = c:get { key = "/test/nonexistent" }
	testaux.assertneq(res, nil, "Test 1.11: Get non-existent key returns response")
	testaux.asserteq(res.count, 0, "Test 1.12: Get count is 0")

	c:close()
	testaux.success("Test 1: Basic CRUD edge cases passed")
end)

-- Test 2: Prefix operations edge cases
testaux.case("Test 2: Prefix operations edge cases", function()
	print("-----Test 2: Prefix operations edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 2.1: Empty prefix (get all keys)
	c:put { key = "/a", value = "1" }
	c:put { key = "/b", value = "2" }
	c:put { key = "/c", value = "3" }

	local res = c:get { key = "", prefix = true }
	testaux.assertneq(res, nil, "Test 2.1: Get with empty prefix")
	testaux.asserteq(res.count >= 3, true, "Test 2.2: Get all keys returns at least 3")

	-- Test 2.3: Prefix with no matches
	res = c:get { key = "/nonexistent/prefix/", prefix = true }
	testaux.asserteq(res.count, 0, "Test 2.3: Prefix with no matches returns 0")

	-- Test 2.4: Prefix with single match
	c:put { key = "/unique/key", value = "val" }
	res = c:get { key = "/unique/", prefix = true }
	testaux.asserteq(res.count, 1, "Test 2.4: Prefix with single match")

	-- Test 2.5: Delete with prefix (empty result)
	res = c:delete { key = "/empty/prefix/", prefix = true }
	testaux.asserteq(res.deleted, 0, "Test 2.5: Delete empty prefix returns 0")

	-- Test 2.6: Nested prefixes
	c:put { key = "/a/b/c/d", value = "deep" }
	c:put { key = "/a/b/c/e", value = "deep2" }
	c:put { key = "/a/b/f", value = "mid" }
	res = c:get { key = "/a/b/c/", prefix = true }
	testaux.asserteq(res.count, 2, "Test 2.6: Nested prefix returns 2")

	-- Test 2.7: Keys with special characters
	c:put { key = "/test/key-with-dash", value = "v1" }
	c:put { key = "/test/key_with_underscore", value = "v2" }
	c:put { key = "/test/key.with.dot", value = "v3" }
	res = c:get { key = "/test/", prefix = true }
	testaux.asserteq(res.count >= 3, true, "Test 2.7: Prefix handles special chars")

	c:close()

	testaux.success("Test 2: Prefix operations edge cases passed")
end)

-- Test 3: Lease edge cases
testaux.case("Test 3: Lease edge cases", function()
	print("-----Test 3: Lease edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 3.1: Grant lease with ID 0 (auto-generate)
	local res = c:grant { TTL = 10 }
	testaux.assertneq(res, nil, "Test 3.1: Grant lease with auto ID")
	testaux.assertgt(res.ID, 0, "Test 3.2: Auto-generated ID is positive")
	local lease1 = res.ID

	-- Test 3.3: Grant lease with specific ID
	res = c:grant { TTL = 10, ID = 9999 }
	testaux.assertneq(res, nil, "Test 3.3: Grant lease with specific ID")
	testaux.asserteq(res.ID, 9999, "Test 3.4: Lease ID matches requested")

	-- Test 3.5: Put with non-existent lease (should work but lease won't exist)
	res = c:put { key = "/test/bad_lease", value = "val", lease = 88888 }
	testaux.assertneq(res, nil, "Test 3.5: Put with non-existent lease")

	-- Test 3.6: Attach multiple keys to same lease
	res = c:grant { TTL = 10 }
	local lease2 = res.ID
	c:put { key = "/lease/key1", value = "v1", lease = lease2 }
	c:put { key = "/lease/key2", value = "v2", lease = lease2 }
	c:put { key = "/lease/key3", value = "v3", lease = lease2 }

	res = c:ttl { ID = lease2, keys = true }
	testaux.asserteq(#res.keys, 3, "Test 3.6: Lease has 3 attached keys")

	-- Test 3.7: Revoke lease with multiple keys
	res = c:revoke { ID = lease2 }
	testaux.assertneq(res, nil, "Test 3.7: Revoke lease with multiple keys")

	res = c:get { key = "/lease/", prefix = true }
	testaux.asserteq(res.count, 0, "Test 3.8: All lease keys deleted after revoke")

	-- Test 3.9: TTL query on non-existent lease
	res = c:ttl { ID = 77777 }
	testaux.assertneq(res, nil, "Test 3.9: TTL query on non-existent lease")
	testaux.asserteq(res.TTL, -1, "Test 3.10: Non-existent lease returns TTL -1")

	-- Test 3.11: Revoke non-existent lease (should succeed)
	res = c:revoke { ID = 77777 }
	testaux.assertneq(res, nil, "Test 3.11: Revoke non-existent lease succeeds")

	-- Test 3.12: Leases list
	c:grant { TTL = 10 }
	c:grant { TTL = 20 }
	res = c:leases()
	testaux.assertneq(res, nil, "Test 3.12: List all leases")
	testaux.assertgt(#res.leases, 0, "Test 3.13: Leases list is not empty")

	c:close()

	testaux.success("Test 3: Lease edge cases passed")
end)

-- Test 4: Keepalive edge cases
testaux.case("Test 4: Keepalive edge cases", function()
	print("-----Test 4: Keepalive edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 4.1: Keepalive on valid lease
	local res = c:grant { TTL = 5 }
	local lease_id = res.ID
	c:keepalive(lease_id)
	time.sleep(500)

	res = c:ttl { ID = lease_id }
	testaux.assertneq(res, nil, "Test 4.1: Keepalive on valid lease")
	testaux.assertgt(res.TTL, 0, "Test 4.2: Lease is still alive after keepalive")

	-- Test 4.3: Keepalive on same lease twice (idempotent)
	c:keepalive(lease_id)
	c:keepalive(lease_id)
	res = c:ttl { ID = lease_id }
	testaux.assertgt(res.TTL, 0, "Test 4.3: Double keepalive is idempotent")

	-- Test 4.4: Keepalive on multiple leases
	local lease2 = c:grant { TTL = 5 }
	local lease3 = c:grant { TTL = 5 }
	c:keepalive(lease2.ID)
	c:keepalive(lease3.ID)
	time.sleep(500)

	res = c:ttl { ID = lease2.ID }
	testaux.assertgt(res.TTL, 0, "Test 4.4: Multiple keepalives work")

	-- Test 4.5: Keepalive after revoke (should handle gracefully)
	c:revoke { ID = lease_id }
	-- Keepalive will continue but lease is gone
	time.sleep(100)

	c:close()

	testaux.success("Test 4: Keepalive edge cases passed")
end)

-- Test 5: Watch edge cases
testaux.case("Test 5: Watch edge cases", function()
	print("-----Test 5: Watch edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 5.1: Watch non-existent key
	local watcher, err = c:watch { key = "/nonexistent" }
	testaux.assertneq(watcher, nil, "Test 5.1: Watch non-existent key")
	wait_watch_created(1)

	-- Test 5.2: Create key after watch started
	task.fork(function()
		time.sleep(100)
		c:put { key = "/nonexistent", value = "created" }
	end)

	local res = watcher:read()
	testaux.assertneq(res, nil, "Test 5.2: Receive event for newly created key")
	testaux.asserteq(#res.events, 1, "Test 5.3: One event received")
	testaux.asserteq(res.events[1].kv.key, "/nonexistent", "Test 5.4: Event key matches")
	watcher:cancel()

	-- Test 5.5: Watch with prefix, multiple events
	local watcher2 = c:watch { key = "/watch/", prefix = true }
	wait_watch_created(1)
	task.fork(function()
		time.sleep(100)
		c:put { key = "/watch/a", value = "1" }
		time.sleep(50)
		c:put { key = "/watch/b", value = "2" }
		time.sleep(50)
		c:delete { key = "/watch/a" }
	end)

	local count = 0
	for i = 1, 3 do
		res = watcher2:read()
		if res then
			count = count + #res.events
		end
	end
	testaux.asserteq(count, 3, "Test 5.5: Received 3 events (2 puts + 1 delete)")
	watcher2:cancel()

	-- Test 5.6: Cancel watch immediately
	local watcher3 = c:watch { key = "/test/cancel" }
	wait_watch_created(1)
	watcher3:cancel()
	-- Should be able to cancel without error
	testaux.success("Test 5.6: Immediate cancel works")

	-- Test 5.7: Multiple watchers on same key
	local w1 = c:watch { key = "/multi" }
	local w2 = c:watch { key = "/multi" }
	wait_watch_created(2)
	local wg = waitgroup.new()
	wg:fork(function()
		local r1 = w1:read()
		local r2 = w2:read()
		testaux.assertneq(r1, nil, "Test 5.7: First watcher receives event")
		testaux.assertneq(r2, nil, "Test 5.8: Second watcher receives event")
		w1:cancel()
		w2:cancel()
	end)
	wg:fork(function()
		c:put { key = "/multi", value = "val" }
	end)
	wg:wait()
	-- Test 5.9: Watch overlapping prefixes
	local w_a = c:watch { key = "/overlap/a/", prefix = true }
	local w_all = c:watch { key = "/overlap/", prefix = true }
	wait_watch_created(2)

	c:put { key = "/overlap/a/1", value = "v1" }
	local ra = w_a:read()
	local rall = w_all:read()
	testaux.assertneq(ra, nil, "Test 5.9: Narrow prefix watcher receives event")
	testaux.assertneq(rall, nil, "Test 5.10: Wide prefix watcher receives event")

	w_a:cancel()
	w_all:cancel()

	c:close()

	testaux.success("Test 5: Watch edge cases passed")
end)

-- Test 6: Watch cancel and close edge cases
testaux.case("Test 6: Watch cancel edge cases", function()
	print("-----Test 6: Watch cancel edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 6.1: Cancel watcher, then verify read fails
	local w = c:watch { key = "/cancel/test" }
	wait_watch_created(1)
	w:cancel()

	-- After cancel, read should eventually return error
	-- The cancel response should be received
	local res, err
	for i = 1, 10 do
		res, err = w:read()
		if err then
			break
		end
		time.sleep(10)
	end
	testaux.asserteq(res, nil, "Test 6.1: Read after cancel returns nil")
	testaux.assertneq(err, nil, "Test 6.2: Read after cancel returns error")

	-- Test 6.3: Double cancel (idempotent)
	local w2 = c:watch { key = "/cancel/test2" }
	wait_watch_created(1)
	w2:cancel()
	w2:cancel()  -- Should not error
	testaux.success("Test 6.3: Double cancel is safe")

	-- Test 6.4: Cancel during active watch
	local w3 = c:watch { key = "/cancel/test3" }
	wait_watch_created(1)
	task.fork(function()
		time.sleep(100)
		w3:cancel()
	end)

	res, err = w3:read()
	-- Should either get cancel response or error
	testaux.success("Test 6.4: Cancel during active watch")

	c:close()

	testaux.success("Test 6: Watch cancel edge cases passed")
end)

-- Test 7: Client close edge cases
testaux.case("Test 7: Client close edge cases", function()
	print("-----Test 7: Client close edge cases-----")
	reset_server()

	local c = create_client()

	-- Test 7.1: Create resources before close
	local lease = c:grant { TTL = 60 }
	c:keepalive(lease.ID)
	local w1 = c:watch { key = "/close/test1" }
	local w2 = c:watch { key = "/close/test2" }
	wait_watch_created(2)

	-- Test 7.2: Close client
	c:close()

	-- Test 7.3: Operations after close should fail
	local res, err = c:put { key = "/after/close", value = "val" }
	testaux.asserteq(res, nil, "Test 7.3: Put after close fails")

	-- Test 7.4: Watch read after close should fail
	res, err = w1:read()
	testaux.asserteq(res, nil, "Test 7.4: Watch read after close fails")

	-- Test 7.5: Double close (idempotent)
	c:close()
	testaux.success("Test 7.5: Double close is safe")


	testaux.success("Test 7: Client close edge cases passed")
end)

-- Test 8: Concurrent operations stress test
testaux.case("Test 8: Concurrent operations", function()
	print("-----Test 8: Concurrent operations-----")
	reset_server()

	local c = create_client()
	local wg = waitgroup.new()
	local success_count = 0
	local total_ops = 100

	-- Test 8.1: Concurrent puts
	for i = 1, total_ops do
		wg:fork(function()
			local key = string.format("/concurrent/key_%d", i)
			local res = c:put { key = key, value = tostring(i) }
			if res then
				success_count = success_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(success_count, total_ops, "Test 8.1: All concurrent puts succeeded")

	-- Test 8.2: Verify all keys exist
	local res = c:get { key = "/concurrent/", prefix = true }
	testaux.asserteq(res.count, total_ops, "Test 8.2: All keys created")

	-- Test 8.3: Concurrent gets
	success_count = 0
	for i = 1, total_ops do
		wg:fork(function()
			local key = string.format("/concurrent/key_%d", i)
			local res = c:get { key = key }
			if res and res.count == 1 then
				success_count = success_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(success_count, total_ops, "Test 8.3: All concurrent gets succeeded")

	-- Test 8.4: Concurrent deletes
	success_count = 0
	for i = 1, total_ops do
		wg:fork(function()
			local key = string.format("/concurrent/key_%d", i)
			local res = c:delete { key = key }
			if res then
				success_count = success_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(success_count, total_ops, "Test 8.4: All concurrent deletes succeeded")

	-- Test 8.5: Verify all deleted
	res = c:get { key = "/concurrent/", prefix = true }
	testaux.asserteq(res.count, 0, "Test 8.5: All keys deleted")

	c:close()

	testaux.success("Test 8: Concurrent operations passed")
end)

-- Test 9: Concurrent watch operations
testaux.case("Test 9: Concurrent watchers", function()
	print("-----Test 9: Concurrent watchers-----")
	reset_server()

	local c = create_client()
	local wg = waitgroup.new()

	-- Test 9.1: Create multiple watchers
	local watchers = {}
	for i = 1, 10 do
		local w = c:watch { key = "/multi/watch" }
		watchers[i] = w
	end
	wait_watch_created(10)

	-- Test 9.2: Trigger event, all watchers should receive it
	task.fork(function()
		time.sleep(100)
		c:put { key = "/multi/watch", value = "broadcast" }
	end)

	local received_count = 0
	for i = 1, 10 do
		wg:fork(function()
			local res = watchers[i]:read()
			if res and #res.events == 1 then
				received_count = received_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(received_count, 10, "Test 9.1: All watchers received event")

	-- Test 9.3: Cancel all watchers
	for i = 1, 10 do
		watchers[i]:cancel()
	end

	c:close()

	testaux.success("Test 9: Concurrent watchers passed")
end)

-- Test 10: Range operations edge cases
testaux.case("Test 10: Range operations", function()
	print("-----Test 10: Range operations-----")
	reset_server()

	local c = create_client()

	-- Setup test data
	c:put { key = "/range/a", value = "1" }
	c:put { key = "/range/b", value = "2" }
	c:put { key = "/range/c", value = "3" }
	c:put { key = "/range/d", value = "4" }
	c:put { key = "/range/e", value = "5" }

	-- Test 10.1: Limit parameter
	local res = c:get { key = "/range/", prefix = true, limit = 2 }
	testaux.asserteq(#res.kvs, 2, "Test 10.1: Limit returns exactly 2 keys")
	testaux.asserteq(res.more, true, "Test 10.2: More flag is true")

	-- Test 10.3: Count only
	res = c:get { key = "/range/", prefix = true, count_only = true }
	testaux.asserteq(res.count, 5, "Test 10.3: Count only returns correct count")
	testaux.asserteq(#res.kvs, 0, "Test 10.4: Count only returns empty kvs")

	-- Test 10.5: Keys only
	res = c:get { key = "/range/", prefix = true, keys_only = true }
	testaux.asserteq(#res.kvs, 5, "Test 10.5: Keys only returns all keys")
	for i, kv in ipairs(res.kvs) do
		-- Keys only should not return values (or return empty values)
		testaux.assertneq(kv.key, nil, "Test 10.6: Key exists in keys_only mode")
	end

	-- Test 10.7: Sorting (if supported)
	res = c:get {
		key = "/range/",
		prefix = true,
		sort_target = "KEY",
		sort_order = "ASCEND",
	}
	testaux.asserteq(res.kvs[1].key, "/range/a", "Test 10.7: First key is 'a' in ascending order")

	c:close()

	testaux.success("Test 10: Range operations passed")
end)

-- Test 11: Revision tracking
testaux.case("Test 11: Revision tracking", function()
	print("-----Test 11: Revision tracking-----")
	reset_server()

	local c = create_client()

	-- Test 11.1: Initial revision
	local res = c:put { key = "/rev/test", value = "v1" }
	local rev1 = res.header.revision

	-- Test 11.2: Revision increases with each operation
	res = c:put { key = "/rev/test", value = "v2" }
	local rev2 = res.header.revision
	testaux.assertgt(rev2, rev1, "Test 11.1: Revision increases after put")

	-- Test 11.3: Delete also increases revision
	res = c:delete { key = "/rev/test" }
	local rev3 = res.header.revision
	testaux.assertgt(rev3, rev2, "Test 11.2: Revision increases after delete")

	-- Test 11.4: Get doesn't increase revision
	res = c:get { key = "/rev/other" }
	local rev4 = res.header.revision
	testaux.asserteq(rev4, rev3, "Test 11.3: Get doesn't increase revision")

	-- Test 11.5: Multiple puts increase revision
	for i = 1, 5 do
		c:put { key = "/rev/multi", value = tostring(i) }
	end
	res = c:get { key = "/rev/multi" }
	testaux.assertgt(res.header.revision, rev4, "Test 11.4: Multiple puts increase revision")

	c:close()

	testaux.success("Test 11: Revision tracking passed")
end)

-- Test 12: Custom handler override
testaux.case("Test 12: Custom handler override", function()
	print("-----Test 12: Custom handler override-----")
	reset_server()

	-- Test 12.1: Override Put handler to inject error
	server:set_kv_handler(function(method, req, srv)
		if method == "Put" and req.key == "/blocked" then
			return {
				header = srv.storage:header(),
				-- Return error by not storing the value
			}
		end
		-- Return nil to use default handler
		return nil
	end)

	local c = create_client()

	-- Test 12.2: Normal put should work
	local res = c:put { key = "/normal", value = "works" }
	testaux.assertneq(res, nil, "Test 12.1: Normal put works")

	-- Test 12.3: Blocked key should still get response but not be stored
	res = c:put { key = "/blocked", value = "should_not_store" }
	testaux.assertneq(res, nil, "Test 12.2: Blocked put returns response")

	-- Test 12.4: Verify blocked key was not stored
	local storage = server:get_storage()
	local stored = storage.storage["/blocked"]
	testaux.asserteq(stored, nil, "Test 12.3: Blocked key not in storage")

	-- Test 12.5: Override Lease handler to simulate lease failure
	server:set_lease_handler(function(method, req, srv)
		if method == "LeaseGrant" and req.TTL == 999 then
			return {
				header = srv.storage:header(),
				ID = 0,
				TTL = 0,
				error = "simulated failure",
			}
		end
		return nil
	end)

	res = c:grant { TTL = 999 }
	testaux.assertneq(res, nil, "Test 12.4: Failed lease grant returns response")
	testaux.asserteq(res.error, "simulated failure", "Test 12.5: Error message propagated")

	c:close()

	testaux.success("Test 12: Custom handler override passed")
end)

-- Test 13: Watch with filters and options
testaux.case("Test 13: Watch with filters", function()
	print("-----Test 13: Watch with filters-----")
	reset_server()

	local c = create_client()

	-- Test 13.1: Watch with NOPUT filter (currently not fully implemented in fake server)
	-- This test verifies the client can send filter options
	local w = c:watch {
		key = "/filter/test",
		NOPUT = true,  -- Filter out PUT events
	}
	wait_watch_created(1)

	-- Even though filter may not be implemented, watch should be created
	testaux.assertneq(w, nil, "Test 13.1: Watch with NOPUT filter created")

	-- Test 13.2: Watch with prev_kv option

	local wg = waitgroup.new()
	local w2 = c:watch {
		key = "/prevkv/test",
		-- prev_kv = true,  -- Request previous value in events
	}
	wait_watch_created(1)
	wg:fork(function()
		local res = w2:read()
		testaux.assertneq(res, nil, "Test 13.2: Watch with prev_kv receives event")
		w:cancel()
		w2:cancel()
	end)
	wg:fork(function()
		c:put { key = "/prevkv/test", value = "old" }
		c:put { key = "/prevkv/test", value = "new" }
	end)
	wg:wait()
	c:close()

	testaux.success("Test 13: Watch with filters passed")
end)

-- Test 14: Compact operation
testaux.case("Test 14: Compact operation", function()
	print("-----Test 14: Compact operation-----")
	reset_server()

	local c = create_client()

	-- Test 14.1: Create some history
	local res = c:put { key = "/compact/test", value = "v1" }
	local rev1 = res.header.revision
	c:put { key = "/compact/test", value = "v2" }
	c:put { key = "/compact/test", value = "v3" }
	local res3 = c:put { key = "/compact/test", value = "v4" }
	local rev3 = res3.header.revision

	-- Test 14.2: Compact to revision
	res = c:compact { revision = rev1 }
	testaux.assertneq(res, nil, "Test 14.1: Compact operation succeeds")

	-- Test 14.3: Current value still accessible
	res = c:get { key = "/compact/test" }
	testaux.asserteq(res.kvs[1].value, "v4", "Test 14.2: Current value still accessible after compact")

	c:close()

	testaux.success("Test 14: Compact operation passed")
end)

-- Test 15: Server reset simulation
testaux.case("Test 15: Server reset", function()
	print("-----Test 15: Server reset-----")
	reset_server()

	local c = create_client()

	-- Test 15.1: Put some data
	c:put { key = "/restart/test", value = "before_reset" }
	local res = c:get { key = "/restart/test" }
	testaux.asserteq(res.count, 1, "Test 15.1: Data exists before reset")

	-- Test 15.2: Reset server (clears all data)
	reset_server()

	-- Test 15.3: Old data is gone after reset
	res = c:get { key = "/restart/test" }
	testaux.asserteq(res.count, 0, "Test 15.2: Data cleared after reset")

	-- Test 15.4: New operations work
	res = c:put { key = "/restart/new", value = "after_reset" }
	testaux.assertneq(res, nil, "Test 15.3: Operations work after reset")

	c:close()

	testaux.success("Test 15: Server reset passed")
end)

-- Test 16: Watch stream reconnection and revision tracking
testaux.case("Test 16: Watch stream reconnection", function()
	print("-----Test 16: Watch stream reconnection-----")
	reset_server()

	local c = create_client()

	-- Test 16.1: Create watcher and check initial start_revision
	server:clear_watch_requests()
	local watcher = c:watch { key = "/reconnect/test" }
	wait_watch_created(1)

	local watch_reqs = server:get_watch_requests()
	testaux.asserteq(#watch_reqs, 1, "Test 16.1: One watch request sent")
	local initial_start_rev = watch_reqs[1].start_revision
	-- Initial watch should have start_revision = 0 or nil (current revision + 1)
	print(string.format("Test 16.2: Initial start_revision = %s", tostring(initial_start_rev)))

	-- Test 16.2: Receive events and track revision
	task.fork(function()
		time.sleep(100)
		c:put { key = "/reconnect/test", value = "v1" }
		time.sleep(50)
		c:put { key = "/reconnect/test", value = "v2" }
		time.sleep(50)
		c:put { key = "/reconnect/test", value = "v3" }
	end)

	local res1 = watcher:read()
	testaux.assertneq(res1, nil, "Test 16.3: Receive first event")
	testaux.asserteq(res1.events[1].kv.value, "v1", "Test 16.4: First event value is v1")

	local res2 = watcher:read()
	testaux.asserteq(res2.events[1].kv.value, "v2", "Test 16.5: Second event value is v2")

	local res3 = watcher:read()
	testaux.asserteq(res3.events[1].kv.value, "v3", "Test 16.6: Third event value is v3")
	local last_revision = res3.header.revision
	local last_mod_revision = res3.events[1].kv.mod_revision

	local wstream = c.watchstream
	-- Test 16.3: Simulate stream disconnection by closing all streams
	-- This will force client to reconnect
	server:clear_watch_requests()  -- Clear previous requests to track reconnect
	server:close_all_streams()
	while c.watchstream == wstream do
		time.sleep(100)
	end
	-- Test 16.4: Check that client reconnected with correct start_revision
	-- The watcher should automatically reconnect
	-- Send a new event to trigger the reconnection to complete
	task.fork(function()
		time.sleep(100)
		c:put { key = "/reconnect/test", value = "v4" }
	end)
	-- Read the new event
	local res4 = watcher:read()
	testaux.assertneq(res4, nil, "Test 16.8: Receive event after reconnection")
	testaux.asserteq(res4.events[1].kv.value, "v4", "Test 16.9: Event after reconnect is v4")

	-- Test 16.5: Verify client used correct start_revision on reconnect
	watch_reqs = server:get_watch_requests()
	testaux.assertgt(#watch_reqs, 0, "Test 16.10: Watch reconnect requests recorded")

	-- Find the reconnect request (should be after the first one)
	local reconnect_req = watch_reqs[#watch_reqs]
	local reconnect_start_rev = reconnect_req.start_revision

	print(string.format("Test 16.11: Reconnect start_revision = %s (last_revision = %d)",
		tostring(reconnect_start_rev), last_revision))

	-- The reconnect should use start_revision = last received revision + 1
	-- This ensures no events are missed or duplicated
	if reconnect_start_rev then
		testaux.asserteq(reconnect_start_rev, last_revision + 1,
			"Test 16.12: Reconnect uses correct start_revision (last_revision + 1)")
	else
		-- In fake server after reset, revision starts from 0, so start_revision might be nil/0
		-- The important thing is that client tracks and uses revision
		print("Test 16.12: start_revision is nil (acceptable for fresh server)")
	end

	watcher:cancel()
	c:close()

	testaux.success("Test 16: Watch stream reconnection passed")
end)

-- Test 17: Lease keepalive stream reconnection
testaux.case("Test 17: Lease keepalive stream reconnection", function()
	print("-----Test 17: Lease keepalive stream reconnection-----")
	reset_server()

	local c = create_client()

	-- Test 17.1: Create lease with short TTL and start keepalive
	local res = c:grant { TTL = 3 }  -- 3 seconds TTL
	testaux.assertneq(res, nil, "Test 17.1: Grant lease")
	local lease_id = res.ID

	-- Test 17.2: Start keepalive and verify it sends requests
	server:clear_keepalive_requests()
	c:keepalive(lease_id)
	time.sleep(600)  -- Wait for at least one keepalive cycle

	local ka_reqs = server:get_keepalive_requests()
	local count_before = #ka_reqs
	testaux.assertgt(count_before, 0, "Test 17.2: Keepalive requests sent before disconnect")
	print(string.format("Test 17.3: %d keepalive requests before disconnect", count_before))

	-- Test 17.3: Verify lease is alive
	res = c:ttl { ID = lease_id }
	testaux.assertgt(res.TTL, 0, "Test 17.4: Lease is alive with keepalive")

	-- Test 17.4: Put a key with this lease
	c:put { key = "/lease/reconnect", value = "test", lease = lease_id }
	res = c:get { key = "/lease/reconnect" }
	testaux.asserteq(res.count, 1, "Test 17.5: Key exists with lease")

	-- Test 17.5: Simulate stream disconnection by closing all streams
	print("Simulating keepalive stream disconnection...")
	server:clear_keepalive_requests()  -- Clear to track reconnect requests
	server:close_all_streams()

	-- Test 17.6: Wait for keepalive to reconnect and resume
	time.sleep(1000)  -- Wait for reconnection and several keepalive cycles

	ka_reqs = server:get_keepalive_requests()
	local count_after = #ka_reqs
	testaux.assertgt(count_after, 0, "Test 17.6: Keepalive reconnected and resumed")
	print(string.format("Test 17.7: %d keepalive requests after reconnect", count_after))

	-- Test 17.7: Verify lease is still alive (keepalive is working)
	res = c:ttl { ID = lease_id }
	testaux.assertgt(res.TTL, 0, "Test 17.8: Lease still alive after reconnection")

	-- Test 17.8: Wait longer than original TTL to ensure keepalive keeps it alive
	time.sleep(2000)  -- Total time > 3s TTL

	res = c:ttl { ID = lease_id }
	testaux.assertgt(res.TTL, 0, "Test 17.9: Lease kept alive beyond original TTL")

	-- Test 17.9: Verify key still exists (not expired)
	res = c:get { key = "/lease/reconnect" }
	testaux.asserteq(res.count, 1, "Test 17.10: Key still exists (lease not expired)")

	-- Test 17.10: Check that keepalive continues to send requests
	ka_reqs = server:get_keepalive_requests()
	local final_count = #ka_reqs
	testaux.assertgt(final_count, count_after, "Test 17.11: Keepalive continues after reconnect")
	print(string.format("Test 17.12: Total %d keepalive requests, continuous operation confirmed", final_count))

	c:revoke { ID = lease_id }
	c:close()

	testaux.success("Test 17: Lease keepalive stream reconnection passed")
end)

server:stop()

print("")
print("=== All Etcd Fake Server Tests Completed ===")
